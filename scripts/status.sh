#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/log-paths.sh"
source "$BASE_DIR/lib/context-runtime.sh"
source "$BASE_DIR/lib/llama/llama-runtime.sh"

STATUS_DEBUG="${CLAWBOX_STATUS_DEBUG:-false}"
for arg in "$@"; do
  case "$arg" in
    --debug)
      STATUS_DEBUG=true
      ;;
  esac
done

RED="${COLOR_RED:-}"
GREEN="${COLOR_GREEN:-}"
RESET="${COLOR_RESET:-}"

title "ClawBox System State"

[ -f "$BASE_DIR/.env" ] && source "$BASE_DIR/.env"

CONFIGURED_LLAMA_BASE_URL="${LLAMA_BASE_URL:-}"
HOST_IP="${HOST_IP:-127.0.0.1}"
LLAMA_PORT="${LLAMA_PORT:-11434}"
LLAMA_BASE_URL="http://$HOST_IP:$LLAMA_PORT"
HOST_STATUS_LLAMA_MODELS_URL="$LLAMA_BASE_URL/v1/models"
HOST_STATUS_DISPLAY_URL="$LLAMA_BASE_URL"
HOST_STATUS_EXPECTS_EXTERNAL=false
OPENCLAW_PROVIDER_NAME="${OPENCLAW_PROVIDER_NAME:-clawbox}"
if [ "${LLAMA_EXTERNAL:-false}" = "true" ] && [ -n "$CONFIGURED_LLAMA_BASE_URL" ]; then
  HOST_STATUS_LLAMA_MODELS_URL="${CONFIGURED_LLAMA_BASE_URL%/}/models"
  HOST_STATUS_DISPLAY_URL="$CONFIGURED_LLAMA_BASE_URL"
  HOST_STATUS_EXPECTS_EXTERNAL=true
fi
VM_LLAMA_BASE_URL="${CONFIGURED_LLAMA_BASE_URL:-$LLAMA_BASE_URL/v1}"
VM_LLAMA_SERVER_BASE_URL="${VM_LLAMA_BASE_URL%/}"
case "$VM_LLAMA_SERVER_BASE_URL" in
  */v1)
    VM_LLAMA_SERVER_BASE_URL="${VM_LLAMA_SERVER_BASE_URL%/v1}"
    ;;
esac
HOST_STATUS_LOCAL_LLAMA_HOST="$(llama_local_readiness_host "${LLAMA_HOST:-0.0.0.0}" 2>/dev/null || printf '127.0.0.1')"
HOST_STATUS_LOCAL_LLAMA_BASE_URL="http://$HOST_STATUS_LOCAL_LLAMA_HOST:$LLAMA_PORT"
HOST_STATUS_LOCAL_LLAMA_MODELS_URL="$HOST_STATUS_LOCAL_LLAMA_BASE_URL/v1/models"
STATUS_LLAMA_RUNTIME_SERVER_BASE_URL="$VM_LLAMA_SERVER_BASE_URL"
if [ "$HOST_STATUS_EXPECTS_EXTERNAL" != true ]; then
  STATUS_LLAMA_RUNTIME_SERVER_BASE_URL="$HOST_STATUS_LOCAL_LLAMA_BASE_URL"
fi
VM_LLAMA_COMPLETION_URL="$VM_LLAMA_SERVER_BASE_URL/completion"
VM_INFERENCE_MODEL="${OPENCLAW_DEFAULT_MODEL:-}"
if [ -z "$VM_INFERENCE_MODEL" ] && [ -n "${MODEL_PATH:-}" ]; then
  VM_INFERENCE_MODEL="$(basename "$MODEL_PATH")"
fi
STATUS_CURL_CONNECT_TIMEOUT="${CLAWBOX_STATUS_CURL_CONNECT_TIMEOUT:-1}"
STATUS_CURL_MAX_TIME="${CLAWBOX_STATUS_CURL_MAX_TIME:-2}"
STATUS_INFERENCE_CURL_MAX_TIME="${CLAWBOX_STATUS_INFERENCE_CURL_MAX_TIME:-${CLAWBOX_STATUS_CURL_MAX_TIME:-10}}"
VM_STATUS_CURL_ARGS="-s --connect-timeout $STATUS_CURL_CONNECT_TIMEOUT --max-time $STATUS_CURL_MAX_TIME"
LLAMA_SYSTEM_ERR_LOG="${CLAWBOX_LLAMA_ERR_LOG:-$(clawbox_llama_system_stderr_log_default)}"
LLAMA_USER_ERR_LOG="${CLAWBOX_LLAMA_USER_ERR_LOG:-$(clawbox_llama_user_stderr_log_default)}"

fail_count=0
wait_count=0
warn_count=0

fail() {
  out "FAIL: $1"
  fail_count=$((fail_count + 1))
}

wait_status() {
  out "WAIT: $1"
  wait_count=$((wait_count + 1))
}

warn_status() {
  out "WARN: $1"
  warn_count=$((warn_count + 1))
}

pass() {
  out "PASS: $1"
}

status_debug() {
  [ "$STATUS_DEBUG" = true ] || return 0
  out "DEBUG: $1"
}

status_curl() {
  curl -s --connect-timeout "$STATUS_CURL_CONNECT_TIMEOUT" --max-time "$STATUS_CURL_MAX_TIME" "$@"
}

status_host_address_available() {
  local host="$1"

  [ -n "$host" ] || return 1
  case "$host" in
    127.*|localhost|::1)
      return 0
      ;;
    0.0.0.0|::)
      return 0
      ;;
  esac

  if command -v ifconfig >/dev/null 2>&1 \
    && ifconfig 2>/dev/null | grep -E "(^|[^0-9.])${host//./\\.}([^0-9.]|$)" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

status_llama_runtime_json() {
  local endpoint="$1"
  local fixture_var=''
  local fixture_path=''

  case "$endpoint" in
    props) fixture_var="${CLAWBOX_STATUS_LLAMA_PROPS_FILE:-}" ;;
    slots) fixture_var="${CLAWBOX_STATUS_LLAMA_SLOTS_FILE:-}" ;;
    *) return 1 ;;
  esac

  fixture_path="$fixture_var"
  if [ -n "$fixture_path" ]; then
    cat "$fixture_path"
    return $?
  fi

  status_curl "$STATUS_LLAMA_RUNTIME_SERVER_BASE_URL/$endpoint"
}

status_json_value() {
  local json="$1"
  local expression="$2"

  python3 - "$json" "$expression" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)

expr = sys.argv[2]

