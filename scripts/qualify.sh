#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${CLAWBOX_ENV_FILE:-$BASE_DIR/.env}"

source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/ssh.sh"
source "$BASE_DIR/lib/qualify/qualify.sh"

QUALIFY_JSON=false
QUALIFY_PROFILE='full'
QUALIFY_PROFILE_EXPLICIT=false
QUALIFY_SCENARIO=''
QUALIFY_ACTIVE_OPERATION_PID=''
QUALIFY_ACTIVE_OPERATION_MESSAGE=''
QUALIFY_ERROR_CODE=''
QUALIFY_ERROR_MODEL_ALIAS='unknown'
QUALIFY_ERROR_MODEL_CONFIGURED='unknown'
QUALIFY_ERROR_MODEL_RUNNING='unknown'
QUALIFY_EXECUTION_GROUP_STARTED=false

for arg in "$@"; do
  if [ "$arg" = '--json' ]; then
    QUALIFY_JSON=true
    break
  fi
done

usage() {
  cat <<'EOF'
Usage: ./clawbox qualify [--profile fast|full] [--scenario <scenario-id>] [--json]

Run the ClawBox model qualification suite inside the VM against the currently
configured OpenClaw model.

Options:
  --profile <id>   Select fast or full qualification profile (default: full)
  --scenario <id>  Run one scenario by ID
  --json           Print only the aggregate JSON result to stdout
  -h, --help       Show this help

Examples:
  ./clawbox qualify
  ./clawbox qualify --profile fast
  ./clawbox qualify --profile full
  ./clawbox qualify --profile fast --scenario 01-tool-reliability
EOF
}

qualify_profile_name() {
  case "$1" in
    fast) printf 'Fast\n' ;;
    full) printf 'Full\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
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
    python3 - "$message" "${QUALIFY_ERROR_CODE:-}" "${QUALIFY_ERROR_MODEL_ALIAS:-unknown}" "${QUALIFY_ERROR_MODEL_CONFIGURED:-unknown}" "${QUALIFY_ERROR_MODEL_RUNNING:-unknown}" "${QUALIFY_PROFILE:-full}" "$(qualify_profile_name "${QUALIFY_PROFILE:-full}" 2>/dev/null || printf '%s' "${QUALIFY_PROFILE:-full}")" <<'PY'
