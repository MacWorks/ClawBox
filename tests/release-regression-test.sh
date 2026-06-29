#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

# shellcheck source=/dev/null
. "$ROOT_DIR/tests/helpers/setup-harness.sh"

TEMP_DIR="$(mktemp -d)"
ENV_BACKUP=""

cleanup_release_regression() {
  if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
    cp "$ENV_BACKUP" "$ENV_FILE"
    rm -f "$ENV_BACKUP"
  fi

  cleanup_temp_dir
}

trap cleanup_release_regression EXIT

if [ -f "$ENV_FILE" ]; then
  ENV_BACKUP="$(mktemp)"
  cp "$ENV_FILE" "$ENV_BACKUP"
fi

prepare_status_test_home() {
  export HOME="$TEMP_DIR/home"
  rm -rf "$HOME"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/ClawBox"
  : > "$HOME/Library/LaunchAgents/com.clawbox.llama.plist"
  : > "$HOME/Library/Application Support/ClawBox/clawbox.env"
}

prepare_status_test_home_for_system_mode() {
  export HOME="$TEMP_DIR/home-system"
  rm -rf "$HOME"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/ClawBox"
}

write_status_test_env() {
  local llama_external="${1:-false}"

  cat > "$ENV_FILE" <<EOF
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="http://127.0.0.1:18080/v1"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_DEFAULT_MODEL="model"
LLAMA_EXTERNAL="$llama_external"
EOF
}

setup_status_test_mocks() {
  setup_mock_bin_dir
  unset CLAWBOX_TEST_STATUS_LAUNCHCTL_LIST_OUTPUT
  unset CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_TARGET
  unset CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_EXIT_CODE
  unset CLAWBOX_TEST_STATUS_LAUNCHCTL_LOG
  unset CLAWBOX_TEST_STATUS_CURL_LOG
  unset CLAWBOX_TEST_STATUS_PROCESS_ARGS_OUTPUT
  unset CLAWBOX_TEST_STATUS_PROCESS_ARGS_EMBEDDINGS_OUTPUT
  unset CLAWBOX_TEST_SSH_LOG
  unset CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_OUTPUT
  unset CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_EXIT_CODE
  unset CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_OUTPUT
  unset CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_EXIT_CODE
  unset CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_PROCESS_EXIT_CODE
  unset CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_REAL_FILE
  unset CLAWBOX_TEST_SSH_OPENCLAW_MEMORY_MODEL
  unset CLAWBOX_TEST_SSH_OPENCLAW_MEMORY_MODEL_EXIT_CODE
  unset CLAWBOX_TEST_SSH_VM_COMPLETION_EXIT_CODE
  unset CLAWBOX_TEST_SSH_VM_COMPLETION_OUTPUT
  unset CLAWBOX_TEST_SSH_VM_COMPLETION_HTTP_CODE
  unset CLAWBOX_TEST_SSH_VM_COMPLETION_BODY
  unset CLAWBOX_TEST_SSH_VM_COMPLETION_ERROR
  unset CLAWBOX_LLAMA_PLIST_DEST
  unset CLAWBOX_LLAMA_ENV_DEST
  unset CLAWBOX_LLAMA_USER_ERR_LOG
  unset CLAWBOX_LLAMA_ERR_LOG
  export CLAWBOX_STATUS_PORT_OPEN_CMD="$MOCK_BIN_DIR/mock-port-open"
  export CLAWBOX_STATUS_PROCESS_CHECK_CMD="$MOCK_BIN_DIR/mock-process-check"
  export CLAWBOX_STATUS_PROCESS_ARGS_CMD="$MOCK_BIN_DIR/mock-process-args"

  write_mock_command mock-port-open '#!/bin/bash
exit "${CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE:-0}"
'

  write_mock_command mock-process-check '#!/bin/bash
exit "${CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE:-0}"
'

  write_mock_command mock-process-args '#!/bin/bash
port="${1:-18080}"
instance="${2:-primary}"
case "$instance" in
  embeddings)
    if [ -n "${CLAWBOX_TEST_STATUS_PROCESS_ARGS_EMBEDDINGS_OUTPUT:-}" ]; then
      printf "%s\n" "$CLAWBOX_TEST_STATUS_PROCESS_ARGS_EMBEDDINGS_OUTPUT"
    else
      printf "/opt/homebrew/bin/llama-server -m /Users/vm-user/models/embed.gguf --host 0.0.0.0 --port %s --ctx-size 8192 --embedding\n" "$port"
    fi
    ;;
  *)
    if [ -n "${CLAWBOX_TEST_STATUS_PROCESS_ARGS_OUTPUT:-}" ]; then
      printf "%s\n" "$CLAWBOX_TEST_STATUS_PROCESS_ARGS_OUTPUT"
    else
      printf "/opt/homebrew/bin/llama-server -m /Users/vm-user/models/model.gguf --host 0.0.0.0 --port %s --ctx-size 32768\n" "$port"
    fi
    ;;
esac
'

  write_mock_command curl '#!/bin/bash
if [ -n "${CLAWBOX_TEST_STATUS_CURL_LOG:-}" ]; then
  printf "%s\n" "$*" >> "$CLAWBOX_TEST_STATUS_CURL_LOG"
fi
exit "${CLAWBOX_TEST_STATUS_CURL_EXIT_CODE:-0}"
'

  write_mock_command launchctl '#!/bin/bash
if [ -n "${CLAWBOX_TEST_STATUS_LAUNCHCTL_LOG:-}" ]; then
  printf "%s\n" "$*" >> "$CLAWBOX_TEST_STATUS_LAUNCHCTL_LOG"
fi

if [ "${1:-}" = "list" ]; then
  printf "%s\n" "${CLAWBOX_TEST_STATUS_LAUNCHCTL_LIST_OUTPUT:-123\t0\tcom.clawbox.llama}"
  exit 0
fi

if [ "${1:-}" = "print" ]; then
  target="${2:-}"
  if [ -n "${CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_TARGET:-}" ]; then
    if [ "$target" = "$CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_TARGET" ]; then
      exit "${CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_EXIT_CODE:-0}"
    fi
    exit 1
  fi

  case "$target" in
    gui/*/com.clawbox.llama|system/com.clawbox.llama|gui/*/com.clawbox.llama.embeddings|system/com.clawbox.llama.embeddings)
      exit "${CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_EXIT_CODE:-0}"
      ;;
  esac

  exit 1
fi
exit 0
'

  write_mock_command ssh '#!/bin/bash
if [ -n "${CLAWBOX_TEST_SSH_LOG:-}" ]; then
  printf "%s\n" "$*" >> "$CLAWBOX_TEST_SSH_LOG"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-i|-p)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      break
      ;;
  esac
done