def first_number(paths):
    for path in paths:
        cur = data
        try:
            for part in path.split("."):
                if isinstance(cur, list):
                    cur = cur[int(part)]
                else:
                    cur = cur[part]
            if isinstance(cur, bool):
                continue
            if isinstance(cur, (int, float)):
                print(int(cur))
                raise SystemExit(0)
        except Exception:
            continue
    raise SystemExit(1)

if expr == "runtime_context":
    first_number(["default_generation_settings.n_ctx", "n_ctx", "context_size", "contextWindow"])
elif expr == "total_slots":
    first_number(["total_slots", "slots", "slot_count"])
elif expr == "slot_context":
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict):
                for key in ("n_ctx", "ctx_size", "context_size"):
                    value = item.get(key)
                    if isinstance(value, (int, float)) and not isinstance(value, bool):
                        print(int(value))
                        raise SystemExit(0)
    if isinstance(data, dict):
        slots = data.get("slots")
        if isinstance(slots, list):
            for item in slots:
                if isinstance(item, dict):
                    for key in ("n_ctx", "ctx_size", "context_size"):
                        value = item.get(key)
                        if isinstance(value, (int, float)) and not isinstance(value, bool):
                            print(int(value))
                            raise SystemExit(0)
    raise SystemExit(1)
else:
    raise SystemExit(1)
PY
}

env_file_value() {
  local env_path="$1"
  local key="$2"

  [ -f "$env_path" ] || return 1
  /bin/bash -c 'set -euo pipefail; source "$1"; key="$2"; printf "%s\n" "${!key:-}"' _ "$env_path" "$key"
}

status_process_args_for_port() {
  local port="$1"
  local instance="${2:-primary}"
  local line

  if [ -n "${CLAWBOX_STATUS_PROCESS_ARGS_CMD:-}" ]; then
    "$CLAWBOX_STATUS_PROCESS_ARGS_CMD" "$port" "$instance"
    return $?
  fi

  while IFS= read -r line; do
    case " $line " in
      *" --port $port "*|*" --port=$port "*)
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done <<EOF
$(pgrep -fl llama-server 2>/dev/null || true)
EOF

  return 1
}

model_path_from_process_args() {
  local args="$1"
  local previous=''
  local word

  for word in $args; do
    if [ "$previous" = '-m' ] || [ "$previous" = '--model' ]; then
      printf '%s\n' "$word"
      return 0
    fi
    case "$word" in
      -m*)
        [ "$word" = '-m' ] || {
          printf '%s\n' "${word#-m}"
          return 0
        }
        ;;
      --model=*)
        printf '%s\n' "${word#--model=}"
        return 0
        ;;
    esac
    previous="$word"
  done

  return 1
}

model_display_name() {
  local path="$1"
  if [ -n "$path" ]; then
    basename "$path"
  else
    printf 'unknown\n'
  fi
}

vm_openclaw_config_get() {
  local key="$1"

  case "$key" in
    agents.defaults.memorySearch.model)
      vm_ssh_exec "jq -er '.agents.defaults.memorySearch.model // empty' ~/.openclaw/openclaw.json"
      ;;
    agents.defaults.compaction.reserveTokens)
      vm_ssh_exec "jq -er '.agents.defaults.compaction.reserveTokens // empty' ~/.openclaw/openclaw.json"
      ;;
    agents.defaults.compaction.reserveTokensFloor)
      vm_ssh_exec "jq -er '.agents.defaults.compaction.reserveTokensFloor // empty' ~/.openclaw/openclaw.json"
      ;;
    *)
      vm_ssh_exec "zsh -lc 'openclaw config get $key'"
      ;;
  esac
}

vm_openclaw_provider_models_get() {
  local provider="$1"

  vm_ssh_exec "jq -cer --arg provider \"$provider\" '.models.providers[\$provider].models // []' ~/.openclaw/openclaw.json"
}

status_openclaw_provider_models_report() {
  local models="$1"
  local default_model="${2:-local}"

  python3 - "$models" "$default_model" <<'PY'
import json, sys

try:
    models = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)

default_model = sys.argv[2] or "local"
if not isinstance(models, list):
    raise SystemExit(1)

local_entries = [
    model for model in models
    if isinstance(model, dict) and model.get("id") == default_model
]
if len(local_entries) == 1:
    print("pass\tOpenClaw stable alias model entry is configured")
elif len(local_entries) > 1:
    print(f"warn\tOpenClaw provider has duplicate stable alias model entries: {len(local_entries)}")
else:
    print("warn\tOpenClaw stable alias model entry is missing")

def is_legacy_concrete_model(model):
    if not isinstance(model, dict):
        return False
    allowed_keys = {"id", "name", "api", "contextWindow", "maxTokens", "compat", "reasoning", "input", "cost"}
    if any(key not in allowed_keys for key in model):
        return False
    model_id = model.get("id")
    if (
        not isinstance(model_id, str)
        or model_id == default_model
        or not model_id.endswith(".gguf")
        or model.get("name") != model_id
        or model.get("api") != "openai-completions"
    ):
        return False
    compat = model.get("compat", {})
    if not isinstance(compat, dict):
        return False
    unsupported = compat.get("unsupportedToolSchemaKeywords", [])
    if unsupported is not None and (
        not isinstance(unsupported, list)
        or any(not isinstance(keyword, str) for keyword in unsupported)
    ):
        return False
    for numeric_key in ("contextWindow", "maxTokens"):
        try:
            int(model.get(numeric_key))
        except Exception:
            return False
    if "reasoning" in model and not isinstance(model.get("reasoning"), bool):
        return False
    if "input" in model and not isinstance(model.get("input"), list):
        return False
    if "cost" in model and not isinstance(model.get("cost"), dict):
        return False
    return compat.get("supportsDeveloperRole") is False

for model in models:
    if not isinstance(model, dict):
        continue
    model_id = model.get("id")
    if not isinstance(model_id, str) or model_id == default_model:
        continue
    if not model_id.endswith(".gguf"):
        continue
    if is_legacy_concrete_model(model):
        print(f"warn\tOpenClaw provider has obsolete concrete model entry: {model_id}")
    elif model.get("name") != model_id:
        print(f"warn\tOpenClaw provider has conflicting concrete model entry: {model_id}")
PY
}

