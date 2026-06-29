#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/log-paths.sh"
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

fail() {
  out "FAIL: $1"
  fail_count=$((fail_count + 1))
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
  vm_ssh_exec "openclaw config get $key"
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

finish 1
EOF
}

# --- LLaMA: unified status ---
section "LLaMA Status"

api_ok=false
port_ok=false
process_ok=false
bind_failed=false
detect_managed_llama_mode
MANAGED_LLAMA_MODE="$REPLY"
MANAGED_LLAMA_SERVICE_NAME="$(managed_llama_service_name "$MANAGED_LLAMA_MODE")"
MANAGED_LLAMA_PLIST_PATH="$(llama_mode_plist_dest "$MANAGED_LLAMA_MODE")"
MANAGED_LLAMA_ENV_PATH="$(llama_mode_env_dest "$MANAGED_LLAMA_MODE")"

if status_curl "$HOST_STATUS_LLAMA_MODELS_URL" >/dev/null 2>&1; then
  api_ok=true
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

elif $api_ok && $port_ok && $process_ok && ! $bind_failed; then
  pass "llama-server is healthy and owned by this user"

elif $api_ok && $bind_failed; then
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
  if status_curl "${EMBEDDINGS_URL%/}/models" >/dev/null 2>&1; then pass "Embeddings llama-server is responding at $EMBEDDINGS_URL"; else fail "Embeddings llama-server is not responding at $EMBEDDINGS_URL"; fi
fi

# --- SSH ---
section "VM SSH"
if vm_ssh_exec 'echo ok' >/dev/null 2>&1; then
  pass "SSH connectivity works"
else
  fail "SSH connectivity failed"
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
if [ "$fail_count" -eq 0 ]; then
  out "RESULT: HEALTHY"
else
  out "RESULT: UNHEALTHY ($fail_count issues)"
fi
out "========================================="
blank_line

exit "$fail_count"