import json, sys
message = sys.argv[1]
error_code = sys.argv[2] or None
model_alias = sys.argv[3] or "unknown"
model_configured = sys.argv[4] or "unknown"
model_running = sys.argv[5] or "unknown"
profile_id = sys.argv[6] or "full"
profile_name = sys.argv[7] or profile_id
print(json.dumps({
    "schemaVersion": "1",
    "runId": None,
    "startedAt": None,
    "completedAt": None,
    "durationSeconds": None,
    "completed": False,
    "suite": {"schemaVersion": "1", "checksum": None},
    "clawbox": {"commit": None, "dirty": None},
    "profile": {"id": profile_id, "name": profile_name},
    "coverage": {"profile": profile_id, "scenariosRun": 0, "reliabilityIterations": 0, "workflowCases": 0},
    "model": {"alias": model_alias, "configured": model_configured, "running": model_running},
    "overallStatus": "ERROR",
    "errorCode": error_code,
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
    printf '{"schemaVersion":"1","runId":null,"startedAt":null,"completedAt":null,"durationSeconds":null,"completed":false,"suite":{"schemaVersion":"1","checksum":null},"clawbox":{"commit":null,"dirty":null},"profile":{"id":"%s","name":"%s"},"coverage":{"profile":"%s","scenariosRun":0,"reliabilityIterations":0,"workflowCases":0},"model":{"alias":"unknown","configured":"unknown","running":"unknown"},"overallStatus":"ERROR","score":null,"categories":{},"warnings":[],"failures":["%s"],"scenarios":[],"artifactDirectory":null}\n' "${QUALIFY_PROFILE:-full}" "$(qualify_profile_name "${QUALIFY_PROFILE:-full}" 2>/dev/null || printf '%s' "${QUALIFY_PROFILE:-full}")" "${QUALIFY_PROFILE:-full}" "$escaped"
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

qualify_cleanup_active_operation() {
  local pid="${QUALIFY_ACTIVE_OPERATION_PID:-}"
  local message="${QUALIFY_ACTIVE_OPERATION_MESSAGE:-}"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  fi
  QUALIFY_ACTIVE_OPERATION_PID=''
  QUALIFY_ACTIVE_OPERATION_MESSAGE=''
  if [ "$QUALIFY_JSON" != true ] && [ -n "$message" ]; then
    status_end "$message ✗" 'error'
  fi
}

install_status_exit_trap
_append_trap 'qualify_cleanup_active_operation' EXIT
_append_trap 'qualify_cleanup_active_operation; exit 130' INT
_append_trap 'qualify_cleanup_active_operation; exit 143' TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || die_usage 'Missing value for --profile.'
      [ "$QUALIFY_PROFILE_EXPLICIT" = false ] || die_usage 'Duplicate --profile option.'
      QUALIFY_PROFILE="$2"
      QUALIFY_PROFILE_EXPLICIT=true
      shift 2
      ;;
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

qualify_status_spinner_message() {
  local label="$1"
  if [ -t 2 ]; then
    printf '%s......\n' "$label"
  else
    printf '%s...\n' "$label"
  fi
}

qualify_begin_execution_group() {
  if [ "$QUALIFY_JSON" = true ]; then
    return 0
  fi
  if [ "${QUALIFY_EXECUTION_GROUP_STARTED:-false}" != true ]; then
    blank_line
    QUALIFY_EXECUTION_GROUP_STARTED=true
  fi
}

qualify_run_operation() {
  local label="$1"
  shift
  local message="$label..."
  local spinner_message='' pid='' status=0 stderr_file=''

  stderr_file="$(mktemp)" || return 2

  if [ "$QUALIFY_JSON" = true ]; then
    printf '%s\n' "$message" >&2
    set +e
    "$@" >/dev/null 2>"$stderr_file"
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      printf '%s ✓\n' "$message" >&2
    else
      printf '%s ✗\n' "$message" >&2
      cat "$stderr_file" >&2 2>/dev/null || true
    fi
    rm -f "$stderr_file"
    return "$status"
  fi

  spinner_message="$(qualify_status_spinner_message "$label")"
  status_begin_compact "$spinner_message"
  set +e
  "$@" >/dev/null 2>"$stderr_file" &
  pid=$!
  set -e
  QUALIFY_ACTIVE_OPERATION_PID="$pid"
  QUALIFY_ACTIVE_OPERATION_MESSAGE="$message"
  while kill -0 "$pid" >/dev/null 2>&1; do
    status_sleep "$(status_tick_interval)" "$spinner_message"
  done
  set +e
  wait "$pid"
  status=$?
  set -e
  QUALIFY_ACTIVE_OPERATION_PID=''
  QUALIFY_ACTIVE_OPERATION_MESSAGE=''
  if [ "$status" -eq 0 ]; then
    status_end "$message ✓" 'progress'
  else
    status_end "$message ✗" 'error'
    cat "$stderr_file" >&2 2>/dev/null || true
  fi
  rm -f "$stderr_file"
  return "$status"
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

validate_profile_id() {
  local profile="$1"
  case "$profile" in
    fast|full) return 0 ;;
    *) die_usage "Unknown qualification profile: $profile" ;;
  esac
}

require_host_inference() {
  local url="${LLAMA_BASE_URL:-}"
  [ -n "$url" ] || { printf 'LLAMA_BASE_URL is not configured.\n' >&2; return 2; }
  if ! curl -s --connect-timeout 2 --max-time 5 "${url%/}/models" >/dev/null; then
    printf 'Host inference endpoint is not responding: %s\n' "${url%/}/models" >&2
    return 2
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
    printf 'VM SSH is not reachable: %s\n' "${VM_HOST:-not configured}" >&2
    return 2
  fi
}

require_openclaw() {
  if ! ssh_check_zsh 'command -v openclaw >/dev/null 2>&1 || [ -x /opt/homebrew/bin/openclaw ] || [ -x /usr/local/bin/openclaw ]' >/dev/null 2>&1; then
    printf 'OpenClaw is not available in the VM. Run ./clawbox setup and VM provisioning first.\n' >&2
    return 2
  fi
}

current_openclaw_model() {
  ssh_check_zsh 'openclaw config get agents.defaults.model.primary 2>/dev/null || true'
}

validate_model_consistency() {
  if [ -z "${model_configured:-}" ] || [ "$model_configured" = 'unknown' ]; then
    printf 'Configured model could not be identified from MODEL_PATH.\n' >&2
    return 2
  fi
  if [ -z "${model_running:-}" ] || [ "$model_running" = 'unknown' ]; then
    printf 'Running model could not be identified from the host inference endpoint.\n' >&2
    return 2
  fi
  if [ "$model_configured" != "$model_running" ]; then
    printf 'Configured model does not match the running model.\n' >&2
    return 2
  fi
}

qualify_clawbox_commit() {
  git -C "$BASE_DIR" rev-parse HEAD 2>/dev/null || true
}

qualify_clawbox_dirty() {
  if ! git -C "$BASE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'null\n'
    return 0
  fi
  if git -C "$BASE_DIR" diff --quiet --ignore-submodules -- 2>/dev/null \
    && git -C "$BASE_DIR" diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
    printf 'false\n'
  else
    printf 'true\n'
  fi
}

qualify_ensure_suite_installed_polished() {
  local checksum=''

  checksum="$(qualify_suite_checksum)" || return 1
  if qualify_remote_manifest_matches "$checksum" >/dev/null 2>&1; then
    return 0
  fi

  qualify_begin_execution_group
  qualify_run_operation 'Publishing qualification suite to VM' qualify_publish_suite_to_vm_runtime || return 1
  qualify_run_operation 'Installing qualification suite in OpenClaw workspace' qualify_install_suite_on_vm "$checksum"
}

qualify_scenario_description() {
  local scenario="$1"
  local profile="${2:-full}"
  case "$scenario" in
    01-tool-reliability) printf '01-tool-reliability qualification\n' ;;
    02-tool-workflows) printf '02-tool-workflows qualification\n' ;;
    03-code-repair) printf '03-code-repair qualification\n' ;;
    '')
      case "$profile" in
        fast) printf 'fast model qualification\n' ;;
        full) printf 'full model qualification\n' ;;
        *) printf '%s model qualification\n' "$profile" ;;
      esac
      ;;
    *) printf '%s qualification\n' "$scenario" ;;
  esac
}