status_openclaw_model_numeric_field() {
  local models="$1"
  local default_model="$2"
  local field="$3"

  python3 - "$models" "$default_model" "$field" <<'PY'
import json, sys
try:
    models = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
default_model = sys.argv[2] or "local"
field = sys.argv[3]
for model in models if isinstance(models, list) else []:
    if isinstance(model, dict) and model.get("id") == default_model:
        value = model.get(field)
        if isinstance(value, bool) or value is None:
            raise SystemExit(1)
        print(int(value))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

llama_process_running() {
  if [ -n "${CLAWBOX_STATUS_PROCESS_CHECK_CMD:-}" ]; then
    "$CLAWBOX_STATUS_PROCESS_CHECK_CMD"
    return $?
  fi

  pgrep -fl llama-server >/dev/null
}

port_open() {
  if [ -n "${CLAWBOX_STATUS_PORT_OPEN_CMD:-}" ]; then
    "$CLAWBOX_STATUS_PORT_OPEN_CMD" "$1"
    return $?
  fi

  (: >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1
}

llama_log_contains() {
  local pattern="$1"
  local log_path=''

  for log_path in "$LLAMA_USER_ERR_LOG" "$LLAMA_SYSTEM_ERR_LOG"; do
    if [ -f "$log_path" ] && tail -n 20 "$log_path" 2>/dev/null | grep -Fq "$pattern"; then
      return 0
    fi
  done

  return 1
}

show_recent_llama_errors() {
  local log_path=''
  local emitted=false

  for log_path in "$LLAMA_USER_ERR_LOG" "$LLAMA_SYSTEM_ERR_LOG"; do
    if [ -f "$log_path" ]; then
      out "From $log_path:"
      tail -n 10 "$log_path" 2>/dev/null || out "(no log output)"
      emitted=true
    fi
  done

  if [ "$emitted" = false ]; then
    out "(no log output)"
  fi
}

detect_managed_llama_mode() {
  if [ -f "$(llama_system_plist_dest)" ] || [ -f "$(llama_system_env_dest)" ]; then
    REPLY='system'
    return 0
  fi

  if [ -f "$(llama_user_plist_dest)" ] || [ -f "$(llama_user_env_dest)" ]; then
    REPLY='user'
    return 0
  fi

  REPLY='user'
}

managed_llama_service_name() {
  case "$1" in
    system)
      printf 'LaunchDaemon\n'
      ;;
    *)
      printf 'LaunchAgent\n'
      ;;
  esac
}

managed_llama_service_loaded() {
  launchctl print "$(llama_mode_target "$1")" >/dev/null 2>&1
}

vm_autostart_plist_path() {
  printf '%s/Library/LaunchAgents/com.clawbox.startutmvm.plist\n' "$HOME"
}

vm_autostart_wrapper_path() {
  printf '%s/Library/Application Support/ClawBox/bin/start-utm-vm.sh\n' "$HOME"
}

vm_autostart_service_target() {
  printf 'gui/%s/com.clawbox.startutmvm\n' "$(id -u)"
}

vm_autostart_service_loaded() {
  launchctl print "$(vm_autostart_service_target)" >/dev/null 2>&1
}

vm_autostart_configured() {
  [ -f "$(vm_autostart_plist_path)" ] || [ -e "$(vm_autostart_wrapper_path)" ]
}

vm_autostart_log_latest_state_for_file() {
  local log_path="$1"

  [ -f "$log_path" ] || return 1
  awk '
    /ClawBox VM auto-start wrapper launched/ { state = "started" }
    /VM is already reachable via SSH/ { state = "success" }
    /VM is already running/ { state = "success" }
    /VM is reachable via SSH after startup/ { state = "success" }
    /VM is running after startup/ { state = "success" }
    /VM did not report running/ { state = "failure" }
    /\[ERROR\]/ { state = "failure" }
    END {
      if (state == "") {
        exit 1
      }
      print state
    }
  ' "$log_path"
}

vm_autostart_log_mtime() {
  local log_path="$1"

  [ -f "$log_path" ] || {
    printf '0\n'
    return 0
  }

  if stat -f '%m' "$log_path" >/dev/null 2>&1; then
    stat -f '%m' "$log_path"
  else
    stat -c '%Y' "$log_path" 2>/dev/null || printf '0\n'
  fi
}

vm_autostart_log_latest_state() {
  local stdout_log="$1"
  local stderr_log="$2"
  local stdout_state=''
  local stderr_state=''
  local stdout_mtime=0
  local stderr_mtime=0

  stdout_state="$(vm_autostart_log_latest_state_for_file "$stdout_log" 2>/dev/null || true)"
  stderr_state="$(vm_autostart_log_latest_state_for_file "$stderr_log" 2>/dev/null || true)"

  if [ -z "$stdout_state" ] && [ -z "$stderr_state" ]; then
    return 1
  fi

  stdout_mtime="$(vm_autostart_log_mtime "$stdout_log")"
  stderr_mtime="$(vm_autostart_log_mtime "$stderr_log")"

  if [ -n "$stderr_state" ] && [ "$stderr_mtime" -gt "$stdout_mtime" ]; then
    printf '%s\n' "$stderr_state"
    return 0
  fi

  if [ -n "$stdout_state" ]; then
    printf '%s\n' "$stdout_state"
    return 0
  fi

  printf '%s\n' "$stderr_state"
}

vm_ssh_exec() {
  ssh -o BatchMode=yes -o ConnectTimeout=3 "$VM_HOST" "$@"
}

vm_openclaw_clawbox_launchd_gateway_running() {
  vm_ssh_exec "launchd_output=\"\$(launchctl print \"gui/\$(id -u)/com.clawbox.openclaw\" 2>/dev/null)\" || exit 1
printf '%s\n' \"\$launchd_output\" | grep -Eq '^[[:space:]]*(state|job state) = running[[:space:]]*$' || exit 1
printf '%s\n' \"\$launchd_output\" | grep -Eq '^[[:space:]]*pid = [0-9]+' || exit 1
printf '%s\n' \"\$launchd_output\" | grep -Fq 'openclaw' || exit 1
printf '%s\n' \"\$launchd_output\" | grep -Eq '(^|[[:space:]])gateway([[:space:]]|$)' || exit 1"
}

vm_openclaw_native_launchd_gateway_running() {
  vm_ssh_exec "launchd_output=\"\$(launchctl print \"gui/\$(id -u)/ai.openclaw.gateway\" 2>/dev/null)\" || exit 1
printf '%s\n' \"\$launchd_output\" | grep -Eq '^[[:space:]]*(state|job state) = running[[:space:]]*$' || exit 1
printf '%s\n' \"\$launchd_output\" | grep -Eq '^[[:space:]]*pid = [0-9]+' || exit 1
printf '%s\n' \"\$launchd_output\" | grep -Fq 'openclaw' || exit 1
printf '%s\n' \"\$launchd_output\" | grep -Eq '(^|[[:space:]])gateway([[:space:]]|$)'"
}

