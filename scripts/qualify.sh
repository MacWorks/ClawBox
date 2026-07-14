#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${CLAWBOX_ENV_FILE:-$BASE_DIR/.env}"

source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/ssh.sh"
source "$BASE_DIR/lib/qualify/qualify.sh"

QUALIFY_JSON=false
QUALIFY_SCENARIO=''

for arg in "$@"; do
  if [ "$arg" = '--json' ]; then
    QUALIFY_JSON=true
    break
  fi
done

usage() {
  cat <<'EOF'
Usage: ./clawbox qualify [--scenario <scenario-id>] [--json]

Run the ClawBox model qualification suite inside the VM against the currently
configured OpenClaw model.

Options:
  --scenario <id>  Run one scenario by ID
  --json           Print only the aggregate JSON result to stdout
  -h, --help       Show this help
EOF
}

die_usage() {
  local message="$1"
  if [ "$QUALIFY_JSON" = true ]; then
    qualify_fail 2 "$message"
  else
    error "$message"
    usage
    exit 2
  fi
}

qualify_json_error_document() {
  local message="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$message" <<'PY'
import json, sys
message = sys.argv[1]
print(json.dumps({
    "schemaVersion": "1",
    "runId": None,
    "model": {"alias": "unknown", "configured": "unknown", "running": "unknown"},
    "overallStatus": "ERROR",
    "score": None,
    "categories": {},
    "warnings": [],
    "failures": [message],
    "scenarios": [],
    "artifactDirectory": None,
}, separators=(",", ":")))
PY
  else
    local escaped
    escaped="$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"schemaVersion":"1","runId":null,"model":{"alias":"unknown","configured":"unknown","running":"unknown"},"overallStatus":"ERROR","score":null,"categories":{},"warnings":[],"failures":["%s"],"scenarios":[],"artifactDirectory":null}\n' "$escaped"
  fi
}

qualify_fail() {
  local status="$1"
  local message="$2"
  if [ "$QUALIFY_JSON" = true ]; then
    printf 'ERROR: %s\n' "$message" >&2
    qualify_json_error_document "$message"
  else
    error "$message"
  fi
  exit "$status"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario)
      [ "$#" -ge 2 ] || die_usage 'Missing value for --scenario.'
      QUALIFY_SCENARIO="$2"
      shift 2
      ;;
    --json)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "Unknown qualify option: $1"
      ;;
  esac
done

qualify_progress() {
  if [ "$QUALIFY_JSON" = true ]; then
    printf '%s\n' "$*" >&2
  else
    out "$*"
  fi
}

require_env() {
  if [ ! -f "$ENV_FILE" ]; then
    qualify_fail 2 "Missing .env. Run ./clawbox setup first."
  fi
  # shellcheck source=/dev/null
  source "$ENV_FILE"
}

validate_scenario_id() {
  local scenario="$1"
  [ -z "$scenario" ] && return 0
  case "$scenario" in
    01-tool-reliability|02-tool-workflows|03-code-repair) return 0 ;;
    *) die_usage "Unknown qualification scenario: $scenario" ;;
  esac
}

require_host_inference() {
  local url="${LLAMA_BASE_URL:-}"
  [ -n "$url" ] || qualify_fail 2 'LLAMA_BASE_URL is not configured.'
  if ! curl -s --connect-timeout 2 --max-time 5 "${url%/}/models" >/dev/null; then
    qualify_fail 2 "Host inference endpoint is not responding: ${url%/}/models"
  fi
}

model_basename() {
  local model_path="$1"
  [ -n "$model_path" ] || return 1
  printf '%s\n' "${model_path##*/}"
}

configured_model_identity() {
  model_basename "${MODEL_PATH:-}" 2>/dev/null || printf 'unknown\n'
}

running_model_identity() {
  local url="${LLAMA_BASE_URL:-}" body='' parsed=''
  [ -n "$url" ] || return 1
  body="$(curl -s --connect-timeout 2 --max-time 5 "${url%/}/models" 2>/dev/null || true)"
  [ -n "$body" ] || return 1
  parsed="$(printf '%s' "$body" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
models = data.get("data") or data.get("models") or []
if not isinstance(models, list) or not models:
    sys.exit(1)
first = models[0]
if isinstance(first, dict):
    value = first.get("id") or first.get("name") or ""
else:
    value = str(first)
if not value:
    sys.exit(1)
print(value.rsplit("/", 1)[-1])
' 2>/dev/null)" || return 1
  [ -n "$parsed" ] || return 1
  printf '%s\n' "$parsed"
}

require_vm_ssh() {
  if ! ssh_check 'echo ok' >/dev/null 2>&1; then
    qualify_fail 2 "VM SSH is not reachable: ${VM_HOST:-not configured}"
  fi
}