qualify_render_report() {
  local json_file="$1"

  section 'Model Qualification Report'
  python3 - "$json_file" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data = json.load(fh)

def line(label, value):
    dots = '.' * max(1, 34 - len(label))
    print(f"{label} {dots} {value}")

def duration(seconds):
    try:
        seconds = int(float(seconds))
    except Exception:
        return None
    if seconds < 60:
        return f"{seconds}s"
    minutes, rem = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {rem:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m {rem:02d}s"

def fmt_average(value):
    try:
        return f"{float(value):.1f}"
    except Exception:
        return str(value)

scenarios = data.get('scenarios', [])
profile = data.get('profile') or {}
profile_name = profile.get('name') or profile.get('id') or 'unknown'
coverage = data.get('coverage') or {}
line('Profile', profile_name)
coverage_parts = []
if coverage.get('scenariosRun') is not None:
    coverage_parts.append(f"{coverage.get('scenariosRun')} scenarios")
if coverage.get('reliabilityIterations') is not None:
    coverage_parts.append(f"{coverage.get('reliabilityIterations')} reliability iterations")
if coverage.get('workflowCases') is not None:
    coverage_parts.append(f"{coverage.get('workflowCases')} workflow cases")
if coverage_parts:
    line('Coverage', f"{profile_name} profile ({', '.join(coverage_parts)})")
print('')
for index, scenario in enumerate(scenarios):
    sid = scenario.get('scenarioId', 'unknown')
    name = scenario.get('scenarioName', '')
    if index:
        print('')
    print(sid)
    if name:
        line(name, scenario.get('status', 'unknown'))
    if scenario.get('score') is not None:
        line('Scenario Score', f"{scenario.get('score')}/100")
    scenario_duration = duration(scenario.get('durationSeconds'))
    if scenario_duration:
        line('Duration', scenario_duration)
    metrics = scenario.get('metrics') or {}
    if 'correctIterations' in metrics and 'totalIterations' in metrics:
        line('Correct iterations', f"{metrics['correctIterations']}/{metrics['totalIterations']}")
    if 'efficientIterations' in metrics and 'totalIterations' in metrics:
        line('Efficient iterations', f"{metrics['efficientIterations']}/{metrics['totalIterations']}")
    if 'passingCases' in metrics and 'totalCases' in metrics:
        line('Passing workflow cases', f"{metrics['passingCases']}/{metrics['totalCases']}")
    if 'efficientCases' in metrics and 'totalCases' in metrics:
        line('Efficient workflow cases', f"{metrics['efficientCases']}/{metrics['totalCases']}")
    if 'averageToolCalls' in metrics:
        line('Average tool calls', fmt_average(metrics['averageToolCalls']))
    if 'testResult' in metrics:
        line('Final test', metrics['testResult'])
    if 'changedFiles' in metrics:
        line('Changed files', metrics['changedFiles'] or 'none')

if scenarios:
    print('')
score = data.get('score')
line('Overall Score', 'Unrated' if score is None else f'{score}/100')
line('Overall Result', data.get('overallStatus', 'unknown'))
if data.get('completed') is False:
    line('Completed', 'false')
warnings = data.get('warnings') or []
failures = data.get('failures') or []
if score is not None and score < 100:
    if warnings or failures:
        print('Score notes:')
        if warnings:
            print('- Deductions reflect the warnings listed below.')
        if failures:
            print('- Deductions reflect the failures listed below.')
    else:
        print('Score notes:')
        print('- Deductions reflect scenario category weighting in the structured JSON report.')
if warnings:
    print('Warnings:')
    for warning in dict.fromkeys(warnings):
        print(f'- {warning}')
if failures:
    print('Failures:')
    for failure in dict.fromkeys(failures):
        print(f'- {failure}')
line('Run ID', data.get('runId') or 'unknown')
aggregate_duration = duration(data.get('durationSeconds'))
if aggregate_duration:
    line('Duration', aggregate_duration)
line('Artifacts', data.get('artifactDirectory') or 'unavailable')
PY
}

qualify_run_remote_runner() {
  local remote_command="$1" output_file="$2" stderr_file="$3" remote_env="$4"

  ssh -n "$VM_HOST" "$remote_env zsh -lc $(qualify_shell_quote "$remote_command")" >"$output_file" 2>"$stderr_file"
}

qualify_run_remote_operation() {
  local label="$1" remote_command="$2" output_file="$3" stderr_file="$4" remote_env="$5"
  local message="$label..." spinner_message='' pid='' status=0 level='success' marker='✓' overall=''

  if [ "$QUALIFY_JSON" = true ]; then
    printf '%s\n' "$message" >&2
    set +e
    qualify_run_remote_runner "$remote_command" "$output_file" "$stderr_file" "$remote_env"
    status=$?
    set -e
    overall="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("overallStatus") or ""))' "$output_file" 2>/dev/null || true)"
    case "$status:$overall" in
      0:WARNING) marker='!' ;;
      0:*) marker='✓' ;;
      1:*) marker='!' ;;
      *) marker='✗' ;;
    esac
    printf '%s %s\n' "$message" "$marker" >&2
    return "$status"
  fi

  spinner_message="$(qualify_status_spinner_message "$label")"
  status_begin_compact "$spinner_message"
  set +e
  qualify_run_remote_runner "$remote_command" "$output_file" "$stderr_file" "$remote_env" &
  pid=$!
  set -e
  QUALIFY_ACTIVE_OPERATION_PID="$pid"
  QUALIFY_ACTIVE_OPERATION_MESSAGE="$message"
  while kill -0 "$pid" >/dev/null 2>&1; do
    status_sleep "$(status_tick_interval)" "$spinner_message"
  done
  set +e
  wait "$pid"
  status=$?
  set -e
  QUALIFY_ACTIVE_OPERATION_PID=''
  QUALIFY_ACTIVE_OPERATION_MESSAGE=''
  overall="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("overallStatus") or ""))' "$output_file" 2>/dev/null || true)"
  case "$status:$overall" in
    0:WARNING) level='progress'; marker='!' ;;
    0:*) level='progress'; marker='✓' ;;
    1:*) level='progress'; marker='!' ;;
    *) level='error'; marker='✗' ;;
  esac
  status_end "$message $marker" "$level"
  return "$status"
}