vm_openclaw_process_gateway_running() {
  vm_ssh_exec "ps -axo pid=,comm=,args= | awk '\$2 == \"openclaw\" && \$0 ~ /(^|[[:space:]])gateway([[:space:]]|$)/ { found=1 } END { exit(found ? 0 : 1) }'"
}

vm_openclaw_native_process_gateway_running() {
  vm_ssh_exec "ps -axo pid=,comm=,args= | awk '\$0 ~ /openclaw/ && \$0 ~ /(^|[[:space:]])gateway([[:space:]]|$)/ { found=1 } END { exit(found ? 0 : 1) }'"
}

vm_llama_inference_probe() {
  status_debug "VM_LLAMA_BASE_URL=$VM_LLAMA_BASE_URL"
  status_debug "VM_LLAMA_COMPLETION_URL=$VM_LLAMA_COMPLETION_URL"
  status_debug "VM_HOST=$VM_HOST"
  status_debug "VM inference connect timeout=$STATUS_CURL_CONNECT_TIMEOUT"
  status_debug "VM inference max time=$STATUS_INFERENCE_CURL_MAX_TIME"

  vm_ssh_exec sh -s -- "$VM_LLAMA_COMPLETION_URL" "$STATUS_CURL_CONNECT_TIMEOUT" "$STATUS_INFERENCE_CURL_MAX_TIME" "$STATUS_DEBUG" <<'EOF'
url="$1"
connect_timeout="$2"
max_time="$3"
debug="$4"
body='{"prompt":"ping","n_predict":1,"cache_prompt":false}'

response_file="$(mktemp)" || exit 1
error_file="$(mktemp)" || {
  rm -f "$response_file"
  exit 1
}

curl_status=0
http_code="$(curl -s --connect-timeout "$connect_timeout" --max-time "$max_time" -o "$response_file" -w '%{http_code}' "$url" -H 'Content-Type: application/json' -d "$body" 2>"$error_file")" || curl_status=$?
response_body="$(cat "$response_file" 2>/dev/null || true)"
response_error="$(cat "$error_file" 2>/dev/null || true)"
response_bytes="$(wc -c < "$response_file" 2>/dev/null | tr -d '[:space:]' || printf '0')"

finish() {
  exit_code="$1"
  if [ "$debug" = true ]; then
    printf 'DEBUG: remote curl url: %s\n' "$url"
    printf 'DEBUG: remote curl status: %s\n' "$curl_status"
    printf 'DEBUG: remote raw HTTP code: %s\n' "$http_code"
    printf 'DEBUG: remote response body path: %s\n' "$response_file"
    printf 'DEBUG: remote response body bytes: %s\n' "$response_bytes"
    if [ -n "$response_error" ]; then
      printf 'DEBUG: remote curl stderr: %s\n' "$response_error"
    else
      printf 'DEBUG: remote curl stderr: (empty)\n'
    fi
    printf 'DEBUG: remote script exit code: %s\n' "$exit_code"
  fi
  rm -f "$response_file" "$error_file"
  exit "$exit_code"
}

if [ "$debug" = true ] && [ -n "$response_body" ]; then
  printf 'DEBUG: remote response body preview: %.200s\n' "$response_body"
fi

rm -f "$response_file" "$error_file"

if [ "$curl_status" -eq 0 ] && [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null && [ -n "$response_body" ]; then
  finish 0
fi

printf 'HTTP status: %s\n' "$http_code"
if [ -n "$response_body" ]; then
  printf 'Response body: %s\n' "$response_body"
fi
if [ -n "$response_error" ]; then
  printf 'curl error: %s\n' "$response_error"
fi

if printf '%s\n%s\n' "$response_body" "$response_error" | grep -Eiq 'context[^[:alnum:]]*(overflow|exceed|exceeded|full)|exceed[^[:alnum:]]*context|too many tokens'; then
  finish 20
fi

if [ "$http_code" = 503 ] \
  && printf '%s\n%s\n' "$response_body" "$response_error" | grep -Eiq 'Loading model|unavailable_error'; then
  finish 21
fi

finish 1
EOF
}

# --- LLaMA: unified status ---
section "LLaMA Status"

api_ok=false
vm_api_ok=false
vm_interface_ok=false
port_ok=false
process_ok=false
bind_failed=false
detect_managed_llama_mode
MANAGED_LLAMA_MODE="$REPLY"
MANAGED_LLAMA_SERVICE_NAME="$(managed_llama_service_name "$MANAGED_LLAMA_MODE")"
MANAGED_LLAMA_PLIST_PATH="$(llama_mode_plist_dest "$MANAGED_LLAMA_MODE")"
MANAGED_LLAMA_ENV_PATH="$(llama_mode_env_dest "$MANAGED_LLAMA_MODE")"

if $HOST_STATUS_EXPECTS_EXTERNAL; then
  if status_curl "$HOST_STATUS_LLAMA_MODELS_URL" >/dev/null 2>&1; then
    api_ok=true
    vm_api_ok=true
  fi
  if status_host_address_available "$HOST_IP"; then
    vm_interface_ok=true
  fi
else
  if status_curl "$HOST_STATUS_LOCAL_LLAMA_MODELS_URL" >/dev/null 2>&1; then
    api_ok=true
  fi
  if status_curl "$HOST_STATUS_LLAMA_MODELS_URL" >/dev/null 2>&1; then
    vm_api_ok=true
  fi
  if status_host_address_available "$HOST_IP"; then
    vm_interface_ok=true
  fi
fi

if port_open "$LLAMA_PORT"; then
  port_ok=true
fi

if llama_process_running; then
  process_ok=true
fi

if llama_log_contains "couldn't bind HTTP server socket"; then
  bind_failed=true
fi

if $api_ok && $HOST_STATUS_EXPECTS_EXTERNAL; then
  pass "llama-server is running (external instance - configured)"
  out "  Using externally managed instance at $HOST_STATUS_DISPLAY_URL"
  out "  ClawBox will not manage this process."

elif $api_ok && $port_ok && $process_ok; then
  if [ "$HOST_STATUS_LOCAL_LLAMA_BASE_URL" != "$HOST_STATUS_DISPLAY_URL" ]; then
    pass "llama-server is healthy through loopback"
    out "Local endpoint: $HOST_STATUS_LOCAL_LLAMA_BASE_URL/v1"
    if $vm_api_ok; then
      pass "VM-facing llama endpoint is reachable"
      out "VM-facing endpoint: $HOST_STATUS_DISPLAY_URL/v1"
    elif ! $vm_interface_ok; then
      warn_status "VM-facing llama endpoint is unavailable because the configured host interface is absent"
      out "VM-facing endpoint: $HOST_STATUS_DISPLAY_URL/v1"
      out "The UTM/VM host network interface may be offline because the selected VM is stopped."
    else
      fail "VM-facing llama endpoint is unavailable"
      out "VM-facing endpoint: $HOST_STATUS_DISPLAY_URL/v1"
      out "The local service is healthy; check VM networking and host firewall reachability."
    fi
  else
    pass "llama-server is healthy and owned by this user"
  fi

elif ! $api_ok && $port_ok && $process_ok && $bind_failed; then
  fail "llama-server conflict detected"
  out "  Another instance is already bound to this port."
  out "  Your LaunchAgent instance failed to start."
  out "  Fix: stop the other instance or choose a different port."

elif ! $api_ok && $process_ok && $bind_failed; then
  fail "llama-server failed to start (port bind error)"
  out "  No active API detected."
  out "  Likely cause: stale process or rapid restart conflict."
  out "  Fix: restart the service or check logs."

elif ! $api_ok && $process_ok; then
  fail "llama-server process exists but API is not responding"
  out "  Likely failed startup. Check logs below."

elif $api_ok && ! $process_ok; then
  fail "llama-server is running but not managed by this user"
  out "  An external instance is responding, but was not selected during setup."
  out "  Re-run setup and choose 'Use existing instance' to accept it."

else
  fail "llama-server is not running"
fi

# --- Launchd service ---
if ! $HOST_STATUS_EXPECTS_EXTERNAL; then
  section "$MANAGED_LLAMA_SERVICE_NAME"
  if managed_llama_service_loaded "$MANAGED_LLAMA_MODE"; then
    pass "$MANAGED_LLAMA_SERVICE_NAME is loaded"
  else
    fail "$MANAGED_LLAMA_SERVICE_NAME not loaded"
  fi

  # --- Launchd service file ---
  section "$MANAGED_LLAMA_SERVICE_NAME File"
  if [ -f "$MANAGED_LLAMA_PLIST_PATH" ]; then
    pass "plist exists"
  else
    fail "plist missing"
  fi

  # --- Runtime env ---
  section "Runtime Env"
  if [ -f "$MANAGED_LLAMA_ENV_PATH" ]; then
    pass "runtime env exists"
  else
    fail "runtime env missing"
  fi
fi

# --- Model summary ---
section "Primary Model"
PRIMARY_CONFIGURED_MODEL="${MODEL_PATH:-}"
PRIMARY_RUNTIME_MODEL=''
PRIMARY_PROCESS_ARGS=''
PRIMARY_RUNNING_MODEL=''
PRIMARY_OPENCLAW_REF="$OPENCLAW_PROVIDER_NAME/${OPENCLAW_DEFAULT_MODEL:-local}"
out "Configured: ${PRIMARY_CONFIGURED_MODEL:-not configured}"
out "API: ${CONFIGURED_LLAMA_BASE_URL:-${HOST_STATUS_DISPLAY_URL%/}/v1}"
out "OpenClaw: $PRIMARY_OPENCLAW_REF"

if ! $HOST_STATUS_EXPECTS_EXTERNAL; then
  PRIMARY_RUNTIME_MODEL="$(env_file_value "$MANAGED_LLAMA_ENV_PATH" MODEL_PATH 2>/dev/null || true)"
  if [ -n "$PRIMARY_RUNTIME_MODEL" ] && [ -n "$PRIMARY_CONFIGURED_MODEL" ] && [ "$PRIMARY_RUNTIME_MODEL" != "$PRIMARY_CONFIGURED_MODEL" ]; then
    fail "primary runtime env model differs from .env"
    out "  Runtime env: $PRIMARY_RUNTIME_MODEL"
  fi
fi

if $process_ok && PRIMARY_PROCESS_ARGS="$(status_process_args_for_port "$LLAMA_PORT" primary 2>/dev/null)" \
  && PRIMARY_RUNNING_MODEL="$(model_path_from_process_args "$PRIMARY_PROCESS_ARGS" 2>/dev/null)"; then
  out "Running: $(model_display_name "$PRIMARY_RUNNING_MODEL")"
  if ! $HOST_STATUS_EXPECTS_EXTERNAL && [ -n "$PRIMARY_CONFIGURED_MODEL" ] && [ "$PRIMARY_RUNNING_MODEL" != "$PRIMARY_CONFIGURED_MODEL" ]; then
    fail "primary running model differs from .env"
    out "  Running path: $PRIMARY_RUNNING_MODEL"
  elif ! $HOST_STATUS_EXPECTS_EXTERNAL; then
    pass "primary model matches configured runtime"
  fi
else
  out "Running: unknown"
fi

# --- Optional embeddings LLaMA ---
if [ "${EMBEDDINGS_ENABLED:-false}" = true ]; then
  EMBEDDINGS_MODE="$MANAGED_LLAMA_MODE"
  EMBEDDINGS_PLIST_PATH="$(embeddings_llama_mode_plist_dest "$EMBEDDINGS_MODE")"
  EMBEDDINGS_ENV_PATH="$(embeddings_llama_mode_env_dest "$EMBEDDINGS_MODE")"
  EMBEDDINGS_TARGET="$(embeddings_llama_mode_target "$EMBEDDINGS_MODE")"
  EMBEDDINGS_URL="${EMBEDDINGS_LLAMA_BASE_URL:-http://${HOST_IP}:${EMBEDDINGS_LLAMA_PORT:-11435}/v1}"

  section 'Embeddings Model'
  EMBEDDINGS_CONFIGURED_MODEL="${EMBEDDINGS_MODEL_PATH:-}"
  EMBEDDINGS_RUNTIME_MODEL=''
  EMBEDDINGS_PROCESS_ARGS=''
  EMBEDDINGS_RUNNING_MODEL=''
  EMBEDDINGS_MEMORY_MODEL=''
  out "Configured: ${EMBEDDINGS_CONFIGURED_MODEL:-not configured}"
  out "API: $EMBEDDINGS_URL"
  EMBEDDINGS_RUNTIME_MODEL="$(env_file_value "$EMBEDDINGS_ENV_PATH" EMBEDDINGS_MODEL_PATH 2>/dev/null || true)"
  if [ -n "$EMBEDDINGS_RUNTIME_MODEL" ] && [ -n "$EMBEDDINGS_CONFIGURED_MODEL" ] && [ "$EMBEDDINGS_RUNTIME_MODEL" != "$EMBEDDINGS_CONFIGURED_MODEL" ]; then
    fail "embeddings runtime env model differs from .env"
    out "  Runtime env: $EMBEDDINGS_RUNTIME_MODEL"
  fi
  if EMBEDDINGS_PROCESS_ARGS="$(status_process_args_for_port "${EMBEDDINGS_LLAMA_PORT:-11435}" embeddings 2>/dev/null)" \
    && EMBEDDINGS_RUNNING_MODEL="$(model_path_from_process_args "$EMBEDDINGS_PROCESS_ARGS" 2>/dev/null)"; then
    out "Running: $(model_display_name "$EMBEDDINGS_RUNNING_MODEL")"
    if [ -n "$EMBEDDINGS_CONFIGURED_MODEL" ] && [ "$EMBEDDINGS_RUNNING_MODEL" != "$EMBEDDINGS_CONFIGURED_MODEL" ]; then
      fail "embeddings running model differs from .env"
      out "  Running path: $EMBEDDINGS_RUNNING_MODEL"
    else
      pass "embeddings model matches configured runtime"
    fi
  else
    out "Running: unknown"
  fi
  if EMBEDDINGS_MEMORY_MODEL="$(vm_openclaw_config_get 'agents.defaults.memorySearch.model' 2>/dev/null)"; then
    out "OpenClaw memorySearch: $EMBEDDINGS_MEMORY_MODEL"
    if [ -n "$EMBEDDINGS_CONFIGURED_MODEL" ] && [ "$EMBEDDINGS_MEMORY_MODEL" != "$(basename "$EMBEDDINGS_CONFIGURED_MODEL")" ]; then
      fail "OpenClaw memorySearch model differs from embeddings model"
    fi
  else
    out "OpenClaw memorySearch: unavailable"
  fi

  section 'Embeddings LLaMA Status'
  if launchctl print "$EMBEDDINGS_TARGET" >/dev/null 2>&1; then pass 'Embeddings LaunchAgent/LaunchDaemon is loaded'; else fail 'Embeddings LaunchAgent/LaunchDaemon not loaded'; fi
  if [ -f "$EMBEDDINGS_PLIST_PATH" ]; then pass 'Embeddings plist exists'; else fail 'Embeddings plist missing'; fi
  if [ -f "$EMBEDDINGS_ENV_PATH" ]; then pass 'Embeddings runtime env exists'; else fail 'Embeddings runtime env missing'; fi
  if status_curl "${EMBEDDINGS_URL%/}/models" >/dev/null 2>&1; then
    pass "Embeddings llama-server is responding at $EMBEDDINGS_URL"
  else
    EMBEDDINGS_LOOPBACK_URL="$(embeddings_llama_local_base_url 2>/dev/null || printf 'http://127.0.0.1:%s/v1' "${EMBEDDINGS_LLAMA_PORT:-11435}")"
    if [ "$EMBEDDINGS_LOOPBACK_URL" != "$EMBEDDINGS_URL" ] \
      && status_curl "${EMBEDDINGS_LOOPBACK_URL%/}/models" >/dev/null 2>&1
    then
      pass "embeddings llama-server is healthy through loopback"
      out "Local endpoint: $EMBEDDINGS_LOOPBACK_URL"
      out "VM-facing endpoint: $EMBEDDINGS_URL"
      if [ "${EMBEDDINGS_LLAMA_HOST:-0.0.0.0}" = "0.0.0.0" ] && ! status_host_address_available "$HOST_IP"; then
        warn_status "VM-facing embeddings endpoint is unavailable because the configured host interface is absent"
        out 'The UTM/VM host network interface may be offline because the selected VM is stopped.'
      else
        fail "Embeddings llama-server is not responding at $EMBEDDINGS_URL"
        out 'Loopback responds, but the configured VM-facing endpoint does not.'
        out 'Restart/update embeddings setup only if the service is not bound to the configured host interface.'
      fi
    else
      fail "Embeddings llama-server is not responding at $EMBEDDINGS_URL"
    fi
  fi
fi

# --- SSH ---
section "VM SSH"
if vm_ssh_exec 'echo ok' >/dev/null 2>&1; then
  pass "SSH connectivity works"
else
  fail "SSH connectivity failed"
fi

if vm_autostart_configured; then
  section "VM Auto-start"
  VM_AUTOSTART_PLIST="$(vm_autostart_plist_path)"
  VM_AUTOSTART_WRAPPER="$(vm_autostart_wrapper_path)"
  VM_AUTOSTART_STDOUT_LOG="${CLAWBOX_VM_AUTOSTART_OUT_LOG:-$(clawbox_startutmvm_stdout_log_default)}"
  VM_AUTOSTART_STDERR_LOG="${CLAWBOX_VM_AUTOSTART_ERR_LOG:-$(clawbox_startutmvm_stderr_log_default)}"
  VM_AUTOSTART_LATEST_LOG_STATE=''

  if [ -f "$VM_AUTOSTART_PLIST" ]; then
    pass "VM auto-start plist exists"
  else
    warn_status "VM auto-start plist is missing"
  fi

  if [ -x "$VM_AUTOSTART_WRAPPER" ]; then
    pass "VM auto-start wrapper is executable"
  else
    warn_status "VM auto-start wrapper is missing or not executable"
  fi

  if vm_autostart_service_loaded; then
    pass "VM auto-start LaunchAgent is loaded"
  else
    warn_status "VM auto-start LaunchAgent is not loaded"
  fi

  out "Service: $(vm_autostart_service_target)"
  out "stdout: $VM_AUTOSTART_STDOUT_LOG"
  out "stderr: $VM_AUTOSTART_STDERR_LOG"
  VM_AUTOSTART_LATEST_LOG_STATE="$(vm_autostart_log_latest_state "$VM_AUTOSTART_STDOUT_LOG" "$VM_AUTOSTART_STDERR_LOG" 2>/dev/null || true)"
  case "$VM_AUTOSTART_LATEST_LOG_STATE" in
    success)
      pass "VM auto-start latest invocation succeeded"
      ;;
    failure)
      warn_status "VM auto-start latest invocation has warning or failure log entries"
      ;;
    started)
      warn_status "VM auto-start latest invocation has not reported VM readiness yet"
      ;;
  esac