target="${1:-}"
shift || true
  remote_command="$*"

  case "$remote_command" in
    echo\ ok)
      exit "${CLAWBOX_TEST_SSH_ECHO_EXIT_CODE:-0}"
      ;;
    *"launchctl print \"gui/"*"ai.openclaw.gateway"*)
      if [ "${CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_EXIT_CODE:-1}" -ne 0 ]; then
        exit "${CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_EXIT_CODE:-1}"
      fi
      printf "%s\n" "${CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_OUTPUT:-}"
      launchd_output="${CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_OUTPUT:-}"
      if printf "%s\n" "$launchd_output" | grep -Eq "^[[:space:]]*(state|job state) = running[[:space:]]*$" \
        && printf "%s\n" "$launchd_output" | grep -Eq "^[[:space:]]*pid = [0-9]+" \
        && printf "%s\n" "$launchd_output" | grep -Fq "openclaw" \
        && printf "%s\n" "$launchd_output" | grep -Eq "(^|[[:space:]])gateway([[:space:]]|$)"; then
        exit 0
      fi
      exit 1
      ;;
    *"launchctl print \"gui/"*"com.clawbox.openclaw"*)
      if [ "${CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_EXIT_CODE:-1}" -ne 0 ]; then
        exit "${CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_EXIT_CODE:-1}"
      fi
      printf "%s\n" "${CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_OUTPUT:-}"
      launchd_output="${CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_OUTPUT:-}"
      if printf "%s\n" "$launchd_output" | grep -Eq "^[[:space:]]*(state|job state) = running[[:space:]]*$" \
        && printf "%s\n" "$launchd_output" | grep -Eq "^[[:space:]]*pid = [0-9]+" \
        && printf "%s\n" "$launchd_output" | grep -Fq "openclaw" \
        && printf "%s\n" "$launchd_output" | grep -Eq "(^|[[:space:]])gateway([[:space:]]|$)"; then
        exit 0
      fi
      exit 1
      ;;
    *\$0\ \~\ /openclaw/*)
      exit "${CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_PROCESS_EXIT_CODE:-1}"
      ;;
    *"ps -axo pid=,comm=,args= | awk "*)
      exit "${CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE:-0}"
      ;;
  *"pgrep -fl openclaw"*)
    exit "${CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE:-0}"
    ;;
    *"openclaw.json"*)
    if [ -n "${CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_REAL_FILE:-}" ]; then
      translated_command="$remote_command"
      translated_command="${translated_command//\~\/\.openclaw\/openclaw\.json/$CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_REAL_FILE}"
      /bin/bash -c "$translated_command" >/dev/null 2>&1
      exit $?
    fi
    exit "${CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE:-0}"
    ;;
    *"openclaw config get agents.defaults.memorySearch.model"*)
      if [ "${CLAWBOX_TEST_SSH_OPENCLAW_MEMORY_MODEL_EXIT_CODE:-0}" -ne 0 ]; then
        exit "${CLAWBOX_TEST_SSH_OPENCLAW_MEMORY_MODEL_EXIT_CODE:-0}"
      fi
      printf "%s\n" "${CLAWBOX_TEST_SSH_OPENCLAW_MEMORY_MODEL:-embed.gguf}"
      exit 0
      ;;
    *"sh -s -- "*"/completion"*)
      script_body="$(cat)"
      if [ -n "${CLAWBOX_TEST_SSH_LOG:-}" ]; then
        printf "%s\n" "$script_body" >> "$CLAWBOX_TEST_SSH_LOG"
      fi
      if [ -n "${CLAWBOX_TEST_SSH_VM_COMPLETION_OUTPUT:-}" ]; then
        printf "%s\n" "$CLAWBOX_TEST_SSH_VM_COMPLETION_OUTPUT"
        exit "${CLAWBOX_TEST_SSH_VM_COMPLETION_EXIT_CODE:-${CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE:-0}}"
      fi
      http_code="${CLAWBOX_TEST_SSH_VM_COMPLETION_HTTP_CODE:-200}"
      response_body="${CLAWBOX_TEST_SSH_VM_COMPLETION_BODY:-{\"content\":\"pong\"}}"
      response_error="${CLAWBOX_TEST_SSH_VM_COMPLETION_ERROR:-}"
      if [ "${CLAWBOX_TEST_SSH_VM_COMPLETION_EXIT_CODE:-0}" -eq 0 ] \
        && [ "$http_code" -ge 200 ] 2>/dev/null \
        && [ "$http_code" -lt 300 ] 2>/dev/null \
        && [ -n "$response_body" ]; then
        exit 0
      fi
      printf "HTTP status: %s\n" "$http_code"
      if [ -n "$response_body" ]; then
        printf "Response body: %s\n" "$response_body"
      fi
      if [ -n "$response_error" ]; then
        printf "curl error: %s\n" "$response_error"
      fi
      if printf "%s\n%s\n" "$response_body" "$response_error" | grep -Eiq "context[^[:alnum:]]*(overflow|exceed|exceeded|full)|exceed[^[:alnum:]]*context|too many tokens"; then
        exit 20
      fi
      exit 1
      ;;
    *"/v1/models"*)
      exit "${CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE:-0}"
      ;;
    *"/v1/responses"*)
      exit "${CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE:-1}"
      ;;
  *)
    exit 1
    ;;
esac
'
}

test_provisioning_fallback_uses_public_setup_command() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs
    queue_prompt_answers 'n'
    NEEDS_PROVISIONING=true
    VM_RUNTIME_PATH='/Users/tester/ClawBox'

    if ensure_openclaw_provisioned; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
  } 2>&1)"

  assert_contains 'provisioning fallback prompts for vm-local completion' "$output" 'Provisioning completed inside the VM? [Y/n]:'
  assert_contains 'provisioning fallback uses public setup command' "$output" '  ./clawbox setup'
  assert_not_contains 'provisioning fallback no longer tells users to run setup.sh directly' "$output" 'Then re-run setup.sh on the host.'
  assert_contains 'provisioning fallback still exits gracefully' "$output" 'STATUS:42'
}

test_post_provisioning_offers_onboarding_with_configured_ssh_target() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs
    queue_prompt_answers 'y' 'n'
    NEEDS_PROVISIONING=true
    VM_HOST='vm-user@192.168.64.2'
    VM_RUNTIME_PATH='/Users/vm-user/ClawBox'

    detect_openclaw_runtime_state() {
      NEEDS_PROVISIONING=false
      IS_RUNNING=false
    }

    ensure_openclaw_provisioned
  } 2>&1)"

  assert_contains 'post-provisioning onboarding explains why it is offered' "$output" 'OpenClaw onboarding has not yet been completed.'
  assert_contains 'post-provisioning onboarding prompts before running' "$output" 'Run onboarding now? [Y/n]:'
  assert_contains 'post-provisioning onboarding prints the configured SSH command when declined' "$output" "ssh -t vm-user@192.168.64.2 'zsh -lc \"openclaw onboard\"'"
}

test_post_provisioning_onboarding_runs_only_after_confirmation() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs
    queue_prompt_answers 'y' 'y'
    NEEDS_PROVISIONING=true
    VM_HOST='vm-user@192.168.64.2'
    VM_RUNTIME_PATH='/Users/vm-user/ClawBox'

    detect_openclaw_runtime_state() {
      NEEDS_PROVISIONING=false
      IS_RUNNING=false
    }

    ssh() {
      printf 'SSH:%s\n' "$*"
    }

    ensure_openclaw_provisioned
  } 2>&1)"

  assert_contains 'post-provisioning onboarding uses an interactive SSH session after confirmation' "$output" 'SSH:-t vm-user@192.168.64.2 zsh -lc "openclaw onboard"'
  assert_contains 'post-provisioning onboarding reports completion after successful SSH command' "$output" 'OpenClaw onboarding completed.'
}

test_status_avoids_duplicate_vm_host_api_failure() {
  local output
  local status=0

  export HOME="$TEMP_DIR/home"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/ClawBox"
  : > "$HOME/Library/LaunchAgents/com.clawbox.llama.plist"
  : > "$HOME/Library/Application Support/ClawBox/clawbox.env"

  cat > "$ENV_FILE" <<'EOF'
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
VM_RUNTIME_PATH="/Users/vm-user/ClawBox"
LLAMA_PORT="18080"
LLAMA_BASE_URL="http://127.0.0.1:18080/v1"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_DEFAULT_MODEL="model"
LLAMA_EXTERNAL="false"
EOF

  setup_mock_bin_dir
  export CLAWBOX_STATUS_PORT_OPEN_CMD="$MOCK_BIN_DIR/mock-port-open"
  export CLAWBOX_STATUS_PROCESS_CHECK_CMD="$MOCK_BIN_DIR/mock-process-check"

  write_mock_command mock-port-open '#!/bin/bash
exit 0
'

  write_mock_command mock-process-check '#!/bin/bash
exit 0
'

  write_mock_command curl '#!/bin/bash
exit 0
'

  write_mock_command launchctl '#!/bin/bash
if [ "${1:-}" = "list" ]; then
  printf "123\t0\tcom.clawbox.llama\n"
fi
exit 0
'

  write_mock_command ssh '#!/bin/bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-i|-p)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      break
      ;;
  esac
done

target="${1:-}"
shift || true
remote_command="$*"

case "$remote_command" in
  echo\ ok)
    exit 0
    ;;
  *"ps -axo pid=,comm=,args= | awk "*)
    exit 0
    ;;
  *"pgrep -fl openclaw"*)
    exit 0
    ;;
  *"openclaw.json"*)
    exit 0
    ;;
  *"/v1/models"*)
    exit 1
    ;;
  *"/completion"*)
    exit 1
    ;;
  *"/v1/responses"*)
    exit 1
    ;;
  *)
    exit 1
    ;;
esac
'

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status exits with one API failure and one inference failure' "$status" '2'
  assert_equals 'status reports VM-to-host llama API failure once' "$(printf '%s\n' "$output" | /usr/bin/grep -Fc 'FAIL: VM cannot reach host llama')" '1'
  assert_contains 'status still reports inference failure separately' "$output" 'FAIL: VM inference request failed'
  assert_contains 'status summary reflects unique failure count' "$output" 'RESULT: UNHEALTHY (2 issues)'
}

test_status_reports_bind_failure_without_double_counting() {
  local output
  local status=0
  local bind_log="$TEMP_DIR/llama-bind.err.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$bind_log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/unused-system.err.log"

  cat > "$bind_log" <<'EOF'
GGML_ASSERT failure details
couldn't bind HTTP server socket
EOF

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status exits with a single bind-conflict failure' "$status" '1'
  assert_equals 'status reports bind conflict once' "$(printf '%s\n' "$output" | /usr/bin/grep -Fc 'FAIL: llama-server conflict detected')" '1'
  assert_not_contains 'status bind conflict path does not also report the generic process-not-responding failure' "$output" 'FAIL: llama-server process exists but API is not responding'
  assert_not_contains 'status bind conflict path does not also report the failed-startup bind branch' "$output" 'FAIL: llama-server failed to start (port bind error)'
  assert_contains 'status bind conflict path explains the remediation' "$output" 'Fix: stop the other instance or choose a different port.'
  assert_contains 'status bind conflict path emits the recent error log path' "$output" "From $bind_log:"
  assert_contains 'status bind conflict path shows the recent bind error line' "$output" "couldn't bind HTTP server socket"
  assert_contains 'status bind conflict path reports a single unhealthy issue in the summary' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_reports_external_instance_as_configured_when_api_and_port_are_healthy() {
  local output
  local status=0
  local curl_log="$TEMP_DIR/status-external-instance-curl.log"
  local configured_base_url='http://host.internal:19090/custom/v1'

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<EOF
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="$configured_base_url"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_DEFAULT_MODEL="model"
LLAMA_EXTERNAL="true"
EOF

  export CLAWBOX_TEST_STATUS_CURL_LOG="$curl_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/no-user-log.err"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/no-system-log.err"

  rm -f "$curl_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status external-instance path exits healthy' "$status" '0'
  assert_contains 'status external-instance path uses the configured base url for host-side health' "$([ -f "$curl_log" ] && cat "$curl_log")" "--connect-timeout 1 --max-time 2 $configured_base_url/models"
  assert_not_contains 'status external-instance path does not reconstruct host-side health from host ip and port' "$([ -f "$curl_log" ] && cat "$curl_log")" 'http://127.0.0.1:18080/v1/models'
  assert_contains 'status external-instance path reports the configured external instance' "$output" 'PASS: llama-server is running (external instance - configured)'
  assert_contains 'status external-instance path shows the configured base url' "$output" "Using externally managed instance at $configured_base_url"
  assert_contains 'status external-instance path explains that ClawBox will not manage the process' "$output" 'ClawBox will not manage this process.'
  assert_not_contains 'status external-instance path does not report unmanaged-instance failure' "$output" 'FAIL: llama-server is running but not managed by this user'
  assert_contains 'status external-instance path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_external_instance_ignores_local_port_when_configured_api_is_healthy() {
  local output
  local status=0
  local curl_log="$TEMP_DIR/status-external-instance-port-ignored-curl.log"
  local configured_base_url='http://host.internal:19090/custom/v1'

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<EOF
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="$configured_base_url"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_DEFAULT_MODEL="model"
LLAMA_EXTERNAL="true"
EOF

  export CLAWBOX_TEST_STATUS_CURL_LOG="$curl_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/external-port-ignored-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/external-port-ignored-system.err.log"

  rm -f "$curl_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status external-instance port-ignored path exits healthy when the configured api responds' "$status" '0'
  assert_contains 'status external-instance port-ignored path still probes the configured external api' "$([ -f "$curl_log" ] && cat "$curl_log")" "--connect-timeout 1 --max-time 2 $configured_base_url/models"
  assert_contains 'status external-instance port-ignored path reports the configured external instance' "$output" 'PASS: llama-server is running (external instance - configured)'
  assert_contains 'status external-instance port-ignored path shows the configured endpoint' "$output" "Using externally managed instance at $configured_base_url"
  assert_not_contains 'status external-instance port-ignored path does not fall back to the unmanaged-instance failure' "$output" 'FAIL: llama-server is running but not managed by this user'
  assert_not_contains 'status external-instance port-ignored path does not fall through to the not-running failure' "$output" 'FAIL: llama-server is not running'
}

test_status_external_instance_does_not_require_local_managed_artifacts() {
  local output
  local status=0
  local configured_base_url='http://host.internal:19090/custom/v1'

  export HOME="$TEMP_DIR/home-external-unmanaged"
  rm -rf "$HOME"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/ClawBox"
  setup_status_test_mocks

  cat > "$ENV_FILE" <<EOF
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="$configured_base_url"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_DEFAULT_MODEL="model"
LLAMA_EXTERNAL="true"
EOF

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/external-unmanaged-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/external-unmanaged-system.err.log"

  rm -f \
    "$HOME/Library/LaunchAgents/com.clawbox.llama.plist" \
    "$HOME/Library/Application Support/ClawBox/clawbox.env" \
    "$CLAWBOX_LLAMA_USER_ERR_LOG" \
    "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status external-instance without local artifacts exits healthy' "$status" '0'
  assert_contains 'status external-instance without local artifacts reports the configured external instance' "$output" 'PASS: llama-server is running (external instance - configured)'
  assert_not_contains 'status external-instance without local artifacts does not require a launch agent' "$output" 'FAIL: LaunchAgent not loaded'
  assert_not_contains 'status external-instance without local artifacts does not require a plist' "$output" 'FAIL: plist missing'
  assert_not_contains 'status external-instance without local artifacts does not require a runtime env file' "$output" 'FAIL: runtime env missing'
  assert_contains 'status external-instance without local artifacts reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_reports_owned_healthy_instance_when_api_port_and_process_are_healthy() {
  local output
  local status=0
  local curl_log="$TEMP_DIR/status-owned-healthy-curl.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_CURL_LOG="$curl_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/owned-healthy-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/owned-healthy-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$curl_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status owned-healthy path exits healthy' "$status" '0'
  assert_contains 'status owned-healthy path keeps the managed local host probe unchanged' "$([ -f "$curl_log" ] && cat "$curl_log")" '--connect-timeout 1 --max-time 2 http://127.0.0.1:18080/v1/models'
  assert_contains 'status owned-healthy path reports the owned healthy instance' "$output" 'PASS: llama-server is healthy and owned by this user'
  assert_not_contains 'status owned-healthy path does not report the configured external instance' "$output" 'PASS: llama-server is running (external instance - configured)'
  assert_not_contains 'status owned-healthy path does not report unmanaged-instance failure' "$output" 'FAIL: llama-server is running but not managed by this user'
  assert_contains 'status owned-healthy path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_reports_system_managed_healthy_instance_when_system_mode_artifacts_exist() {
  local output
  local status=0

  prepare_status_test_home_for_system_mode
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/system-owned-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/system-owned-system.err.log"
  export CLAWBOX_LLAMA_PLIST_DEST="$TEMP_DIR/Library/LaunchDaemons/com.clawbox.llama.plist"
  export CLAWBOX_LLAMA_ENV_DEST="$TEMP_DIR/usr/local/etc/clawbox.env"

  mkdir -p "$(dirname "$CLAWBOX_LLAMA_PLIST_DEST")" "$(dirname "$CLAWBOX_LLAMA_ENV_DEST")"
  : > "$CLAWBOX_LLAMA_PLIST_DEST"
  : > "$CLAWBOX_LLAMA_ENV_DEST"
  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status system-managed healthy path exits healthy' "$status" '0'
  assert_contains 'status system-managed healthy path reports the owned healthy instance' "$output" 'PASS: llama-server is healthy and owned by this user'
  assert_contains 'status system-managed healthy path reports the launch daemon section as loaded' "$output" 'PASS: LaunchDaemon is loaded'
  assert_contains 'status system-managed healthy path reports the plist as present' "$output" 'PASS: plist exists'
  assert_contains 'status system-managed healthy path reports the runtime env as present' "$output" 'PASS: runtime env exists'
  assert_contains 'status system-managed healthy path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_reports_system_launchdaemon_loaded_via_domain_aware_probe() {
  local output
  local status=0
  local launchctl_log="$TEMP_DIR/status-system-launchctl.log"

  prepare_status_test_home_for_system_mode
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_LAUNCHCTL_LOG="$launchctl_log"
  export CLAWBOX_TEST_STATUS_LAUNCHCTL_LIST_OUTPUT='no matching service'
  export CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_TARGET='system/com.clawbox.llama'
  export CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/system-domain-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/system-domain-system.err.log"
  export CLAWBOX_LLAMA_PLIST_DEST="$TEMP_DIR/Library/LaunchDaemons/com.clawbox.llama.plist"
  export CLAWBOX_LLAMA_ENV_DEST="$TEMP_DIR/usr/local/etc/clawbox.env"

  mkdir -p "$(dirname "$CLAWBOX_LLAMA_PLIST_DEST")" "$(dirname "$CLAWBOX_LLAMA_ENV_DEST")"
  : > "$CLAWBOX_LLAMA_PLIST_DEST"
  : > "$CLAWBOX_LLAMA_ENV_DEST"
  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$launchctl_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status system-domain launchdaemon path exits healthy' "$status" '0'
  assert_contains 'status system-domain launchdaemon path reports the launch daemon as loaded' "$output" 'PASS: LaunchDaemon is loaded'
  assert_contains 'status system-domain launchdaemon path probes the system launchctl target' "$(cat "$launchctl_log")" 'print system/com.clawbox.llama'
  assert_contains 'status system-domain launchdaemon path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_reports_unmanaged_instance_when_api_is_healthy_but_external_mode_is_false() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/unmanaged-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/unmanaged-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status unmanaged-instance path exits unhealthy' "$status" '1'
  assert_contains 'status unmanaged-instance path reports the unmanaged instance failure' "$output" 'FAIL: llama-server is running but not managed by this user'
  assert_contains 'status unmanaged-instance path explains the external instance was not selected during setup' "$output" 'An external instance is responding, but was not selected during setup.'
  assert_contains 'status unmanaged-instance path explains how to accept the external instance' "$output" "Re-run setup and choose 'Use existing instance' to accept it."
  assert_not_contains 'status unmanaged-instance path does not report the configured external instance' "$output" 'PASS: llama-server is running (external instance - configured)'
  assert_not_contains 'status unmanaged-instance path does not report the owned healthy instance' "$output" 'PASS: llama-server is healthy and owned by this user'
  assert_contains 'status unmanaged-instance path reports a single unhealthy issue in the summary' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_reports_failed_start_bind_error_when_process_exists_without_api_and_bind_log_is_present() {
  local output
  local status=0
  local bind_log="$TEMP_DIR/llama-failed-start.err.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$bind_log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/unused-failed-start-system.err.log"

  cat > "$bind_log" <<'EOF'
startup line
couldn't bind HTTP server socket
EOF

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status failed-start bind-error path exits unhealthy' "$status" '1'
  assert_contains 'status failed-start bind-error path reports the bind failure' "$output" 'FAIL: llama-server failed to start (port bind error)'
  assert_contains 'status failed-start bind-error path explains that no API is active' "$output" 'No active API detected.'
  assert_contains 'status failed-start bind-error path explains the likely cause' "$output" 'Likely cause: stale process or rapid restart conflict.'
  assert_contains 'status failed-start bind-error path explains the remediation' "$output" 'Fix: restart the service or check logs.'
  assert_not_contains 'status failed-start bind-error path does not report the generic process-not-responding failure' "$output" 'FAIL: llama-server process exists but API is not responding'
  assert_not_contains 'status failed-start bind-error path does not report the bind-conflict branch' "$output" 'FAIL: llama-server conflict detected'
  assert_contains 'status failed-start bind-error path emits the recent error log path' "$output" "From $bind_log:"
  assert_contains 'status failed-start bind-error path shows the recent bind error line' "$output" "couldn't bind HTTP server socket"
  assert_contains 'status failed-start bind-error path reports a single unhealthy issue in the summary' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_reports_process_not_responding_when_process_exists_without_api_or_bind_log() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/process-not-responding-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/process-not-responding-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status process-not-responding path exits unhealthy' "$status" '1'
  assert_contains 'status process-not-responding path reports the generic process-not-responding failure' "$output" 'FAIL: llama-server process exists but API is not responding'
  assert_contains 'status process-not-responding path explains the likely failed startup' "$output" 'Likely failed startup. Check logs below.'
  assert_not_contains 'status process-not-responding path does not report the bind-conflict branch' "$output" 'FAIL: llama-server conflict detected'
  assert_not_contains 'status process-not-responding path does not report the failed-start bind-error branch' "$output" 'FAIL: llama-server failed to start (port bind error)'
  assert_contains 'status process-not-responding path reports a single unhealthy issue in the summary' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_reports_llama_not_running_when_no_api_port_or_process_exist() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/not-running-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/not-running-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status llama-not-running path exits unhealthy' "$status" '1'
  assert_contains 'status llama-not-running path reports the final not-running branch' "$output" 'FAIL: llama-server is not running'
  assert_contains 'status llama-not-running path reports a single unhealthy issue in the summary' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_reports_missing_managed_service_artifacts() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_LAUNCHCTL_LIST_OUTPUT='no matching service'
  export CLAWBOX_TEST_STATUS_LAUNCHCTL_PRINT_EXIT_CODE=1
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_PLIST_DEST="$TEMP_DIR/missing-managed-system/com.clawbox.llama.plist"
  export CLAWBOX_LLAMA_ENV_DEST="$TEMP_DIR/missing-managed-system/clawbox.env"
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/missing-managed-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/missing-managed-system.err.log"

  rm -f "$HOME/Library/LaunchAgents/com.clawbox.llama.plist" "$HOME/Library/Application Support/ClawBox/clawbox.env"
  rm -f "$CLAWBOX_LLAMA_PLIST_DEST" "$CLAWBOX_LLAMA_ENV_DEST"
  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status missing managed artifacts path exits unhealthy' "$status" '3'
  assert_contains 'status missing managed artifacts path reports launchd service missing' "$output" 'FAIL: LaunchAgent not loaded'
  assert_contains 'status missing managed artifacts path reports plist missing' "$output" 'FAIL: plist missing'
  assert_contains 'status missing managed artifacts path reports runtime env missing' "$output" 'FAIL: runtime env missing'
  assert_contains 'status missing managed artifacts path reports three unhealthy issues in the summary' "$output" 'RESULT: UNHEALTHY (3 issues)'
}

test_status_reports_vm_ssh_connectivity_failure() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/ssh-failure-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/ssh-failure-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status vm ssh failure path exits unhealthy' "$status" '1'
  assert_contains 'status vm ssh failure path reports SSH connectivity failure' "$output" 'FAIL: SSH connectivity failed'
  assert_contains 'status vm ssh failure path reports a single unhealthy issue in the summary' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_reports_vm_openclaw_runtime_failures() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/openclaw-runtime-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/openclaw-runtime-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status vm openclaw runtime failure path exits unhealthy' "$status" '2'
  assert_contains 'status vm openclaw runtime failure path reports missing process' "$output" 'FAIL: OpenClaw process NOT running'
  assert_contains 'status vm openclaw runtime failure path reports invalid config' "$output" 'FAIL: OpenClaw config invalid or unreadable'
  assert_contains 'status vm openclaw runtime failure path reports two unhealthy issues in the summary' "$output" 'RESULT: UNHEALTHY (2 issues)'
}

test_status_validates_vm_openclaw_config_with_configured_provider_name() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-provider-name-ssh.log"
  local provider_name='custom-provider'
  local vm_config_dir="$TEMP_DIR/vm-home/.openclaw"
  local vm_config_path="$vm_config_dir/openclaw.json"

  prepare_status_test_home
  setup_status_test_mocks

  mkdir -p "$vm_config_dir"
  cat > "$vm_config_path" <<EOF
{
  "models": {
    "providers": {
      "$provider_name": {
        "baseUrl": "http://127.0.0.1:18080/v1"
      }
    }
  }
}
EOF

  cat > "$ENV_FILE" <<EOF
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="http://127.0.0.1:18080/v1"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_PROVIDER_NAME="$provider_name"
OPENCLAW_DEFAULT_MODEL="model"
LLAMA_EXTERNAL="false"
EOF

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_REAL_FILE="$vm_config_path"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/provider-name-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/provider-name-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status custom-provider config path exits healthy' "$status" '0'
  assert_contains 'status custom-provider config path validates the configured provider key' "$(cat "$ssh_log")" ".models.providers[\$provider].baseUrl"
  assert_not_contains 'status custom-provider config path does not hardcode the clawbox provider key' "$(cat "$ssh_log")" '.models.providers.clawbox.baseUrl'
  assert_contains 'status custom-provider config path reports the config as valid' "$output" 'PASS: OpenClaw config is valid'
  assert_contains 'status custom-provider config path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_reports_live_openclaw_gateway_process_as_healthy() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-openclaw-gateway-ssh.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/openclaw-gateway-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/openclaw-gateway-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status live openclaw gateway path stays healthy when all probes succeed' "$status" '0'
  assert_contains 'status live openclaw gateway path uses the gateway-specific runtime command' "$(cat "$ssh_log")" 'gateway([[:space:]]|$)'
  assert_contains 'status live openclaw gateway path reports the process as running' "$output" 'PASS: OpenClaw process is running'
  assert_contains 'status live openclaw gateway path preserves the healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_accepts_launchd_managed_openclaw_gateway_when_ps_args_are_truncated() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-openclaw-launchd-gateway-ssh.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_OUTPUT='gui/501/com.clawbox.openclaw = {
  path = /Users/user/Library/LaunchAgents/com.clawbox.openclaw.plist
  state = running
  program = /opt/homebrew/bin/openclaw
    /opt/homebrew/bin/openclaw
    gateway
  stdout path = /Users/user/ClawBox/logs/runtime/openclaw.out.log
  stderr path = /Users/user/ClawBox/logs/runtime/openclaw.err.log
  XPC_SERVICE_NAME => com.clawbox.openclaw
  pid = 612
  job state = running
}'
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/openclaw-launchd-gateway-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/openclaw-launchd-gateway-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status launchd-managed openclaw gateway path stays healthy when ps omits gateway args' "$status" '0'
  assert_contains 'status launchd-managed openclaw gateway path inspects vm launchd service first' "$(cat "$ssh_log")" 'launchctl print "gui/$(id -u)/com.clawbox.openclaw"'
  assert_contains 'status launchd-managed openclaw gateway path reports the gateway as running' "$output" 'PASS: OpenClaw gateway is running'
  assert_contains 'status launchd-managed openclaw gateway path identifies ClawBox ownership' "$output" 'managed by ClawBox LaunchAgent'
  assert_contains 'status launchd-managed openclaw gateway path preserves the healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_accepts_native_openclaw_launchagent_when_clawbox_job_is_exited() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-openclaw-native-launchd-ssh.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_OUTPUT='gui/501/com.clawbox.openclaw = {
  state = not running
  job state = exited
  last exit code = 0
}'
  export CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_OUTPUT='gui/501/ai.openclaw.gateway = {
  state = running
  program = /Users/user/.openclaw/service-env/ai.openclaw.gateway-env-wrapper.sh
  arguments = {
    /opt/homebrew/opt/node/bin/node
    /opt/homebrew/lib/node_modules/openclaw/dist/index.js
    gateway
    --port
    18789
  }
  pid = 13222
  job state = running
}'
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/openclaw-native-launchd-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/openclaw-native-launchd-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status native launchagent path stays healthy when VM inference succeeds' "$status" '0'
  assert_contains 'status native launchagent path checks the native launchd label' "$(cat "$ssh_log")" 'ai.openclaw.gateway'
  assert_contains 'status native launchagent path reports the gateway as running' "$output" 'PASS: OpenClaw gateway is running'
  assert_contains 'status native launchagent path identifies native ownership' "$output" 'managed by native OpenClaw LaunchAgent (ai.openclaw.gateway)'
  assert_not_contains 'status native launchagent path does not report OpenClaw down' "$output" 'FAIL: OpenClaw process NOT running'
  assert_contains 'status native launchagent path preserves the healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_accepts_native_openclaw_gateway_process_without_launchagent() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_LAUNCHD_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_NATIVE_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/openclaw-native-process-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/openclaw-native-process-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status native gateway process path stays healthy when VM inference succeeds' "$status" '0'
  assert_contains 'status native gateway process path reports the gateway as running' "$output" 'PASS: OpenClaw gateway is running'
  assert_contains 'status native gateway process path identifies non-ClawBox ownership' "$output" 'native OpenClaw gateway process detected outside ClawBox management'
  assert_not_contains 'status native gateway process path does not report OpenClaw down' "$output" 'FAIL: OpenClaw process NOT running'
  assert_contains 'status native gateway process path preserves the healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_rejects_stale_launchd_openclaw_service_without_running_job() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-openclaw-stale-launchd-ssh.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_LAUNCHD_OUTPUT='gui/501/com.clawbox.openclaw = {
  state = not running
  program = /opt/homebrew/bin/openclaw
  arguments = {
    /opt/homebrew/bin/openclaw
    gateway
  }
}'
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/openclaw-stale-launchd-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/openclaw-stale-launchd-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status stale launchd openclaw service exits with one runtime issue' "$status" '1'
  assert_contains 'status stale launchd openclaw service still inspects vm launchd service' "$(cat "$ssh_log")" 'launchctl print "gui/$(id -u)/com.clawbox.openclaw"'
  assert_contains 'status stale launchd openclaw service falls back to process gateway check' "$(cat "$ssh_log")" 'ps -axo pid=,comm=,args='
  assert_contains 'status stale launchd openclaw service without running pid fails runtime check' "$output" 'FAIL: OpenClaw process NOT running'
  assert_contains 'status stale launchd openclaw service reports one unhealthy issue in the summary' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_rejects_generic_non_gateway_openclaw_process() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-openclaw-non-gateway-ssh.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=1
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/openclaw-non-gateway-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/openclaw-non-gateway-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status generic non-gateway openclaw path exits with one runtime issue' "$status" '1'
  assert_contains 'status generic non-gateway openclaw path still uses the gateway-specific runtime command' "$(cat "$ssh_log")" 'gateway([[:space:]]|$)'
  assert_contains 'status generic non-gateway openclaw path rejects the process as not running' "$output" 'FAIL: OpenClaw process NOT running'
  assert_contains 'status generic non-gateway openclaw path reports one unhealthy issue in the summary' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_managed_local_host_probe_ignores_custom_llama_base_url_when_external_is_false() {
  local output
  local status=0
  local curl_log="$TEMP_DIR/status-managed-local-custom-base-url-curl.log"
  local configured_base_url='http://host.internal:19090/custom/v1'

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<EOF
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="$configured_base_url"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_DEFAULT_MODEL="model"
LLAMA_EXTERNAL="false"
EOF

  export CLAWBOX_TEST_STATUS_CURL_LOG="$curl_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/managed-local-custom-base-url-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/managed-local-custom-base-url-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$curl_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status managed-local custom-base-url path exits healthy' "$status" '0'
  assert_contains 'status managed-local custom-base-url path keeps the host probe on the derived local endpoint' "$([ -f "$curl_log" ] && cat "$curl_log")" '--connect-timeout 1 --max-time 2 http://127.0.0.1:18080/v1/models'
  assert_not_contains 'status managed-local custom-base-url path does not switch the host probe to the configured vm-facing endpoint' "$([ -f "$curl_log" ] && cat "$curl_log")" "$configured_base_url/models"
  assert_contains 'status managed-local custom-base-url path reports the owned healthy instance' "$output" 'PASS: llama-server is healthy and owned by this user'
}

test_status_displays_primary_model_summary() {
  local output
  local status=0

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<'EOF'
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="http://127.0.0.1:18080/v1"
MODEL_PATH="/Users/vm-user/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
LLAMA_EXTERNAL="false"
EOF
  cat > "$HOME/Library/Application Support/ClawBox/clawbox.env" <<'EOF'
MODEL_PATH="/Users/vm-user/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
EOF

  export CLAWBOX_TEST_STATUS_PROCESS_ARGS_OUTPUT='/opt/homebrew/bin/llama-server -m /Users/vm-user/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf --host 0.0.0.0 --port 18080 --ctx-size 32768'
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/primary-model-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/primary-model-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status primary model summary exits healthy' "$status" '0'
  assert_contains 'status primary model summary shows section' "$output" 'Primary Model'
  assert_contains 'status primary model summary shows configured path' "$output" 'Configured: /Users/vm-user/models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
  assert_contains 'status primary model summary shows running basename' "$output" 'Running: Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
  assert_contains 'status primary model summary shows stable OpenClaw reference' "$output" 'OpenClaw: clawbox/local'
  assert_contains 'status primary model summary shows API' "$output" 'API: http://127.0.0.1:18080/v1'
  assert_contains 'status primary model summary reports runtime match' "$output" 'PASS: primary model matches configured runtime'
  assert_not_contains 'status primary model summary ignores legacy provider model arrays' "$output" 'models.providers.clawbox.models'
}

test_status_detects_primary_model_mismatch() {
  local output
  local status=0

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<'EOF'
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="http://127.0.0.1:18080/v1"
MODEL_PATH="/Users/vm-user/models/current.gguf"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
LLAMA_EXTERNAL="false"
EOF
  cat > "$HOME/Library/Application Support/ClawBox/clawbox.env" <<'EOF'
MODEL_PATH="/Users/vm-user/models/runtime-old.gguf"
EOF

  export CLAWBOX_TEST_STATUS_PROCESS_ARGS_OUTPUT='/opt/homebrew/bin/llama-server -m /Users/vm-user/models/process-old.gguf --host 0.0.0.0 --port 18080 --ctx-size 32768'
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/primary-mismatch-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/primary-mismatch-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status primary mismatch exits with two issues' "$status" '2'
  assert_contains 'status primary mismatch detects runtime env drift' "$output" 'FAIL: primary runtime env model differs from .env'
  assert_contains 'status primary mismatch detects running process drift' "$output" 'FAIL: primary running model differs from .env'
  assert_contains 'status primary mismatch prints running path only on mismatch' "$output" 'Running path: /Users/vm-user/models/process-old.gguf'
  assert_contains 'status primary mismatch reports unhealthy issue count' "$output" 'RESULT: UNHEALTHY (2 issues)'
}

test_status_displays_embeddings_model_summary_when_enabled() {
  local output
  local status=0

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<'EOF'
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="http://127.0.0.1:18080/v1"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
LLAMA_EXTERNAL="false"
EMBEDDINGS_ENABLED="true"
EMBEDDINGS_MODEL_PATH="/Users/vm-user/models/bge-large-en-v1.5-f16.gguf"
EMBEDDINGS_LLAMA_PORT="18081"
EMBEDDINGS_LLAMA_BASE_URL="http://127.0.0.1:18081/v1"
EOF
  cat > "$HOME/Library/Application Support/ClawBox/clawbox.env" <<'EOF'
MODEL_PATH="/Users/vm-user/models/model.gguf"
EOF
  cat > "$HOME/Library/Application Support/ClawBox/clawbox-embeddings.env" <<'EOF'
EMBEDDINGS_MODEL_PATH="/Users/vm-user/models/bge-large-en-v1.5-f16.gguf"
EOF
  : > "$HOME/Library/LaunchAgents/com.clawbox.llama.embeddings.plist"

  export CLAWBOX_TEST_STATUS_PROCESS_ARGS_OUTPUT='/opt/homebrew/bin/llama-server -m /Users/vm-user/models/model.gguf --host 0.0.0.0 --port 18080 --ctx-size 32768'
  export CLAWBOX_TEST_STATUS_PROCESS_ARGS_EMBEDDINGS_OUTPUT='/opt/homebrew/bin/llama-server -m /Users/vm-user/models/bge-large-en-v1.5-f16.gguf --host 0.0.0.0 --port 18081 --ctx-size 8192 --embedding'
  export CLAWBOX_TEST_SSH_OPENCLAW_MEMORY_MODEL='bge-large-en-v1.5-f16.gguf'
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/embeddings-model-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/embeddings-model-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status embeddings model summary exits healthy' "$status" '0'
  assert_contains 'status embeddings model summary shows section' "$output" 'Embeddings Model'
  assert_contains 'status embeddings model summary shows configured path' "$output" 'Configured: /Users/vm-user/models/bge-large-en-v1.5-f16.gguf'
  assert_contains 'status embeddings model summary shows running basename' "$output" 'Running: bge-large-en-v1.5-f16.gguf'
  assert_contains 'status embeddings model summary shows memorySearch model' "$output" 'OpenClaw memorySearch: bge-large-en-v1.5-f16.gguf'
  assert_contains 'status embeddings model summary reports runtime match' "$output" 'PASS: embeddings model matches configured runtime'
  assert_contains 'status embeddings model summary keeps embeddings endpoint distinct' "$output" 'API: http://127.0.0.1:18081/v1'
}

test_status_detects_embeddings_model_mismatch_when_enabled() {
  local output
  local status=0

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<'EOF'
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="http://127.0.0.1:18080/v1"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
LLAMA_EXTERNAL="false"
EMBEDDINGS_ENABLED="true"
EMBEDDINGS_MODEL_PATH="/Users/vm-user/models/embed-current.gguf"
EMBEDDINGS_LLAMA_PORT="18081"
EMBEDDINGS_LLAMA_BASE_URL="http://127.0.0.1:18081/v1"
EOF
  cat > "$HOME/Library/Application Support/ClawBox/clawbox.env" <<'EOF'
MODEL_PATH="/Users/vm-user/models/model.gguf"
EOF
  cat > "$HOME/Library/Application Support/ClawBox/clawbox-embeddings.env" <<'EOF'
EMBEDDINGS_MODEL_PATH="/Users/vm-user/models/embed-runtime-old.gguf"
EOF
  : > "$HOME/Library/LaunchAgents/com.clawbox.llama.embeddings.plist"

  export CLAWBOX_TEST_STATUS_PROCESS_ARGS_OUTPUT='/opt/homebrew/bin/llama-server -m /Users/vm-user/models/model.gguf --host 0.0.0.0 --port 18080 --ctx-size 32768'
  export CLAWBOX_TEST_STATUS_PROCESS_ARGS_EMBEDDINGS_OUTPUT='/opt/homebrew/bin/llama-server -m /Users/vm-user/models/embed-process-old.gguf --host 0.0.0.0 --port 18081 --ctx-size 8192 --embedding'
  export CLAWBOX_TEST_SSH_OPENCLAW_MEMORY_MODEL='embed-memory-old.gguf'
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/embeddings-mismatch-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/embeddings-mismatch-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status embeddings mismatch exits with three issues' "$status" '3'
  assert_contains 'status embeddings mismatch detects runtime env drift' "$output" 'FAIL: embeddings runtime env model differs from .env'
  assert_contains 'status embeddings mismatch detects running process drift' "$output" 'FAIL: embeddings running model differs from .env'
  assert_contains 'status embeddings mismatch detects memorySearch drift' "$output" 'FAIL: OpenClaw memorySearch model differs from embeddings model'
  assert_contains 'status embeddings mismatch reports unhealthy issue count' "$output" 'RESULT: UNHEALTHY (3 issues)'
}

test_status_omits_embeddings_model_summary_when_disabled_or_absent() {
  local absent_output false_output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/embeddings-disabled-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/embeddings-disabled-system.err.log"
  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  absent_output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status absent embeddings exits healthy' "$status" '0'
  assert_not_contains 'status absent embeddings omits model section' "$absent_output" 'Embeddings Model'
  assert_not_contains 'status absent embeddings omits service section' "$absent_output" 'Embeddings LLaMA Status'

  printf 'EMBEDDINGS_ENABLED="false"\n' >> "$ENV_FILE"
  set +e
  false_output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status disabled embeddings exits healthy' "$status" '0'
  assert_not_contains 'status disabled embeddings omits model section' "$false_output" 'Embeddings Model'
  assert_not_contains 'status disabled embeddings omits service section' "$false_output" 'Embeddings LLaMA Status'
}

test_status_uses_configured_llama_base_url_for_vm_host_api_and_inference_probes() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-configured-base-url-ssh.log"
  local configured_base_url='http://host.internal:19090/custom/v1'

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<EOF
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="$configured_base_url"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_DEFAULT_MODEL="model"
LLAMA_EXTERNAL="false"
EOF

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/configured-base-url-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/configured-base-url-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status configured-base-url path stays healthy when probes succeed' "$status" '0'
  assert_contains 'status configured-base-url path uses the configured base url for the vm api probe' "$([ -f "$ssh_log" ] && cat "$ssh_log")" "curl -s --connect-timeout 1 --max-time 2 $configured_base_url/models"
  assert_contains 'status configured-base-url path passes the inference url and bounded timeouts as remote script args' "$([ -f "$ssh_log" ] && cat "$ssh_log")" "sh -s -- http://host.internal:19090/custom/completion 1 10"
  assert_contains 'status configured-base-url path sends the inference probe to direct llama completion' "$([ -f "$ssh_log" ] && cat "$ssh_log")" "http://host.internal:19090/custom/completion"
  assert_not_contains 'status configured-base-url path does not use persistent responses inference' "$([ -f "$ssh_log" ] && cat "$ssh_log")" "$configured_base_url/responses"
  assert_not_contains 'status configured-base-url path does not reconstruct the vm api probe from host ip and port' "$([ -f "$ssh_log" ] && cat "$ssh_log")" 'curl -s --connect-timeout 1 --max-time 2 http://127.0.0.1:18080/v1/models'
  assert_contains 'status configured-base-url path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_applies_overridden_curl_timeouts_to_all_http_probes() {
  local output
  local status=0
  local curl_log="$TEMP_DIR/status-overridden-curl-timeouts.log"
  local ssh_log="$TEMP_DIR/status-overridden-curl-timeouts-ssh.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_CURL_LOG="$curl_log"
  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_STATUS_CURL_CONNECT_TIMEOUT=4
  export CLAWBOX_STATUS_CURL_MAX_TIME=9
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/overridden-curl-timeouts-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/overridden-curl-timeouts-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$curl_log" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  unset CLAWBOX_STATUS_CURL_CONNECT_TIMEOUT CLAWBOX_STATUS_CURL_MAX_TIME

  assert_equals 'status overridden curl timeouts path exits healthy' "$status" '0'
  assert_contains 'status overridden curl timeouts path applies the overridden timeouts to the local host probe' "$([ -f "$curl_log" ] && cat "$curl_log")" '--connect-timeout 4 --max-time 9 http://127.0.0.1:18080/v1/models'
  assert_contains 'status overridden curl timeouts path applies the overridden timeouts to the vm api probe' "$([ -f "$ssh_log" ] && cat "$ssh_log")" 'curl -s --connect-timeout 4 --max-time 9 http://127.0.0.1:18080/v1/models'
  assert_contains 'status overridden curl timeouts path applies the overridden timeouts to the vm inference probe' "$([ -f "$ssh_log" ] && cat "$ssh_log")" 'sh -s -- http://127.0.0.1:18080/completion 4 9'
  assert_contains 'status overridden curl timeouts path uses direct llama completion for inference' "$([ -f "$ssh_log" ] && cat "$ssh_log")" 'http://127.0.0.1:18080/completion'
  assert_contains 'status overridden curl timeouts path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_uses_minimal_direct_llama_completion_for_vm_inference_probe() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-configured-model-ssh.log"

  prepare_status_test_home
  setup_status_test_mocks

  cat > "$ENV_FILE" <<EOF
HOST_IP="127.0.0.1"
VM_HOST="vm-user@192.168.64.2"
LLAMA_PORT="18080"
LLAMA_BASE_URL="http://127.0.0.1:18080/v1"
MODEL_PATH="/Users/vm-user/models/model.gguf"
OPENCLAW_DEFAULT_MODEL="custom-openclaw-model"
LLAMA_EXTERNAL="false"
EOF

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_COMPLETION_HTTP_CODE=200
  export CLAWBOX_TEST_SSH_VM_COMPLETION_BODY='{"content":"pong","stop":true}'
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/configured-model-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/configured-model-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status minimal direct llama completion path stays healthy when probes succeed' "$status" '0'
  assert_contains 'status minimal direct llama completion path uses the direct completion endpoint' "$([ -f "$ssh_log" ] && cat "$ssh_log")" 'http://127.0.0.1:18080/completion'
  assert_contains 'status minimal direct llama completion path uses the safer default inference max time' "$([ -f "$ssh_log" ] && cat "$ssh_log")" 'sh -s -- http://127.0.0.1:18080/completion 1 10'
  assert_contains 'status minimal direct llama completion path sends a tiny prompt' "$([ -f "$ssh_log" ] && cat "$ssh_log")" '"prompt":"ping"'
  assert_contains 'status minimal direct llama completion path requests one token' "$([ -f "$ssh_log" ] && cat "$ssh_log")" '"n_predict":1'
  assert_contains 'status minimal direct llama completion path preserves cache bypass' "$([ -f "$ssh_log" ] && cat "$ssh_log")" '"cache_prompt":false'
  assert_not_contains 'status minimal direct llama completion path avoids model-bound responses sessions' "$([ -f "$ssh_log" ] && cat "$ssh_log")" '/v1/responses'
  assert_not_contains 'status minimal direct llama completion path does not send an OpenClaw model id' "$([ -f "$ssh_log" ] && cat "$ssh_log")" '"model":'
  assert_not_contains 'status minimal direct llama completion path does not report http 000 when curl succeeds' "$output" 'HTTP status: 000'
  assert_contains 'status minimal direct llama completion path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_classifies_vm_inference_context_overflow() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-context-overflow-ssh.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_COMPLETION_HTTP_CODE=500
  export CLAWBOX_TEST_SSH_VM_COMPLETION_BODY='{"error":"context overflow"}'
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/context-overflow-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/context-overflow-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status context-overflow inference path exits with one issue' "$status" '1'
  assert_contains 'status context-overflow inference path uses direct llama completion' "$([ -f "$ssh_log" ] && cat "$ssh_log")" 'http://127.0.0.1:18080/completion'
  assert_contains 'status context-overflow inference path classifies the failure' "$output" 'FAIL: VM inference request failed: llama context overflow'
  assert_contains 'status context-overflow inference path prints response details' "$output" 'Response body: {"error":"context overflow"}'
  assert_contains 'status context-overflow inference path reports one unhealthy issue' "$output" 'RESULT: UNHEALTHY (1 issues)'
}

test_status_debug_reports_vm_inference_probe_details() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_COMPLETION_OUTPUT='DEBUG: remote curl url: http://127.0.0.1:18080/completion
DEBUG: remote curl status: 0
DEBUG: remote raw HTTP code: 200
DEBUG: remote response body path: /tmp/clawbox-status-body
DEBUG: remote response body bytes: 34
DEBUG: remote curl stderr: (empty)
DEBUG: remote script exit code: 0'
  export CLAWBOX_TEST_SSH_VM_COMPLETION_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/status-debug-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/status-debug-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" --debug 2>&1)"
  status=$?
  set -e

  assert_equals 'status debug inference path stays healthy' "$status" '0'
  assert_contains 'status debug prints resolved vm llama base url' "$output" 'DEBUG: VM_LLAMA_BASE_URL=http://127.0.0.1:18080/v1'
  assert_contains 'status debug prints derived completion url' "$output" 'DEBUG: VM_LLAMA_COMPLETION_URL=http://127.0.0.1:18080/completion'
  assert_contains 'status debug prints ssh target' "$output" 'DEBUG: VM_HOST=vm-user@192.168.64.2'
  assert_contains 'status debug prints raw http code' "$output" 'DEBUG: remote raw HTTP code: 200'
  assert_contains 'status debug prints response body path' "$output" 'DEBUG: remote response body path: /tmp/clawbox-status-body'
  assert_contains 'status debug prints response body length' "$output" 'DEBUG: remote response body bytes: 34'
  assert_contains 'status debug prints curl stderr' "$output" 'DEBUG: remote curl stderr: (empty)'
  assert_contains 'status debug prints remote script exit code' "$output" 'DEBUG: remote script exit code: 0'
  assert_contains 'status debug still reports healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_shows_recent_llama_errors_when_log_exists() {
  local output
  local status=0
  local user_log="$TEMP_DIR/status-user.err.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$user_log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/status-system.err.log"

  cat > "$user_log" <<'EOF'
llama stderr line 1
llama stderr line 2
EOF

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status log display path stays healthy when the runtime is otherwise healthy' "$status" '0'
  assert_contains 'status log display path reports the user error log location' "$output" "From $user_log:"
  assert_contains 'status log display path includes the first recent error line' "$output" 'llama stderr line 1'
  assert_contains 'status log display path includes the second recent error line' "$output" 'llama stderr line 2'
  assert_not_contains 'status log display path does not fall back to the empty-log placeholder when a log exists' "$output" '(no log output)'
}

test_status_shows_no_log_output_when_no_logs_exist() {
  local output
  local status=0

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/missing-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/missing-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status empty-log path stays healthy when no other checks fail' "$status" '0'
  assert_equals 'status empty-log path emits the empty-log placeholder once' "$(printf '%s\n' "$output" | /usr/bin/grep -Fc '(no log output)')" '1'
  assert_contains 'status empty-log path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

test_status_uses_bounded_noninteractive_ssh_for_all_vm_checks() {
  local output
  local status=0
  local ssh_log="$TEMP_DIR/status-ssh.log"

  prepare_status_test_home
  write_status_test_env false
  setup_status_test_mocks

  export CLAWBOX_TEST_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_STATUS_PORT_OPEN_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_STATUS_CURL_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_ECHO_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_PROCESS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_OPENCLAW_CONFIG_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_MODELS_EXIT_CODE=0
  export CLAWBOX_TEST_SSH_VM_RESPONSES_EXIT_CODE=0
  export CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/bounded-ssh-user.err.log"
  export CLAWBOX_LLAMA_ERR_LOG="$TEMP_DIR/bounded-ssh-system.err.log"

  rm -f "$CLAWBOX_LLAMA_USER_ERR_LOG" "$CLAWBOX_LLAMA_ERR_LOG" "$ssh_log"

  set +e
  output="$(/bin/bash "$ROOT_DIR/scripts/status.sh" 2>&1)"
  status=$?
  set -e

  assert_equals 'status bounded ssh path stays healthy when all probes succeed' "$status" '0'
  assert_equals 'status bounded ssh path issues seven SSH calls' "$(/usr/bin/grep -Fc -- '-o BatchMode=yes' "$ssh_log")" '7'
  assert_equals 'status bounded ssh path applies BatchMode to every SSH call' "$(/usr/bin/grep -Fc -- '-o BatchMode=yes' "$ssh_log")" '7'
  assert_equals 'status bounded ssh path applies ConnectTimeout to every SSH call' "$(/usr/bin/grep -Fc -- '-o ConnectTimeout=3' "$ssh_log")" '7'
  assert_contains 'status bounded ssh path reports a healthy summary' "$output" 'RESULT: HEALTHY'
}

printf 'Running release regression tests\n'

run_test test_status_avoids_duplicate_vm_host_api_failure
run_test test_status_reports_bind_failure_without_double_counting
run_test test_status_reports_external_instance_as_configured_when_api_and_port_are_healthy
run_test test_status_external_instance_ignores_local_port_when_configured_api_is_healthy
run_test test_status_external_instance_does_not_require_local_managed_artifacts
run_test test_status_reports_owned_healthy_instance_when_api_port_and_process_are_healthy
run_test test_status_reports_system_managed_healthy_instance_when_system_mode_artifacts_exist
run_test test_status_reports_system_launchdaemon_loaded_via_domain_aware_probe
run_test test_status_reports_unmanaged_instance_when_api_is_healthy_but_external_mode_is_false
run_test test_status_reports_failed_start_bind_error_when_process_exists_without_api_and_bind_log_is_present
run_test test_status_reports_process_not_responding_when_process_exists_without_api_or_bind_log
run_test test_status_reports_llama_not_running_when_no_api_port_or_process_exist
run_test test_status_reports_missing_managed_service_artifacts
run_test test_status_reports_vm_ssh_connectivity_failure
run_test test_status_reports_vm_openclaw_runtime_failures
run_test test_status_validates_vm_openclaw_config_with_configured_provider_name
run_test test_status_reports_live_openclaw_gateway_process_as_healthy
run_test test_status_accepts_launchd_managed_openclaw_gateway_when_ps_args_are_truncated
run_test test_status_accepts_native_openclaw_launchagent_when_clawbox_job_is_exited
run_test test_status_accepts_native_openclaw_gateway_process_without_launchagent
run_test test_status_rejects_stale_launchd_openclaw_service_without_running_job
run_test test_status_rejects_generic_non_gateway_openclaw_process
run_test test_status_managed_local_host_probe_ignores_custom_llama_base_url_when_external_is_false
run_test test_status_displays_primary_model_summary
run_test test_status_detects_primary_model_mismatch
run_test test_status_displays_embeddings_model_summary_when_enabled
run_test test_status_detects_embeddings_model_mismatch_when_enabled
run_test test_status_omits_embeddings_model_summary_when_disabled_or_absent
run_test test_status_uses_configured_llama_base_url_for_vm_host_api_and_inference_probes
run_test test_status_applies_overridden_curl_timeouts_to_all_http_probes
run_test test_status_uses_minimal_direct_llama_completion_for_vm_inference_probe
run_test test_status_classifies_vm_inference_context_overflow
run_test test_status_debug_reports_vm_inference_probe_details
run_test test_status_shows_recent_llama_errors_when_log_exists
run_test test_status_shows_no_log_output_when_no_logs_exist
run_test test_status_uses_bounded_noninteractive_ssh_for_all_vm_checks
run_test test_provisioning_fallback_uses_public_setup_command
run_test test_post_provisioning_offers_onboarding_with_configured_ssh_target
run_test test_post_provisioning_onboarding_runs_only_after_confirmation

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