require_openclaw() {
  if ! ssh_check_zsh 'command -v openclaw >/dev/null 2>&1 || [ -x /opt/homebrew/bin/openclaw ] || [ -x /usr/local/bin/openclaw ]' >/dev/null 2>&1; then
    qualify_fail 2 'OpenClaw is not available in the VM. Run ./clawbox setup and VM provisioning first.'
  fi
}

current_openclaw_model() {
  ssh_check_zsh 'openclaw config get agents.defaults.model.primary 2>/dev/null || true'
}

main() {
  local model_ref='' model_configured='' model_running='' model_display='' model_warning=''
  local remote_command='' remote_status=0 remote_env=''

  validate_scenario_id "$QUALIFY_SCENARIO"
  require_env

  VM_HOST="${VM_HOST:-}"
  VM_RUNTIME_PATH="${VM_RUNTIME_PATH:-}"
  require_vm_host >/dev/null 2>&1 || qualify_fail 2 'VM_HOST is not configured.'
  [ -n "$VM_RUNTIME_PATH" ] || qualify_fail 2 'VM_RUNTIME_PATH is not configured.'

  if [ "$QUALIFY_JSON" != true ]; then
    title 'ClawBox Model Qualification'
  fi

  qualify_progress 'Checking host inference endpoint...'
  require_host_inference
  qualify_progress 'Checking VM SSH access...'
  require_vm_ssh
  qualify_progress 'Checking OpenClaw availability...'
  require_openclaw

  model_ref="$(current_openclaw_model)"
  [ -n "$model_ref" ] || model_ref="${OPENCLAW_PROVIDER_NAME:-clawbox}/${OPENCLAW_DEFAULT_MODEL:-local}"
  model_configured="$(configured_model_identity)"
  model_running="$(running_model_identity || true)"
  [ -n "$model_running" ] || model_running="$model_configured"
  if [ -n "$model_running" ] && [ "$model_running" != 'unknown' ]; then
    model_display="$model_running"
  elif [ -n "$model_configured" ] && [ "$model_configured" != 'unknown' ]; then
    model_display="$model_configured"
  else
    model_display="$model_ref"
  fi
  if [ "$model_configured" != 'unknown' ] && [ "$model_running" != 'unknown' ] && [ "$model_configured" != "$model_running" ]; then
    model_warning="Configured model $model_configured differs from running model $model_running."
  fi

  export CLAWBOX_QUALIFY_MODEL_REF="$model_ref"
  export CLAWBOX_QUALIFY_MODEL_ALIAS="$model_ref"
  export CLAWBOX_QUALIFY_MODEL_CONFIGURED="$model_configured"
  export CLAWBOX_QUALIFY_MODEL_RUNNING="$model_running"
  export CLAWBOX_QUALIFY_MODEL_WARNING="$model_warning"

  qualify_progress "Model under qualification: $model_display"
  qualify_progress "OpenClaw alias: $model_ref"
  qualify_progress "Configured model: $model_configured"
  qualify_progress "Running model: $model_running"
  if [ -n "$model_warning" ]; then
    qualify_progress "WARNING: $model_warning"
  fi
  if [ "$QUALIFY_JSON" = true ]; then
    qualify_ensure_suite_installed >&2 || qualify_fail 2 'Unable to publish or install the VM qualification suite.'
  else
    qualify_ensure_suite_installed || qualify_fail 2 'Unable to publish or install the VM qualification suite.'
  fi

  remote_command="$(qualify_remote_runner_command "$QUALIFY_SCENARIO" "$QUALIFY_JSON")"
  remote_env="CLAWBOX_QUALIFY_MODEL_REF=$(qualify_shell_quote "$model_ref") CLAWBOX_QUALIFY_MODEL_ALIAS=$(qualify_shell_quote "$model_ref") CLAWBOX_QUALIFY_MODEL_CONFIGURED=$(qualify_shell_quote "$model_configured") CLAWBOX_QUALIFY_MODEL_RUNNING=$(qualify_shell_quote "$model_running") CLAWBOX_QUALIFY_MODEL_WARNING=$(qualify_shell_quote "$model_warning")"
  if [ "$QUALIFY_JSON" = true ]; then
    ssh -n "$VM_HOST" "$remote_env zsh -lc $(qualify_shell_quote "$remote_command")" || remote_status=$?
  else
    ssh -n "$VM_HOST" "$remote_env zsh -lc $(qualify_shell_quote "$remote_command")" || remote_status=$?
  fi

  case "$remote_status" in
    0|1|2) return "$remote_status" ;;
    *) qualify_fail 2 "Unable to run the VM qualification suite over SSH." ;;
  esac
}

main "$@"