fi

# --- Logs ---
section "Recent LLaMA Errors"
show_recent_llama_errors

# --- VM checks ---
section "VM OpenClaw Process"
if vm_openclaw_clawbox_launchd_gateway_running >/dev/null 2>&1; then
  pass "OpenClaw gateway is running"
  out 'OpenClaw runtime: managed by ClawBox LaunchAgent (com.clawbox.openclaw)'
elif vm_openclaw_native_launchd_gateway_running >/dev/null 2>&1; then
  pass "OpenClaw gateway is running"
  out 'OpenClaw runtime: managed by native OpenClaw LaunchAgent (ai.openclaw.gateway)'
elif vm_openclaw_process_gateway_running >/dev/null 2>&1; then
  pass "OpenClaw process is running"
elif vm_openclaw_native_process_gateway_running >/dev/null 2>&1; then
  pass "OpenClaw gateway is running"
  out 'OpenClaw runtime: native OpenClaw gateway process detected outside ClawBox management'
else
  fail "OpenClaw process NOT running"
fi

section "VM OpenClaw Config"
if vm_ssh_exec "jq -e --arg provider \"$OPENCLAW_PROVIDER_NAME\" '.models.providers[\$provider].baseUrl' ~/.openclaw/openclaw.json" >/dev/null 2>&1; then
  pass "OpenClaw config is valid"