main() {
  local model_ref='' model_configured='' model_running='' model_display=''
  local remote_command='' remote_status=0 remote_env='' remote_output='' remote_stderr=''
  local run_label='' suite_checksum='' clawbox_commit='' clawbox_dirty='null'

  validate_profile_id "$QUALIFY_PROFILE"
  validate_scenario_id "$QUALIFY_SCENARIO"
  require_env

  VM_HOST="${VM_HOST:-}"
  VM_RUNTIME_PATH="${VM_RUNTIME_PATH:-}"
  require_vm_host >/dev/null 2>&1 || qualify_fail 2 'VM_HOST is not configured.'
  [ -n "$VM_RUNTIME_PATH" ] || qualify_fail 2 'VM_RUNTIME_PATH is not configured.'

  if [ "$QUALIFY_JSON" != true ]; then
    title 'ClawBox Model Qualification'
  fi

  qualify_run_operation 'Checking host inference endpoint' require_host_inference || qualify_fail 2 'Host inference endpoint is not responding.'
  qualify_run_operation 'Checking VM SSH access' require_vm_ssh || qualify_fail 2 "VM SSH is not reachable: ${VM_HOST:-not configured}"
  qualify_run_operation 'Checking OpenClaw availability' require_openclaw || qualify_fail 2 'OpenClaw is not available in the VM. Run ./clawbox setup and VM provisioning first.'

  model_ref="$(current_openclaw_model)"
  [ -n "$model_ref" ] || model_ref="${OPENCLAW_PROVIDER_NAME:-clawbox}/${OPENCLAW_DEFAULT_MODEL:-local}"
  model_configured="$(configured_model_identity)"
  model_running="$(running_model_identity || true)"
  [ -n "$model_running" ] || model_running='unknown'
  if [ -n "$model_running" ] && [ "$model_running" != 'unknown' ]; then
    model_display="$model_running"
  elif [ -n "$model_configured" ] && [ "$model_configured" != 'unknown' ]; then
    model_display="$model_configured"
  else
    model_display="$model_ref"
  fi

  QUALIFY_ERROR_MODEL_ALIAS="$model_ref"
  QUALIFY_ERROR_MODEL_CONFIGURED="$model_configured"
  QUALIFY_ERROR_MODEL_RUNNING="$model_running"
  if ! qualify_run_operation 'Checking configured model matches running model' validate_model_consistency; then
    QUALIFY_ERROR_CODE='MODEL_MISMATCH'
    qualify_fail 2 "Configured model does not match the running model.
Configured: $model_configured
Running:    $model_running
Resolve the model inconsistency before running qualification."
  fi

  export CLAWBOX_QUALIFY_MODEL_REF="$model_ref"
  export CLAWBOX_QUALIFY_MODEL_ALIAS="$model_ref"
  export CLAWBOX_QUALIFY_MODEL_CONFIGURED="$model_configured"
  export CLAWBOX_QUALIFY_MODEL_RUNNING="$model_running"
  export CLAWBOX_QUALIFY_MODEL_WARNING=''

  blank_line
  qualify_progress "Model under qualification: $model_display"
  qualify_progress "OpenClaw alias: $model_ref"
  qualify_progress "Qualification profile: $(qualify_profile_name "$QUALIFY_PROFILE")"
  suite_checksum="$(qualify_suite_checksum)" || qualify_fail 2 'Unable to calculate the VM qualification suite checksum.'
  qualify_ensure_suite_installed_polished || qualify_fail 2 'Unable to publish or install the VM qualification suite.'
  clawbox_commit="$(qualify_clawbox_commit)"
  clawbox_dirty="$(qualify_clawbox_dirty)"

  remote_output="$(mktemp)" || qualify_fail 2 'Unable to create qualification output file.'
  remote_stderr="$(mktemp)" || qualify_fail 2 'Unable to create qualification stderr file.'
  remote_command="$(qualify_remote_runner_command "$QUALIFY_SCENARIO" true "$QUALIFY_PROFILE")"
  remote_env="CLAWBOX_QUALIFY_MODEL_REF=$(qualify_shell_quote "$model_ref") CLAWBOX_QUALIFY_MODEL_ALIAS=$(qualify_shell_quote "$model_ref") CLAWBOX_QUALIFY_MODEL_CONFIGURED=$(qualify_shell_quote "$model_configured") CLAWBOX_QUALIFY_MODEL_RUNNING=$(qualify_shell_quote "$model_running") CLAWBOX_QUALIFY_MODEL_WARNING='' CLAWBOX_QUALIFY_PROFILE_ID=$(qualify_shell_quote "$QUALIFY_PROFILE") CLAWBOX_QUALIFY_PROFILE_NAME=$(qualify_shell_quote "$(qualify_profile_name "$QUALIFY_PROFILE")") CLAWBOX_QUALIFY_SUITE_VERSION=$(qualify_shell_quote "$QUALIFY_SUITE_VERSION") CLAWBOX_QUALIFY_SUITE_CHECKSUM=$(qualify_shell_quote "$suite_checksum") CLAWBOX_QUALIFY_CLAWBOX_COMMIT=$(qualify_shell_quote "$clawbox_commit") CLAWBOX_QUALIFY_CLAWBOX_DIRTY=$(qualify_shell_quote "$clawbox_dirty")"
  run_label="Running $(qualify_scenario_description "$QUALIFY_SCENARIO" "$QUALIFY_PROFILE")"
  qualify_begin_execution_group
  if qualify_run_remote_operation "$run_label" "$remote_command" "$remote_output" "$remote_stderr" "$remote_env"; then
    remote_status=0
  else
    remote_status=$?
  fi

  if ! python3 -m json.tool "$remote_output" >/dev/null 2>&1; then
    cat "$remote_stderr" >&2 2>/dev/null || true
    qualify_fail 2 'VM qualification runner did not produce valid aggregate JSON.'
  fi

  case "$remote_status" in
    0) run_level='success' ;;
    1) run_level='warning' ;;
    2) run_level='error' ;;
    *) run_level='error' ;;
  esac

  if [ "$QUALIFY_JSON" = true ]; then
    cat "$remote_output"
  else
    qualify_render_report "$remote_output"
  fi

  case "$remote_status" in
    0|1|2) return "$remote_status" ;;
    *) qualify_fail 2 "Unable to run the VM qualification suite over SSH." ;;
  esac
}

main "$@"