else
  fail "OpenClaw config invalid or unreadable"
fi
if OPENCLAW_PROVIDER_MODELS="$(vm_openclaw_provider_models_get "$OPENCLAW_PROVIDER_NAME" 2>/dev/null)"; then
  while IFS=$'\t' read -r status_kind status_message; do
    [ -n "$status_kind" ] || continue
    case "$status_kind" in
      pass)
        pass "$status_message"
        ;;
      warn)
        warn_status "$status_message"
        ;;
    esac
  done <<EOF
$(status_openclaw_provider_models_report "$OPENCLAW_PROVIDER_MODELS" "${OPENCLAW_DEFAULT_MODEL:-local}" 2>/dev/null || true)
EOF
else
  warn_status "OpenClaw provider model array is unavailable"
fi

section "Context and Token Budget"
STATUS_CONFIGURED_CONTEXT="${LLAMA_CTX:-}"
STATUS_NATIVE_CONTEXT=''
STATUS_PROPS_JSON=''
STATUS_SLOTS_JSON=''
STATUS_RUNTIME_CONTEXT=''
STATUS_TOTAL_SLOTS=''
STATUS_SLOT_COUNT=''
STATUS_SLOT_CONTEXT=''
STATUS_SLOT_CONTEXT_VALID=true
STATUS_OPENCLAW_CONTEXT=''
STATUS_OPENCLAW_MAX_TOKENS=''
STATUS_RESERVE_TOKENS=''
STATUS_RESERVE_TOKENS_FLOOR=''
STATUS_PROMPT_BUDGET=''

if [ -n "${MODEL_PATH:-}" ]; then
  STATUS_NATIVE_CONTEXT="$(gguf_native_context_from_file "$MODEL_PATH" 2>/dev/null || true)"
fi

STATUS_PROPS_JSON="$(status_llama_runtime_json props 2>/dev/null || true)"
STATUS_SLOTS_JSON="$(status_llama_runtime_json slots 2>/dev/null || true)"
if [ -n "$STATUS_PROPS_JSON" ]; then
  STATUS_RUNTIME_CONTEXT="$(status_json_value "$STATUS_PROPS_JSON" runtime_context 2>/dev/null || true)"
  STATUS_TOTAL_SLOTS="$(status_json_value "$STATUS_PROPS_JSON" total_slots 2>/dev/null || true)"
fi
if [ -n "$STATUS_SLOTS_JSON" ]; then
  STATUS_SLOT_COUNT="$(llama_runtime_slot_count_from_slots_json "$STATUS_SLOTS_JSON" 2>/dev/null || true)"
  if ! STATUS_SLOT_CONTEXT="$(llama_runtime_slot_context_from_slots_json "$STATUS_SLOTS_JSON" 2>/dev/null)"; then
    STATUS_SLOT_CONTEXT=''
    STATUS_SLOT_CONTEXT_VALID=false
  fi
  [ -n "$STATUS_TOTAL_SLOTS" ] || STATUS_TOTAL_SLOTS="$STATUS_SLOT_COUNT"
fi
if [ -z "$STATUS_RUNTIME_CONTEXT" ]; then
  STATUS_RUNTIME_CONTEXT="$STATUS_SLOT_CONTEXT"
fi

if [ -n "${OPENCLAW_PROVIDER_MODELS:-}" ]; then
  STATUS_OPENCLAW_CONTEXT="$(status_openclaw_model_numeric_field "$OPENCLAW_PROVIDER_MODELS" "${OPENCLAW_DEFAULT_MODEL:-local}" contextWindow 2>/dev/null || true)"
  STATUS_OPENCLAW_MAX_TOKENS="$(status_openclaw_model_numeric_field "$OPENCLAW_PROVIDER_MODELS" "${OPENCLAW_DEFAULT_MODEL:-local}" maxTokens 2>/dev/null || true)"
fi
STATUS_RESERVE_TOKENS="$(vm_openclaw_config_get 'agents.defaults.compaction.reserveTokens' 2>/dev/null || true)"
STATUS_RESERVE_TOKENS_FLOOR="$(vm_openclaw_config_get 'agents.defaults.compaction.reserveTokensFloor' 2>/dev/null || true)"

out "Model native context: ${STATUS_NATIVE_CONTEXT:-unknown}"
out "Configured LLAMA_CTX: ${STATUS_CONFIGURED_CONTEXT:-unknown}"
out "Runtime context: ${STATUS_RUNTIME_CONTEXT:-unknown}"
out "Parallel slots: ${STATUS_TOTAL_SLOTS:-${LLAMA_PARALLEL:-unknown}}"
out "Per-slot context: ${STATUS_SLOT_CONTEXT:-unknown}"
out "OpenClaw contextWindow: ${STATUS_OPENCLAW_CONTEXT:-unknown}"
out "OpenClaw maxTokens: ${STATUS_OPENCLAW_MAX_TOKENS:-${OPENCLAW_MAX_TOKENS:-unknown}}"
out "Compaction reserveTokens: ${STATUS_RESERVE_TOKENS:-unknown}"
out "Compaction reserveTokensFloor: ${STATUS_RESERVE_TOKENS_FLOOR:-unknown}"

if clawbox_positive_integer "${STATUS_OPENCLAW_CONTEXT:-}" && clawbox_positive_integer "${STATUS_RESERVE_TOKENS:-}"; then
  STATUS_PROMPT_BUDGET=$((STATUS_OPENCLAW_CONTEXT - STATUS_RESERVE_TOKENS))
  out "Prompt budget before reserve: $STATUS_PROMPT_BUDGET"
else
  out "Prompt budget before reserve: unknown"
fi

if [ -n "${MODEL_PATH:-}" ] && [ -f "$MODEL_PATH" ] && [ -z "$STATUS_NATIVE_CONTEXT" ]; then
  warn_status "GGUF native context metadata is unavailable"
fi

if clawbox_positive_integer "${STATUS_CONFIGURED_CONTEXT:-}" && clawbox_positive_integer "${STATUS_RUNTIME_CONTEXT:-}" \
  && [ "$STATUS_CONFIGURED_CONTEXT" -ne "$STATUS_RUNTIME_CONTEXT" ]; then
  fail "llama-server runtime context differs from configured LLAMA_CTX"
elif clawbox_positive_integer "${STATUS_RUNTIME_CONTEXT:-}" && clawbox_positive_integer "${STATUS_OPENCLAW_CONTEXT:-}" \
  && [ "$STATUS_OPENCLAW_CONTEXT" -ne "$STATUS_RUNTIME_CONTEXT" ]; then
  fail "OpenClaw contextWindow differs from effective llama-server runtime context"
elif clawbox_positive_integer "${STATUS_RUNTIME_CONTEXT:-}" && clawbox_positive_integer "${STATUS_OPENCLAW_CONTEXT:-}" \
  && [ "$STATUS_OPENCLAW_CONTEXT" -eq "$STATUS_RUNTIME_CONTEXT" ]; then
  pass "OpenClaw contextWindow matches effective llama-server runtime context"
fi

if clawbox_positive_integer "${LLAMA_PARALLEL:-}" && clawbox_positive_integer "${STATUS_TOTAL_SLOTS:-}" \
  && [ "$LLAMA_PARALLEL" -ne "$STATUS_TOTAL_SLOTS" ]; then
  fail "llama-server total_slots differs from configured LLAMA_PARALLEL"
fi

if [ -z "$STATUS_PROPS_JSON" ] || [ -z "$STATUS_SLOTS_JSON" ]; then
  out "Runtime API validation: incomplete (/props or /slots unavailable)"
elif [ "$STATUS_SLOT_CONTEXT_VALID" != true ]; then
  fail "llama-server slot contexts are unavailable or inconsistent"
elif clawbox_positive_integer "${STATUS_TOTAL_SLOTS:-}" && clawbox_positive_integer "${STATUS_SLOT_COUNT:-}" \
  && [ "$STATUS_TOTAL_SLOTS" -ne "$STATUS_SLOT_COUNT" ]; then
  fail "llama-server total_slots does not match returned slot count"
elif clawbox_positive_integer "${STATUS_RUNTIME_CONTEXT:-}" && clawbox_positive_integer "${STATUS_SLOT_CONTEXT:-}" \
  && [ "$STATUS_RUNTIME_CONTEXT" -ne "$STATUS_SLOT_CONTEXT" ]; then
  fail "llama-server /props context does not match per-slot context"
elif clawbox_positive_integer "${STATUS_CONFIGURED_CONTEXT:-}" && clawbox_positive_integer "${STATUS_SLOT_CONTEXT:-}" \
  && [ "$STATUS_CONFIGURED_CONTEXT" -ne "$STATUS_SLOT_CONTEXT" ]; then
  fail "llama-server slot context differs from configured LLAMA_CTX"
else
  pass "llama-server runtime context evidence is internally consistent"
fi

if clawbox_positive_integer "${STATUS_OPENCLAW_CONTEXT:-}" && clawbox_positive_integer "${STATUS_OPENCLAW_MAX_TOKENS:-}" \
  && [ "$STATUS_OPENCLAW_MAX_TOKENS" -ge "$STATUS_OPENCLAW_CONTEXT" ]; then
  fail "OpenClaw maxTokens is not less than contextWindow"
fi
if clawbox_positive_integer "${STATUS_OPENCLAW_CONTEXT:-}" && clawbox_positive_integer "${STATUS_RESERVE_TOKENS:-}" \
  && [ "$STATUS_RESERVE_TOKENS" -ge "$STATUS_OPENCLAW_CONTEXT" ]; then
  fail "OpenClaw reserveTokens is not less than contextWindow"
fi
if clawbox_positive_integer "${STATUS_OPENCLAW_CONTEXT:-}" && clawbox_positive_integer "${STATUS_RESERVE_TOKENS_FLOOR:-}" \
  && [ "$STATUS_RESERVE_TOKENS_FLOOR" -ge "$STATUS_OPENCLAW_CONTEXT" ]; then
  fail "OpenClaw reserveTokensFloor is not less than contextWindow"
fi

section "VM → Host LLaMA (API)"
if vm_ssh_exec "curl $VM_STATUS_CURL_ARGS $VM_LLAMA_BASE_URL/models" >/dev/null 2>&1; then
  pass "VM can reach host llama"
else
  fail "VM cannot reach host llama"
fi

section "VM → Host LLaMA (Inference)"
vm_inference_output=''
if vm_inference_output="$(vm_llama_inference_probe 2>&1)"; then
  pass "VM inference request succeeded"
  if [ "$STATUS_DEBUG" = true ] && [ -n "$vm_inference_output" ]; then
    out "$vm_inference_output"
  fi
else
  vm_inference_status=$?
  if [ "$vm_inference_status" -eq 20 ]; then
    fail "VM inference request failed: llama context overflow"
  elif [ "$vm_inference_status" -eq 21 ]; then
    wait_status "host llama-server is still loading the model"
    out 'Retry ./clawbox status shortly.'
  else
    fail "VM inference request failed"
  fi

  if [ -n "$vm_inference_output" ]; then
    out "$vm_inference_output"
  fi
fi

# --- Summary ---
blank_line
out "========================================="
if [ "$fail_count" -eq 0 ] && [ "$wait_count" -eq 0 ] && [ "$warn_count" -eq 0 ]; then
  out "RESULT: HEALTHY"
elif [ "$fail_count" -eq 0 ] && [ "$wait_count" -eq 0 ]; then
  out "RESULT: HEALTHY WITH WARNINGS ($warn_count warnings)"
elif [ "$fail_count" -eq 0 ]; then
  out "RESULT: WAITING ($wait_count temporary issues)"
else
  out "RESULT: UNHEALTHY ($fail_count issues)"
fi
out "========================================="
blank_line

exit $((fail_count + wait_count))
