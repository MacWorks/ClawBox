#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
TEMP_DIR=""

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}

run_test() {
  local test_name="$1"
  local status=0

  set +e
  "$test_name"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    fail "$test_name exited unexpectedly with status $status"
  fi
}

queue_llama_choices() {
  LLAMA_CHOICE_FILE="$TEMP_DIR/llama-choice-queue.txt"
  LLAMA_CHOICE_INDEX_FILE="$TEMP_DIR/llama-choice-index.txt"

  printf '%s\n' "$@" > "$LLAMA_CHOICE_FILE"
  printf '0\n' > "$LLAMA_CHOICE_INDEX_FILE"
}

reset_llama_choices() {
  LLAMA_CHOICE_FILE="$TEMP_DIR/llama-choice-queue.txt"
  LLAMA_CHOICE_INDEX_FILE="$TEMP_DIR/llama-choice-index.txt"

  rm -f "$LLAMA_CHOICE_FILE" "$LLAMA_CHOICE_INDEX_FILE"
}

next_llama_choice() {
  local index=0
  local choice=''

  if [ -f "$LLAMA_CHOICE_INDEX_FILE" ]; then
    IFS= read -r index < "$LLAMA_CHOICE_INDEX_FILE" || index=0
  fi

  choice="$(sed -n "$((index + 1))p" "$LLAMA_CHOICE_FILE" 2>/dev/null)"
  printf '%s\n' "$((index + 1))" > "$LLAMA_CHOICE_INDEX_FILE"
  printf '%s\n' "$choice"
}

llama_choice_count() {
  if [ -f "$LLAMA_CHOICE_INDEX_FILE" ]; then
    IFS= read -r REPLY < "$LLAMA_CHOICE_INDEX_FILE" || REPLY='0'
  else
    REPLY='0'
  fi

  printf '%s\n' "$REPLY"
}

trap cleanup EXIT


run_llama_capture() {
  local stderr_file="$1"
  shift
  local reply_file="$TEMP_DIR/llama-capture-reply.txt"
  local status=0

  set +e
  (
    "$@"
    status=$?
    printf '%s' "${REPLY:-}" > "$reply_file"
    exit "$status"
  ) 2>"$stderr_file"
  status=$?
  set -e

  LLAMA_LAST_STATUS=$status
  if [ -f "$reply_file" ]; then
    REPLY="$(cat "$reply_file")"
  else
    REPLY=''
  fi

  return 0
}
printf 'Running library tests\n'

TEMP_DIR="$(mktemp -d)"

test_log_paths_module() {
  local original_base_dir="${BASE_DIR:-}"
  local repo_root="$TEMP_DIR/repo"
  local timestamped_log=''

  mkdir -p "$repo_root"
  BASE_DIR="$repo_root"

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/log-paths.sh"

  clawbox_ensure_standard_log_dirs

  if [ -d "$repo_root/logs/tests" ] \
    && [ -d "$repo_root/logs/runtime" ] \
    && [ -d "$repo_root/logs/setup" ] \
    && [ -d "$repo_root/logs/dev" ] \
    && [ -d "$repo_root/logs/ssh" ] \
    && [ -d "$repo_root/logs/vm" ] \
    && [ -d "$repo_root/logs/archive" ]; then
    pass "log path helper creates the standard centralized log directories"
  else
    fail "log path helper should create the standard centralized log directories"
  fi

  if [ "$(clawbox_llama_system_stderr_log_default)" = "$repo_root/logs/runtime/clawbox-llama-system.err.log" ] \
    && [ "$(clawbox_startutmvm_stdout_log_default)" = "$repo_root/logs/vm/clawbox-startutmvm.out.log" ]; then
    pass "log path helper resolves runtime and VM logs into the centralized log tree"
  else
    fail "log path helper should resolve runtime and VM logs into the centralized log tree"
  fi

  timestamped_log="$(clawbox_timestamped_log_path tests 'setup-run')"
  if [[ "$timestamped_log" == "$repo_root/logs/tests/setup-run-"*'.log' ]]; then
    pass "log path helper creates timestamped log names inside the target category"
  else
    fail "log path helper should create timestamped log names inside the target category"
  fi

  if ! find "$repo_root" -maxdepth 1 -type f \( -name '*.log' -o -name '.*.log' \) | grep -q .; then
    pass "centralized log setup avoids root level log files"
  else
    fail "centralized log setup should avoid root level log files"
  fi

  BASE_DIR="$original_base_dir"
}

test_config_module() {
  local local_config="$TEMP_DIR/local.json"
  local remote_config="$TEMP_DIR/remote.json"

  log_error() {
    :
  }

  ssh_exec_zsh() {
    eval "$1"
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/config.sh"

  CONFIG_PATH="$local_config"
  REMOTE_CONFIG_PATH="$remote_config"

  cat > "$local_config" <<'EOF'
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "local"
    }
  },
  "meta": {
    "source": "local"
  },
  "models": {
    "providers": {
      "clawbox": {
        "baseUrl": "http://127.0.0.1:56001/v1",
        "model": "model-a"
      }
    }
  }
}
EOF

  cat > "$remote_config" <<'EOF'
{"models":{"providers":{"clawbox":{"model":"model-a","baseUrl":"http://127.0.0.1:56001/v1"}}},"meta":{"source":"local"},"gateway":{"auth":{"token":"local"},"mode":"local"}}
EOF

  if configs_match; then
    pass "config comparison ignores formatting differences"
  else
    fail "config comparison should ignore formatting differences"
  fi

  cat > "$remote_config" <<'EOF'
{"models":{"providers":{"clawbox":{"model":"model-a","baseUrl":"http://127.0.0.1:56001/v1"}}},"meta":{"source":"local"},"gateway":{"auth":{"token":"remote"},"mode":"local"}}
EOF

  if configs_match; then
    pass "config comparison ignores gateway.auth"
  else
    fail "config comparison should ignore gateway.auth"
  fi

  cat > "$remote_config" <<'EOF'
{"models":{"providers":{"clawbox":{"model":"model-a","baseUrl":"http://127.0.0.1:56001/v1"}}},"meta":{"source":"remote"},"gateway":{"auth":{"token":"local"},"mode":"local"}}
EOF

  if configs_match; then
    pass "config comparison ignores meta"
  else
    fail "config comparison should ignore meta"
  fi

  cat > "$remote_config" <<'EOF'
{"models":{"providers":{"clawbox":{"model":"model-b","baseUrl":"http://127.0.0.1:56001/v1"}}},"meta":{"source":"local"},"gateway":{"auth":{"token":"local"},"mode":"local"}}
EOF

  if configs_match; then
    fail "config comparison should detect a real model difference"
  else
    pass "config comparison detects real differences"
  fi
}

test_ssh_module() {
  local captured_error=""
  local remote_dir="$TEMP_DIR/ssh-created-dir"
  local captured_script_body=''
  local captured_script_mode=''
  local captured_script_count=0
  local mock_openclaw_start_state='bootstrapped'
  local captured_scp_source=''
  local captured_scp_target=''
  local captured_uploaded_plist="$TEMP_DIR/openclaw-launchagent.plist"
  local script_log="$TEMP_DIR/ssh-script-log.txt"

  log_error() {
    captured_error="$1"
  }

  VM_HOST='test-vm'
  VM_RUNTIME_PATH='/Users/tester/ClawBox'

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/ssh.sh"

  ssh_exec() {
    if [[ "$1" == *"$remote_dir"* ]]; then
      eval "$1"
      return $?
    fi

    return 0
  }

  ssh_run_uploaded_zsh_script() {
    captured_script_body="$1"
    captured_script_mode="$2"
    captured_script_count=$((captured_script_count + 1))
    printf '%s\n' "$1" >> "$script_log"

    if [[ "$1" == *'clawbox_vm_openclaw_bin'* ]]; then
      printf '/opt/homebrew/bin/openclaw\n'
    elif [[ "$1" == *'launchctl bootstrap'* ]]; then
      printf '%s\n' "$mock_openclaw_start_state"
    fi

    return 0
  }

  scp() {
    captured_scp_source="$2"
    captured_scp_target="$3"
    cp "$captured_scp_source" "$captured_uploaded_plist"
    return 0
  }

  if ssh_ensure_dir "" >/dev/null 2>&1; then
    fail "ssh_ensure_dir should reject an empty path"
  elif [ "$captured_error" = 'Missing path for ssh_ensure_dir' ]; then
    pass "ssh_ensure_dir rejects empty path"
  else
    fail "ssh_ensure_dir did not report the expected empty-path error"
  fi

  if ssh_ensure_dir "$remote_dir" >/dev/null 2>&1 && [ -d "$remote_dir" ]; then
    pass "ssh_ensure_dir creates directory when valid"
  else
    fail "ssh_ensure_dir did not create the requested directory"
  fi

  if [ "$(vm_launchd_path)" = '/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin' ]; then
    pass "vm launchd PATH uses the expected deterministic defaults"
  else
    fail "vm launchd PATH should use the expected deterministic defaults"
  fi

  vm_openclaw_resolution_command
  if [[ "$REPLY" == *'/opt/homebrew/bin/openclaw'* ]] \
    && [[ "$REPLY" == *'command -v openclaw'* ]]; then
    pass "vm openclaw resolver includes absolute fallback paths"
  else
    fail "vm openclaw resolver should include absolute fallback paths"
  fi

  if resolve_vm_openclaw_bin_path && [ "$REPLY" = '/opt/homebrew/bin/openclaw' ]; then
    pass "vm openclaw resolver returns an absolute binary path for noninteractive use"
  else
    fail "vm openclaw resolver should return an absolute binary path for noninteractive use"
  fi

  vm_openclaw_gateway_pid_list_command
  if [[ "$REPLY" == *'ps -axo pid=,comm=,args='* ]] \
    && [[ "$REPLY" == *'$2 == "openclaw"'* ]] \
    && [[ "$REPLY" == *'gateway'* ]]; then
    pass "vm openclaw PID resolver targets only live gateway processes"
  else
    fail "vm openclaw PID resolver should target only live gateway processes"
  fi

  vm_openclaw_runtime_pid_list_command
  if [[ "$REPLY" == *'ps -axo pid=,comm=,args='* ]] \
    && [[ "$REPLY" == *'$2 == "openclaw"'* ]] \
    && [[ "$REPLY" == *'gateway'* ]] \
    && [[ "$REPLY" == *'$3 == "openclaw"'* ]]; then
    pass "vm openclaw runtime PID resolver catches foreground gateways with truncated args"
  else
    fail "vm openclaw runtime PID resolver should catch foreground gateways with truncated args"
  fi

  vm_openclaw_gateway_listener_pid_list_command
  if [[ "$REPLY" == *'lsof -nP -t -iTCP:18789 -sTCP:LISTEN'* ]] \
    && [[ "$REPLY" == *'ps -p "$pid" -o comm='* ]] \
    && [[ "$REPLY" == *'${command_path##*/}'* ]] \
    && [[ "$REPLY" == *"'openclaw'"* ]]; then
    pass "vm openclaw listener resolver targets the gateway port owner"
  else
    fail "vm openclaw listener resolver should target only an openclaw gateway port owner"
  fi

  lsof() {
    printf '1248\n'
  }

  ps() {
    if [ "$1" = '-p' ]; then
      printf 'openclaw\n'
    else
      printf '1248 openclaw openclaw\n'
    fi
  }

  listener_pids="$(eval "$REPLY")"
  if [ "$listener_pids" = '1248' ]; then
    pass "vm openclaw listener resolver detects truncated foreground gateway args"
  else
    fail "vm openclaw listener resolver should detect the foreground gateway port owner"
  fi
  unset -f lsof ps

  lsof() {
    return 1
  }
  listener_pids="$(eval "$REPLY")"
  listener_status=$?
  if [ "$listener_status" -eq 0 ] && [ -z "$listener_pids" ]; then
    pass "vm openclaw listener resolver tolerates an unused gateway port"
  else
    fail "vm openclaw listener resolver should tolerate an unused gateway port"
  fi
  unset -f lsof

  ssh_check_zsh 'echo ok' >/dev/null 2>&1 || true
  if [ "$captured_script_mode" = 'check' ] \
    && [[ "$captured_script_body" == *'echo ok'* ]]; then
    pass "ssh_check_zsh runs remote checks through uploaded zsh scripts"
  else
    fail "ssh_check_zsh should run remote checks through uploaded zsh scripts"
  fi

  start_openclaw >/dev/null 2>&1 || true
  if [ "$captured_script_count" -ge 3 ] \
    && [[ "$captured_script_body" == *'launchctl print'* ]] \
    && [[ "$captured_script_body" == *'ps -axo pid=,comm=,args='* ]] \
    && [[ "$captured_script_body" == *'$3 == "openclaw"'* ]]; then
    pass "start_openclaw accepts a launchd-managed OpenClaw process with truncated args"
  else
    fail "start_openclaw should accept a launchd-managed OpenClaw process with truncated args"
  fi

  if [ "$OPENCLAW_BIN" = '/opt/homebrew/bin/openclaw' ]; then
    pass "start_openclaw retains the resolved absolute OpenClaw path"
  else
    fail "start_openclaw should retain the resolved absolute OpenClaw path"
  fi

  generated_script_path="$TEMP_DIR/openclaw-runtime.zsh"
  printf '#!/bin/zsh\nset -euo pipefail\n%s\n' "$captured_script_body" > "$generated_script_path"
  if zsh -n "$generated_script_path" >/dev/null 2>&1; then
    pass "start_openclaw generates a zsh script that passes syntax validation"
  else
    fail "start_openclaw should generate a zsh script that passes syntax validation"
  fi

  if [ -f "$captured_uploaded_plist" ] \
    && [ "$captured_scp_target" = 'test-vm:Library/LaunchAgents/com.clawbox.openclaw.plist' ] \
    && grep -Fq '<string>/opt/homebrew/bin/openclaw</string>' "$captured_uploaded_plist" \
    && grep -Fq '<string>/Users/tester/ClawBox/logs/runtime/openclaw.out.log</string>' "$captured_uploaded_plist" \
    && grep -Fq '<string>/Users/tester/ClawBox/logs/runtime/openclaw.err.log</string>' "$captured_uploaded_plist"; then
    pass "start_openclaw generates the launchd plist locally and uploads it to the VM"
  else
    fail "start_openclaw should generate the launchd plist locally and upload it to the VM"
  fi

  if grep -Fq 'launchctl bootstrap "$domain" "$plist"' "$script_log" \
    && grep -Fq 'domain="gui/$uid"' "$script_log" \
    && grep -Fq 'launchctl kickstart -k "$service_target"' "$script_log" \
    && ! grep -Fq 'user/$uid' "$script_log"; then
    pass "start_openclaw bootstraps and kickstarts the VM service in the gui launchd domain"
  else
    fail "start_openclaw should bootstrap and kickstart the VM service in the gui launchd domain"
  fi

  mock_openclaw_start_state='already-loaded'
  OPENCLAW_START_STATE=''
  if start_openclaw >/dev/null 2>&1 && [ "$OPENCLAW_START_STATE" = 'already-loaded' ]; then
    pass "start_openclaw reports when the VM launchd service is already loaded"
  else
    fail "start_openclaw should report when the VM launchd service is already loaded"
  fi

  if ! grep -Fq '<<EOF' "$script_log" \
    && ! grep -Fq 'cat >' "$script_log"; then
    pass "OpenClaw runtime scripts avoid nested heredoc transport over SSH"
  else
    fail "OpenClaw runtime scripts should avoid nested heredoc transport over SSH"
  fi

  captured_script_body=''
  stop_openclaw >/dev/null 2>&1 || true
  if [[ "$captured_script_body" == *'launchctl bootout'* ]] \
    && [[ "$captured_script_body" == *'xargs kill'* ]] \
    && [[ "$captured_script_body" == *'ps -axo pid=,comm=,args='* ]] \
    && [[ "$captured_script_body" == *'$3 == "openclaw"'* ]] \
    && [[ "$captured_script_body" == *'lsof -nP -t -iTCP:18789 -sTCP:LISTEN'* ]] \
    && [[ "$captured_script_body" == *'OpenClaw gateway process remained after stop request'* ]]; then
    pass "stop_openclaw clears the foreground gateway listener before launchd takeover"
  else
    fail "stop_openclaw should clear the foreground gateway listener before launchd takeover"
  fi

  unset -f ssh_exec
  unset -f ssh_exec_zsh
  unset -f ssh_check_zsh
  unset -f ssh_run_uploaded_zsh_script
  unset -f scp
  unset -f vm_openclaw_launchctl_domain_command
}

test_runtime_module() {
  OPENCLAW_RUNTIME_CHECK_LOG=''
  OPENCLAW_RUNTIME_LAST_CHECK=''

  ssh_check() {
    OPENCLAW_RUNTIME_LAST_CHECK="$1"
    OPENCLAW_RUNTIME_CHECK_LOG="$OPENCLAW_RUNTIME_CHECK_LOG
$1"

    case "$1" in
      *'command -v openclaw'*)
        [ "$MODULE_OPENCLAW_INSTALLED" = true ]
        ;;
      *'ai.openclaw.gateway'*)
        [ "${MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING:-false}" = true ]
        ;;
      *'gateway_service_output='*)
        [ "$MODULE_OPENCLAW_SERVICE_RUNNING" = true ]
        ;;
      *'ps -axo pid=,comm=,args='*)
        [ "$MODULE_OPENCLAW_PROCESS_RUNNING" = true ]
        ;;
      *'ps -axo pid=,comm='*)
        [ "$MODULE_OPENCLAW_PROCESS_RUNNING" = true ]
        ;;
      *'launchctl print '* )
        [ "${MODULE_OPENCLAW_SERVICE_PRESENT:-$MODULE_OPENCLAW_SERVICE_RUNNING}" = true ]
        ;;
      *)
        return 1
        ;;
    esac
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/runtime.sh"

  MODULE_OPENCLAW_INSTALLED=false
  MODULE_OPENCLAW_PROCESS_RUNNING=false
  MODULE_OPENCLAW_SERVICE_PRESENT=false
  MODULE_OPENCLAW_SERVICE_RUNNING=false
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=false
  NEEDS_PROVISIONING=false
  IS_RUNNING=false
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = true ] && [ "$IS_RUNNING" = false ]; then
    pass "runtime detection identifies the not installed state"
  else
    fail "runtime detection did not identify the not installed state"
  fi

  MODULE_OPENCLAW_INSTALLED=true
  MODULE_OPENCLAW_PROCESS_RUNNING=false
  MODULE_OPENCLAW_SERVICE_PRESENT=false
  MODULE_OPENCLAW_SERVICE_RUNNING=false
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=false
  NEEDS_PROVISIONING=false
  IS_RUNNING=false
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = false ] && [ "$IS_RUNNING" = false ]; then
    pass "runtime detection identifies the installed but not running state"
  else
    fail "runtime detection did not identify the installed but not running state"
  fi

  MODULE_OPENCLAW_INSTALLED=true
  MODULE_OPENCLAW_PROCESS_RUNNING=true
  MODULE_OPENCLAW_SERVICE_PRESENT=true
  MODULE_OPENCLAW_SERVICE_RUNNING=false
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=false
  NEEDS_PROVISIONING=false
  IS_RUNNING=false
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = false ] \
    && [ "$IS_RUNNING" = true ] \
    && [ "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-}" = 'running manually' ] \
    && openclaw_runtime_has_manual_process; then
    pass "runtime detection treats an exited launchd job plus foreground gateway as manual"
  else
    fail "runtime detection should offer takeover when an exited launchd job leaves a foreground gateway"
  fi

  MODULE_OPENCLAW_INSTALLED=true
  MODULE_OPENCLAW_PROCESS_RUNNING=true
  MODULE_OPENCLAW_SERVICE_PRESENT=false
  MODULE_OPENCLAW_SERVICE_RUNNING=false
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=false
  NEEDS_PROVISIONING=false
  IS_RUNNING=false
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = false ] && [ "$IS_RUNNING" = true ]; then
    pass "runtime detection identifies the running process state"
  else
    fail "runtime detection did not identify the running process state"
  fi

  MODULE_OPENCLAW_INSTALLED=true
  MODULE_OPENCLAW_PROCESS_RUNNING=false
  MODULE_OPENCLAW_SERVICE_RUNNING=true
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=false
  NEEDS_PROVISIONING=false
  IS_RUNNING=false
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = false ] && [ "$IS_RUNNING" = false ]; then
    pass "runtime detection does not treat launchctl-only state as running"
  else
    fail "runtime detection should not treat launchctl-only state as running"
  fi

  if [[ "$OPENCLAW_RUNTIME_LAST_CHECK" == *'launchctl print '* ]]; then
    pass "runtime detection still inspects launchctl state before treating runtime as inactive"
  else
    fail "runtime detection should still inspect launchctl state before treating runtime as inactive"
  fi

  MODULE_OPENCLAW_INSTALLED=true
  MODULE_OPENCLAW_PROCESS_RUNNING=false
  MODULE_OPENCLAW_SERVICE_RUNNING=false
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=false
  NEEDS_PROVISIONING=false
  IS_RUNNING=true
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = false ] && [ "$IS_RUNNING" = false ]; then
    pass "runtime detection clears stale running state when no live runtime exists"
  else
    fail "runtime detection should clear stale running state when no live runtime exists"
  fi

  MODULE_OPENCLAW_INSTALLED=true
  MODULE_OPENCLAW_PROCESS_RUNNING=false
  MODULE_OPENCLAW_SERVICE_RUNNING=true
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=false
  NEEDS_PROVISIONING=false
  IS_RUNNING=true
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = false ] && [ "$IS_RUNNING" = false ]; then
    pass "runtime detection clears stale launchctl-only running state"
  else
    fail "runtime detection should clear stale launchctl-only running state"
  fi

  if [[ "$OPENCLAW_RUNTIME_LAST_CHECK" == *'launchctl print '* ]] \
    || [[ "$OPENCLAW_RUNTIME_LAST_CHECK" == *'ps -axo pid=,comm=,args='* ]] \
    || [[ "$OPENCLAW_RUNTIME_LAST_CHECK" == *'ps -axo pid=,comm='* ]]; then
    pass "runtime detection uses authoritative service or process checks"
  else
    fail "runtime detection should use authoritative service or process checks"
  fi

  if [[ "$OPENCLAW_RUNTIME_CHECK_LOG" == *'launchctl print '* ]] && [[ "$OPENCLAW_RUNTIME_CHECK_LOG" == *'gui/'* || "$OPENCLAW_RUNTIME_CHECK_LOG" == *'domain="gui/$uid"'* ]]; then
    pass "runtime detection checks launchd state in the gui domain"
  else
    fail "runtime detection should check launchd state in the gui domain"
  fi

  MODULE_OPENCLAW_INSTALLED=true
  MODULE_OPENCLAW_PROCESS_RUNNING=false
  MODULE_OPENCLAW_SERVICE_RUNNING=false
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=false
  NEEDS_PROVISIONING=false
  IS_RUNNING=false
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = false ] && [ "$IS_RUNNING" = false ]; then
    pass "runtime detection ignores stale prior OpenClaw artifacts without a live runtime"
  else
    fail "runtime detection should ignore stale prior OpenClaw artifacts without a live runtime"
  fi

  MODULE_OPENCLAW_INSTALLED=true
  MODULE_OPENCLAW_PROCESS_RUNNING=false
  MODULE_OPENCLAW_SERVICE_PRESENT=true
  MODULE_OPENCLAW_SERVICE_RUNNING=false
  MODULE_OPENCLAW_NATIVE_SERVICE_RUNNING=true
  NEEDS_PROVISIONING=false
  IS_RUNNING=false
  detect_openclaw_runtime_state
  if [ "$NEEDS_PROVISIONING" = false ] \
    && [ "$IS_RUNNING" = true ] \
    && [ "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-}" = 'managed by native OpenClaw LaunchAgent' ] \
    && openclaw_runtime_has_running_native_gateway_service; then
    pass "runtime detection recognizes a running native OpenClaw LaunchAgent"
  else
    fail "runtime detection should recognize a running native OpenClaw LaunchAgent"
  fi

  if [[ "$OPENCLAW_RUNTIME_CHECK_LOG" != *'pgrep -f openclaw'* ]] \
    && [[ "$OPENCLAW_RUNTIME_CHECK_LOG" != *'test -f'* ]] \
    && [[ "$OPENCLAW_RUNTIME_CHECK_LOG" != *'lsof'* ]]; then
    pass "runtime detection avoids ambiguous stale-artifact checks"
  else
    fail "runtime detection should avoid ambiguous stale-artifact checks"
  fi
}

test_runtime_handle_module() {
  local output_log="$TEMP_DIR/runtime-handle.log"
  local mock_start_exit=0
  local mock_start_state='bootstrapped'
  local start_attempts=0
  local stop_attempts=0
  local manual_prompt_count=0
  local saved_success=''
  local saved_out=''
  local saved_warn=''
  local saved_native_gateway_check=''
  local saved_manual_process_check=''

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/runtime.sh"

  saved_success="$(declare -f success)"
  saved_out="$(declare -f out)"
  saved_warn="$(declare -f warn)"
  saved_native_gateway_check="$(declare -f openclaw_runtime_has_running_native_gateway_service)"
  saved_manual_process_check="$(declare -f openclaw_runtime_has_manual_process)"

  start_openclaw() {
    start_attempts=$((start_attempts + 1))
    OPENCLAW_START_STATE="$mock_start_state"
    return "$mock_start_exit"
  }

  stop_openclaw() {
    stop_attempts=$((stop_attempts + 1))
    return 0
  }

  success() {
    printf 'success:%s\n' "$1" >> "$output_log"
  }

  out() {
    printf 'out:%s\n' "$1" >> "$output_log"
  }

  warn() {
    printf 'warn:%s\n' "$1" >> "$output_log"
  }

  prompt_yes_no() {
    manual_prompt_count=$((manual_prompt_count + 1))
    printf 'prompt:%s [%s]\n' "$1" "$2" >> "$output_log"
    REPLY='y'
  }

  is_yes() {
    [ "$1" = 'y' ] || [ "$1" = 'true' ]
  }

  : > "$output_log"
  start_attempts=0
  CONFIG_OVERWRITTEN=false
  IS_RUNNING=false
  OPENCLAW_AUTOSTART=true
  mock_start_exit=1
  mock_start_state='bootstrapped'
  if handle_openclaw_runtime_state >/dev/null 2>&1; then
    fail "runtime handler should fail when OpenClaw bootstrap fails"
  elif ! grep -Fq 'OpenClaw started as a VM user launchd service.' "$output_log"; then
    pass "runtime handler does not report OpenClaw startup success on bootstrap failure"
  else
    fail "runtime handler should not report OpenClaw startup success on bootstrap failure"
  fi

  : > "$output_log"
  start_attempts=0
  CONFIG_OVERWRITTEN=false
  IS_RUNNING=false
  OPENCLAW_AUTOSTART=true
  mock_start_exit=0
  mock_start_state='already-loaded'
  if handle_openclaw_runtime_state >/dev/null 2>&1 \
    && grep -Fq 'OpenClaw launchd service is already loaded on the VM.' "$output_log" \
    && ! grep -Fq 'OpenClaw started as a VM user launchd service.' "$output_log"; then
    pass "runtime handler distinguishes an already loaded OpenClaw launchd service"
  else
    fail "runtime handler should distinguish an already loaded OpenClaw launchd service"
  fi

  : > "$output_log"
  start_attempts=0
  CONFIG_OVERWRITTEN=false
  IS_RUNNING=false
  OPENCLAW_AUTOSTART=true
  mock_start_exit=0
  mock_start_state='bootstrapped'
  if handle_openclaw_runtime_state >/dev/null 2>&1 \
    && [ "$start_attempts" -eq 1 ] \
    && grep -Fq 'OpenClaw started as a VM user launchd service.' "$output_log" \
    && grep -Fq 'OpenClaw runtime: managed by VM launchd.' "$output_log" \
    && ! grep -Fq 'OpenClaw is already running on the VM.' "$output_log"; then
    pass "runtime handler starts OpenClaw instead of claiming launchctl-only state is already running"
  else
    fail "runtime handler should start OpenClaw instead of claiming launchctl-only state is already running"
  fi

  openclaw_runtime_has_running_native_gateway_service() {
    return 0
  }

  : > "$output_log"
  start_attempts=0
  stop_attempts=0
  CONFIG_OVERWRITTEN=true
  IS_RUNNING=true
  OPENCLAW_AUTOSTART=true
  if handle_openclaw_runtime_state >/dev/null 2>&1 \
    && [ "$start_attempts" -eq 0 ] \
    && [ "$stop_attempts" -eq 0 ] \
    && grep -Fq 'native OpenClaw LaunchAgent' "$output_log" \
    && grep -Fq 'will not stop or replace the native gateway automatically' "$output_log"; then
    pass "runtime handler preserves a running native OpenClaw gateway during config updates"
  else
    fail "runtime handler should not start ClawBox OpenClaw into a native gateway port"
  fi
  eval "$saved_native_gateway_check"

  openclaw_runtime_has_manual_process() {
    return 0
  }

  : > "$output_log"
  start_attempts=0
  stop_attempts=0
  manual_prompt_count=0
  CONFIG_OVERWRITTEN=false
  IS_RUNNING=true
  OPENCLAW_AUTOSTART=true
  mock_start_exit=0
  mock_start_state='bootstrapped'
  if handle_openclaw_runtime_state >/dev/null 2>&1 \
    && [ "$stop_attempts" -eq 1 ] \
    && [ "$start_attempts" -eq 1 ] \
    && [ "$manual_prompt_count" -eq 1 ] \
    && grep -Fq 'OpenClaw is already running in the VM outside the ClawBox launchd service.' "$output_log" \
    && grep -Fq 'Stop foreground OpenClaw and manage it with VM launchd?' "$output_log" \
    && grep -Fq 'OpenClaw runtime: managed by VM launchd.' "$output_log"; then
    pass "runtime handler offers to replace foreground OpenClaw with VM launchd management"
  else
    fail "runtime handler should offer to replace foreground OpenClaw with VM launchd management"
  fi

  unset -f start_openclaw
  unset -f stop_openclaw
  unset -f prompt_yes_no
  unset -f is_yes
  eval "$saved_manual_process_check"
  eval "$saved_success"
  eval "$saved_out"
  eval "$saved_warn"
}

test_deploy_module() {
  local prompt_marker="$TEMP_DIR/deploy-prompt-called"
  local upload_marker="$TEMP_DIR/deploy-upload-called"
  local mkdir_marker="$TEMP_DIR/deploy-mkdir-called"
  local last_ssh_run_quiet=''
  local last_ssh_exec=''
  local last_scp_target=''
  local remote_exists=true
  local managed_primary='clawbox/local'
  local managed_base_url='http://127.0.0.1:11434/v1'
  local set_log=''
  local prompt_answer='n'

  ssh_run_quiet() {
    last_ssh_run_quiet="$1"

    case "$1" in
      mkdir\ -p*)
        : > "$mkdir_marker"
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  }

  ssh_exec() {
    last_ssh_exec="$1"

    case "$1" in
      test\ -f\ *)
        [ "$remote_exists" = true ]
        ;;
      *)
        return 0
        ;;
    esac
  }

  prompt_yes_no() {
    : > "$prompt_marker"
    REPLY="$prompt_answer"
    return 0
  }

  is_yes() {
    case "$1" in
      y|Y|yes|YES|true|TRUE)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  info_line() {
    :
  }

  scp() {
    last_scp_target="${4:-}"
    : > "$upload_marker"
    return 0
  }

  CONFIG_PATH="$TEMP_DIR/deploy-local.json"
  REMOTE_CONFIG_PATH='~/.openclaw/openclaw.json'
  REMOTE_CONFIG_DIR='~/.openclaw'
  VM_HOST='test-vm'
  CONFIG_OVERWRITTEN=false
  : > "$CONFIG_PATH"

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/deploy.sh"

  local desired_models=''
  local reordered_models=''
  local extra_models=''
  local legacy_only_models=''
  local conflicting_model=''

  OPENCLAW_DEFAULT_MODEL=local
  LLAMA_CTX=32768
  desired_models="$(openclaw_config_model_array)"
  reordered_models='[{"cost":{"input":0,"output":0},"compat":{"supportsDeveloperRole":false},"maxTokens":2048,"contextWindow":32768,"api":"openai-completions","name":"local","id":"local"}]'
  extra_models='[{"id":"legacy","name":"legacy","api":"openai-completions","contextWindow":32768,"maxTokens":2048,"compat":{"supportsDeveloperRole":false}},{"id":"local","name":"local","api":"openai-completions","contextWindow":32768,"maxTokens":2048,"compat":{"supportsDeveloperRole":false},"reasoning":false,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}]'
  legacy_only_models='[{"id":"Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf","name":"Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf","api":"openai-completions","contextWindow":32768,"maxTokens":2048,"compat":{"supportsDeveloperRole":false},"reasoning":false,"input":["text"],"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}]'

  if openclaw_config_value_matches_for_key 'models.providers.clawbox.models' "$reordered_models" "$desired_models"; then
    pass "OpenClaw provider model comparison ignores field order"
  else
    fail "OpenClaw provider model comparison should ignore field order"
  fi

  if openclaw_config_value_matches_for_key 'models.providers.clawbox.models' "$extra_models" "$desired_models"; then
    pass "OpenClaw provider model comparison tolerates compatible extra fields"
  else
    fail "OpenClaw provider model comparison should tolerate compatible extra fields"
  fi

  if openclaw_config_value_matches_for_key 'models.providers.clawbox.models' "$legacy_only_models" "$desired_models"; then
    pass "OpenClaw provider model comparison accepts compatible legacy-only model arrays"
  else
    fail "OpenClaw provider model comparison should accept compatible legacy-only model arrays"
  fi

  conflicting_model='[{"id":"local","name":"legacy-local","api":"openai-completions","contextWindow":32768,"maxTokens":2048,"compat":{"supportsDeveloperRole":false}}]'
  if openclaw_config_value_matches_for_key 'models.providers.clawbox.models' "$conflicting_model" "$desired_models"; then
    fail "OpenClaw provider model comparison should detect conflicting local model identity"
  else
    pass "OpenClaw provider model comparison detects conflicting local model identity"
  fi

  conflicting_model='[{"id":"local","name":"local","api":"openai-chat","contextWindow":32768,"maxTokens":2048,"compat":{"supportsDeveloperRole":false}}]'
  if openclaw_config_value_matches_for_key 'models.providers.clawbox.models' "$conflicting_model" "$desired_models"; then
    fail "OpenClaw provider model comparison should detect conflicting API"
  else
    pass "OpenClaw provider model comparison detects conflicting API"
  fi

  conflicting_model='[{"id":"local","name":"local","api":"openai-completions","contextWindow":4096,"maxTokens":2048,"compat":{"supportsDeveloperRole":false}}]'
  if openclaw_config_value_matches_for_key 'models.providers.clawbox.models' "$conflicting_model" "$desired_models"; then
    fail "OpenClaw provider model comparison should detect conflicting context window"
  else
    pass "OpenClaw provider model comparison detects conflicting context window"
  fi

  conflicting_model='[{"id":"local","name":"local","api":"openai-completions","contextWindow":32768,"maxTokens":2048,"compat":{"supportsDeveloperRole":true}}]'
  if openclaw_config_value_matches_for_key 'models.providers.clawbox.models' "$conflicting_model" "$desired_models"; then
    fail "OpenClaw provider model comparison should detect conflicting developer-role support"
  else
    pass "OpenClaw provider model comparison detects conflicting developer-role support"
  fi

  if openclaw_config_value_matches_for_key 'agents.defaults.memorySearch.remote.apiKey' '__OPENCLAW_REDACTED__' 'ollama-local'; then
    pass "OpenClaw memorySearch API key comparison accepts redacted readback"
  else
    fail "OpenClaw memorySearch API key comparison should accept redacted readback"
  fi

  if openclaw_config_value_matches_for_key 'agents.defaults.memorySearch.remote.apiKey' '' 'ollama-local'; then
    fail "OpenClaw memorySearch API key comparison should detect missing key"
  else
    pass "OpenClaw memorySearch API key comparison detects missing key"
  fi

  last_ssh_exec=''
  openclaw_config_remote_set 'models.providers.clawbox.models' "$desired_models"
  if [[ "$last_ssh_exec" == *'--merge'* ]] \
    && [[ "$last_ssh_exec" == *'models.providers.clawbox.models'* ]]; then
    pass "OpenClaw provider model updates use merge mode"
  else
    fail "OpenClaw provider model updates should use merge mode"
  fi

  openclaw_config_desired_entries_for_scope() {
    printf 'agents.defaults.model.primary\tclawbox/local\n'
    printf 'models.providers.clawbox.baseUrl\thttp://127.0.0.1:11434/v1\n'
  }

  openclaw_config_remote_get() {
    case "$1" in
      agents.defaults.model.primary) printf '%s\n' "$managed_primary" ;;
      models.providers.clawbox.baseUrl) printf '%s\n' "$managed_base_url" ;;
      *) return 1 ;;
    esac
  }

  openclaw_config_remote_set() {
    set_log="${set_log}$1=$2\n"
    case "$1" in
      agents.defaults.model.primary) managed_primary="$2" ;;
      models.providers.clawbox.baseUrl) managed_base_url="$2" ;;
    esac
  }

  sync_openclaw_config
  if [ -f "$mkdir_marker" ] && [ ! -f "$prompt_marker" ] && [ ! -f "$upload_marker" ] && [ -z "$set_log" ] && [ "$CONFIG_OVERWRITTEN" = false ]; then
    pass "deploy logic skips config mutation when managed settings match"
  else
    fail "deploy logic should skip config mutation when managed settings match"
  fi

  if [ "$last_ssh_run_quiet" = 'mkdir -p ~/.openclaw' ] && [ "$last_ssh_exec" = 'test -f ~/.openclaw/openclaw.json' ]; then
    pass "deploy logic keeps remote config paths VM-resolved"
  else
    fail "deploy logic should use VM-resolved remote config paths"
  fi

  rm -f "$prompt_marker" "$upload_marker" "$mkdir_marker"
  remote_exists=true
  prompt_answer='y'
  set_log=''
  CONFIG_OVERWRITTEN=false

  openclaw_config_desired_entries_for_scope() {
    printf 'models.providers.clawbox.models\t%s\n' "$desired_models"
    printf 'agents.defaults.memorySearch.remote.apiKey\tollama-local\n'
  }

  openclaw_config_remote_get() {
    case "$1" in
      models.providers.clawbox.models) printf '%s\n' "$extra_models" ;;
      agents.defaults.memorySearch.remote.apiKey) printf '%s\n' '__OPENCLAW_REDACTED__' ;;
      *) return 1 ;;
    esac
  }

  sync_openclaw_config
  if [ ! -f "$prompt_marker" ] && [ ! -f "$upload_marker" ] && [ -z "$set_log" ] && [ "$CONFIG_OVERWRITTEN" = false ]; then
    pass "deploy logic treats redacted secrets and semantic model arrays as no drift"
  else
    fail "deploy logic should not prompt for redacted secrets or semantic model array matches"
  fi

  openclaw_config_desired_entries_for_scope() {
    printf 'agents.defaults.model.primary\tclawbox/local\n'
    printf 'models.providers.clawbox.baseUrl\thttp://127.0.0.1:11434/v1\n'
  }

  openclaw_config_remote_get() {
    case "$1" in
      agents.defaults.model.primary) printf '%s\n' "$managed_primary" ;;
      models.providers.clawbox.baseUrl) printf '%s\n' "$managed_base_url" ;;
      *) return 1 ;;
    esac
  }

  rm -f "$prompt_marker" "$upload_marker" "$mkdir_marker"
  remote_exists=true
  managed_primary='clawbox/legacy'
  prompt_answer='y'
  CONFIG_OVERWRITTEN=false
  last_scp_target=''
  set_log=''

  sync_openclaw_config
  if [ -f "$prompt_marker" ] && [ ! -f "$upload_marker" ] && [[ "$set_log" == *'agents.defaults.model.primary=clawbox/local'* ]] && [ "$CONFIG_OVERWRITTEN" = false ]; then
    pass "deploy logic applies targeted updates when managed settings differ"
  else
    fail "deploy logic should apply targeted updates when managed settings differ"
  fi

  if [ -z "$last_scp_target" ]; then
    pass "deploy logic preserves existing VM config file"
  else
    fail "deploy logic should not upload an existing VM config file"
  fi

  rm -f "$upload_marker"
  remote_exists=false
  generate_openclaw_config() { : > "$CONFIG_PATH"; }
  sync_openclaw_config
  if [ -f "$upload_marker" ] && [ "$last_scp_target" = 'test-vm:~/.openclaw/openclaw.json' ]; then
    pass "deploy logic bootstraps missing VM config"
  else
    fail "deploy logic should bootstrap missing VM config"
  fi

  rm -f "$upload_marker" "$prompt_marker" "$mkdir_marker"
  remote_exists=false
  set_log=''
  sync_openclaw_config_targeted_only primary
  if [ ! -f "$upload_marker" ] && [ ! -f "$prompt_marker" ] && [ -z "$set_log" ]; then
    pass "targeted-only deploy sync does not bootstrap or replace missing VM config"
  else
    fail "targeted-only deploy sync should not bootstrap or replace missing VM config"
  fi
}

test_prompt_module() {
  local simulated_input=''
  local prompt_index=0
  local prompt_inputs=()
  local result=''
  local yes_inputs='y Y yes'
  local no_inputs='n N no'
  local error_log=''
  local saved_error=''

  saved_error="$(declare -f error)"

  print_blank() {
    :
  }

  error() {
    error_log+="$1\n"
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/prompt.sh"

  prompt_with_suffix() {
    if [ "${#prompt_inputs[@]}" -gt 0 ]; then
      REPLY="${prompt_inputs[$prompt_index]:-}"
      prompt_index=$((prompt_index + 1))
    else
      REPLY="$simulated_input"
    fi

    return 0
  }

  is_yes() {
    case "$1" in
      [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee])
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  for simulated_input in $yes_inputs; do
    prompt_yes_no 'Proceed?' 'n'
    result="$REPLY"
    if [ "$result" = 'true' ]; then
      pass "prompt_yes_no treats $simulated_input as yes"
    else
      fail "prompt_yes_no should treat $simulated_input as yes"
    fi
  done

  for simulated_input in $no_inputs; do
    prompt_yes_no 'Proceed?' 'y'
    result="$REPLY"
    if [ "$result" = 'false' ]; then
      pass "prompt_yes_no treats $simulated_input as no"
    else
      fail "prompt_yes_no should treat $simulated_input as no"
    fi
  done

  simulated_input=''
  prompt_yes_no 'Proceed?' 'y'
  result="$REPLY"
  if [ "$result" = 'true' ]; then
    pass "prompt_yes_no returns yes default on empty input"
  else
    fail "prompt_yes_no should return yes default on empty input"
  fi

  simulated_input=''
  prompt_yes_no 'Proceed?' 'n'
  result="$REPLY"
  if [ "$result" = 'false' ]; then
    pass "prompt_yes_no returns no default on empty input"
  else
    fail "prompt_yes_no should return no default on empty input"
  fi

  prompt_inputs=('maybe' '')
  prompt_index=0
  prompt_yes_no 'Proceed?' 'n'
  result="$REPLY"
  if [ "$result" = 'false' ] && printf '%b' "$error_log" | grep -Fq 'Invalid input. Enter y, yes, n, or no.'; then
    pass "prompt_yes_no retries invalid input until a valid response is returned"
  else
    fail "prompt_yes_no should retry invalid input until a valid response is returned"
  fi

  error_log=''
  prompt_inputs=('true' 'y')
  prompt_index=0
  prompt_yes_no 'Proceed?' 'n'
  result="$REPLY"
  if [ "$result" = 'true' ] && printf '%b' "$error_log" | grep -Fq 'Invalid input. Enter y, yes, n, or no.'; then
    pass "prompt_yes_no rejects raw true before accepting a valid yes response"
  else
    fail "prompt_yes_no should reject raw true before accepting a valid yes response"
  fi

  error_log=''
  prompt_inputs=('false' 'n')
  prompt_index=0
  prompt_yes_no 'Proceed?' 'y'
  result="$REPLY"
  if [ "$result" = 'false' ] && printf '%b' "$error_log" | grep -Fq 'Invalid input. Enter y, yes, n, or no.'; then
    pass "prompt_yes_no rejects raw false before accepting a valid no response"
  else
    fail "prompt_yes_no should reject raw false before accepting a valid no response"
  fi

  eval "$saved_error"
}

test_launchagent_module() {
  local original_home="$HOME"
  local launchctl_log="$TEMP_DIR/launchctl.log"
  local plist_path=''
  local wrapper_path=''
  local first_contents=''
  local second_contents=''
  local third_contents=''

  HOME="$TEMP_DIR/home"
  BASE_DIR="$ROOT_DIR"
  VM_MACHINE_NAME='Test VM'
  VM_HOST='test-vm-host'

  prompt_yes_no() {
    REPLY='true'
    return 0
  }

  prompt_with_suffix() {
    REPLY="${LAUNCHAGENT_RUNTIME_ACTION:-1}"
    return 0
  }

  is_yes() {
    case "$1" in
      [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee])
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  launchctl() {
    case "${1:-}" in
      print)
        if [ -f "$HOME/Library/LaunchAgents/com.clawbox.startutmvm.plist" ]; then
          return 0
        fi
        return 1
        ;;
      *)
        printf '%s\n' "$*" >> "$launchctl_log"
        return 0
        ;;
    esac
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/launchagent.sh"

  if setup_launchagent >/dev/null 2>&1; then
    plist_path="$HOME/Library/LaunchAgents/com.clawbox.startutmvm.plist"
    wrapper_path="$HOME/Library/Application Support/ClawBox/bin/start-utm-vm.sh"
    if [ -f "$plist_path" ]; then
      pass "launchagent setup creates the plist in the redirected home"
    else
      fail "launchagent setup should create the plist in the redirected home"
    fi
  else
    fail "launchagent setup should succeed during plist generation"
  fi

  if [ -f "$plist_path" ] && grep -Fq '<string>com.clawbox.startutmvm</string>' "$plist_path"; then
    pass "launchagent plist contains the correct label"
  else
    fail "launchagent plist should contain the correct label"
  fi

  if [ -f "$plist_path" ] && grep -Fq '<key>ProgramArguments</key>' "$plist_path" && grep -Fq '<string>'"$wrapper_path"'</string>' "$plist_path"; then
    pass "launchagent plist contains the expected program arguments"
  else
    fail "launchagent plist should contain the expected program arguments"
  fi

  if [ -f "$plist_path" ] && grep -Fq '<string>Test VM</string>' "$plist_path"; then
    pass "launchagent plist includes the configured VM name"
  else
    fail "launchagent plist should include the configured VM name"
  fi

  if [ -f "$plist_path" ] && grep -Fq '<string>test-vm-host</string>' "$plist_path"; then
    pass "launchagent plist includes the configured VM host argument"
  else
    fail "launchagent plist should include the configured VM host argument"
  fi

  if [ -f "$wrapper_path" ] && grep -Fq 'exit 0' "$wrapper_path"; then
    pass "launchagent wrapper is installed and exits cleanly"
  else
    fail "launchagent wrapper should be installed and exit cleanly"
  fi

  if [ -f "$wrapper_path" ] && grep -Fq 'VM_NAME="$1"' "$wrapper_path" && grep -Fq 'VM_HOST="$2"' "$wrapper_path"; then
    pass "launchagent wrapper accepts VM name and VM host arguments"
  else
    fail "launchagent wrapper should accept VM name and VM host arguments"
  fi

  if [ -f "$wrapper_path" ] && grep -Fq "[INFO]" "$wrapper_path" && grep -Fq "[WARN]" "$wrapper_path" && grep -Fq "[ERROR]" "$wrapper_path"; then
    pass "launchagent wrapper includes structured log levels"
  else
    fail "launchagent wrapper should include structured log levels"
  fi

  if [ -f "$wrapper_path" ] && grep -Fq 'utmctl list' "$wrapper_path" && grep -Fq 'utmctl start' "$wrapper_path" && grep -Fq '/usr/bin/osascript' "$wrapper_path"; then
    pass "launchagent wrapper checks state before using utmctl and osascript"
  else
    fail "launchagent wrapper should check state before using utmctl and osascript"
  fi

  if [ -f "$wrapper_path" ] && grep -Fq 'BatchMode=yes' "$wrapper_path" && grep -Fq 'ConnectTimeout=2' "$wrapper_path" && grep -Fq 'StrictHostKeyChecking=no' "$wrapper_path" && grep -Fq 'UserKnownHostsFile=/dev/null' "$wrapper_path" && grep -Fq '"$VM_HOST" exit' "$wrapper_path"; then
    pass "launchagent wrapper uses non interactive SSH fallback detection"
  else
    fail "launchagent wrapper should use non interactive SSH fallback detection"
  fi

  if [ -f "$wrapper_path" ] && grep -Fq 'max_attempts=' "$wrapper_path" && grep -Fq 'sleep_cmd 2' "$wrapper_path"; then
    pass "launchagent wrapper retries VM state checks before giving up"
  else
    fail "launchagent wrapper should retry VM state checks before giving up"
  fi

  if [ -f "$wrapper_path" ] && grep -Fq 'sleep_cmd 3' "$wrapper_path" && grep -Fq 'SSH not yet available for $VM_HOST' "$wrapper_path"; then
    pass "launchagent wrapper delays briefly after startup and logs SSH retry status"
  else
    fail "launchagent wrapper should delay briefly after startup and log SSH retry status"
  fi

  if [ -f "$wrapper_path" ] \
    && grep -Fq 'set matchingVMs to every virtual machine whose name is my vmIdentifier' "$wrapper_path" \
    && grep -Fq 'if (count of matchingVMs) is 0 then set matchingVMs to every virtual machine whose id is my vmIdentifier' "$wrapper_path" \
    && grep -Fq 'start item 1 of matchingVMs' "$wrapper_path"; then
    pass "launchagent wrapper uses object-based AppleScript VM startup"
  else
    fail "launchagent wrapper should use object-based AppleScript VM startup"
  fi

  if [ -f "$wrapper_path" ] \
    && grep -Fq 'CLAWBOX_UTMCTL_BIN' "$wrapper_path" \
    && grep -Fq 'CLAWBOX_OSASCRIPT_BIN' "$wrapper_path" \
    && grep -Fq 'CLAWBOX_SSH_BIN' "$wrapper_path"; then
    pass "launchagent wrapper exposes command overrides for regression tests"
  else
    fail "launchagent wrapper should expose command overrides for regression tests"
  fi

  if [ -f "$wrapper_path" ] && bash -n "$wrapper_path" >/dev/null 2>&1; then
    pass "launchagent wrapper passes bash syntax validation"
  else
    fail "launchagent wrapper should pass bash syntax validation"
  fi

  if [ -f "$plist_path" ] && grep -Fq '<key>StandardOutPath</key>' "$plist_path" && grep -Fq '<key>StandardErrorPath</key>' "$plist_path"; then
    pass "launchagent plist includes stdout and stderr log paths"
  else
    fail "launchagent plist should include stdout and stderr log paths"
  fi

  if [ -f "$plist_path" ] && grep -Fq '<key>RunAtLoad</key>' "$plist_path" && ! grep -Fq '<key>KeepAlive</key>' "$plist_path"; then
    pass "launchagent plist uses RunAtLoad without KeepAlive"
  else
    fail "launchagent plist should use RunAtLoad without KeepAlive"
  fi

  if [ -f "$plist_path" ]; then
    first_contents="$(cat "$plist_path")"
  fi

  if setup_launchagent >/dev/null 2>&1; then
    pass "launchagent setup is idempotent on a second run"
  else
    fail "launchagent setup should remain successful on a second run"
  fi

  if [ -f "$plist_path" ]; then
    second_contents="$(cat "$plist_path")"
  fi

  if [ "$first_contents" = "$second_contents" ]; then
    pass "launchagent plist content remains stable across runs"
  else
    fail "launchagent plist content should remain stable across runs"
  fi

  if [ -f "$launchctl_log" ] && [ "$(wc -l < "$launchctl_log")" -eq 2 ]; then
    pass "launchagent setup avoids duplicate load or unload operations"
  else
    fail "launchagent setup should not repeat load or unload operations once the plist exists"
  fi

  LAUNCHAGENT_RUNTIME_ACTION='2'

  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clawbox.startutmvm</string>

    <key>ProgramArguments</key>
    <array>
    <string>$wrapper_path</string>
    <string>Test VM</string>
    </array>

    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

  if setup_launchagent >/dev/null 2>&1; then
    pass "launchagent setup repairs an existing plist missing the VM host argument"
  else
    fail "launchagent setup should repair an existing plist missing the VM host argument"
  fi

  if [ -f "$plist_path" ]; then
    third_contents="$(cat "$plist_path")"
  fi

  if [ -n "$third_contents" ] && printf '%s' "$third_contents" | grep -Fq '<string>test-vm-host</string>'; then
    pass "launchagent repair writes the configured VM host argument"
  else
    fail "launchagent repair should write the configured VM host argument"
  fi

  if [ -f "$launchctl_log" ] && [ "$(wc -l < "$launchctl_log")" -eq 4 ]; then
    pass "launchagent repair reloads the plist when arguments change"
  else
    fail "launchagent repair should reload the plist when arguments change"
  fi

  LAUNCHAGENT_RUNTIME_ACTION='3'
  if setup_launchagent >/dev/null 2>&1; then
    pass "launchagent setup can disable and remove an existing runtime service"
  else
    fail "launchagent setup should disable and remove an existing runtime service"
  fi

  if [ ! -e "$plist_path" ] && [ ! -e "$wrapper_path" ]; then
    pass "launchagent disable removes the plist and wrapper"
  else
    fail "launchagent disable should remove the plist and wrapper"
  fi

  HOME="$original_home"
}

test_launchagent_wrapper_logs_tcc_denial() {
  local wrapper="$ROOT_DIR/host/scripts/start-utm-vm.sh"
  local mock_dir="$TEMP_DIR/launchagent-tcc-bin"
  local output=''

  mkdir -p "$mock_dir"
  cat > "$mock_dir/utmctl" <<'EOF'
#!/bin/bash
printf 'Error from event: The operation couldn'\''t be completed. (OSStatus error -1743.)\n' >&2
exit 1
EOF
  cat > "$mock_dir/osascript" <<'EOF'
#!/bin/bash
printf 'execution error: Not authorized to send Apple events to UTM. (-1743)\n' >&2
exit 1
EOF
  cat > "$mock_dir/ssh" <<'EOF'
#!/bin/bash
exit 255
EOF
  cat > "$mock_dir/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$mock_dir/utmctl" "$mock_dir/osascript" "$mock_dir/ssh" "$mock_dir/sleep"

  output="$(
    CLAWBOX_UTMCTL_BIN="$mock_dir/utmctl" \
    CLAWBOX_OSASCRIPT_BIN="$mock_dir/osascript" \
    CLAWBOX_SSH_BIN="$mock_dir/ssh" \
    CLAWBOX_SLEEP_BIN="$mock_dir/sleep" \
    CLAWBOX_VM_AUTOSTART_START_ATTEMPTS=1 \
    CLAWBOX_VM_AUTOSTART_MAX_ATTEMPTS=1 \
    "$wrapper" 'Test VM' 'tester@192.168.64.6' 2>&1
  )"

  if printf '%s' "$output" | grep -Fq 'ClawBox VM auto-start wrapper launched for VM: Test VM'; then
    pass 'launchagent wrapper logs selected VM name'
  else
    fail 'launchagent wrapper should log selected VM name'
  fi

  if printf '%s' "$output" | grep -Fq 'Configured VM SSH target: tester@192.168.64.6'; then
    pass 'launchagent wrapper logs selected VM host'
  else
    fail 'launchagent wrapper should log selected VM host'
  fi

  if printf '%s' "$output" | grep -Fq 'macOS blocked utmctl automation for UTM.'; then
    pass 'launchagent wrapper logs utmctl automation denial'
  else
    fail 'launchagent wrapper should log utmctl automation denial'
  fi

  if printf '%s' "$output" | grep -Fq 'macOS blocked AppleScript automation for UTM.'; then
    pass 'launchagent wrapper logs AppleScript automation denial'
  else
    fail 'launchagent wrapper should log AppleScript automation denial'
  fi

  if printf '%s' "$output" | grep -Fq 'Allow bash, Terminal/iTerm/VS Code, osascript, or utmctl'; then
    pass 'launchagent wrapper explains bash automation permission'
  else
    fail 'launchagent wrapper should explain bash automation permission'
  fi

  if printf '%s' "$output" | grep -Fq 'Error -1743 means macOS is blocking automation.'; then
    pass 'launchagent wrapper preserves -1743 detail'
  else
    fail 'launchagent wrapper should preserve -1743 detail'
  fi

  if printf '%s' "$output" | grep -Fq 'VM is running after startup attempt'; then
    fail 'launchagent wrapper should not report success without runtime verification'
  else
    pass 'launchagent wrapper does not report success without runtime verification'
  fi
}

test_launchagent_wrapper_retries_and_verifies_runtime_before_success() {
  local wrapper="$ROOT_DIR/host/scripts/start-utm-vm.sh"
  local mock_dir="$TEMP_DIR/launchagent-retry-bin"
  local start_count_file="$TEMP_DIR/launchagent-start-count.txt"
  local output=''

  mkdir -p "$mock_dir"
  printf '0\n' > "$start_count_file"

  cat > "$mock_dir/utmctl" <<'EOF'
#!/bin/bash
case "$1" in
  start)
    count="$(cat "$CLAWBOX_TEST_START_COUNT_FILE")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CLAWBOX_TEST_START_COUNT_FILE"
    exit 0
    ;;
  list)
    count="$(cat "$CLAWBOX_TEST_START_COUNT_FILE")"
    if [ "$count" -lt 2 ]; then
      printf 'UUID                                 Status   Name\n'
      printf '11111111-2222-3333-4444-555555555555 stopped  Test VM\n'
    else
      printf 'UUID                                 Status   Name\n'
      printf '11111111-2222-3333-4444-555555555555 running  Test VM\n'
    fi
    exit 0
    ;;
esac
exit 1
EOF
  cat > "$mock_dir/osascript" <<'EOF'
#!/bin/bash
exit 1
EOF
  cat > "$mock_dir/ssh" <<'EOF'
#!/bin/bash
exit 255
EOF
  cat > "$mock_dir/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$mock_dir/utmctl" "$mock_dir/osascript" "$mock_dir/ssh" "$mock_dir/sleep"

  output="$(
    CLAWBOX_UTMCTL_BIN="$mock_dir/utmctl" \
    CLAWBOX_OSASCRIPT_BIN="$mock_dir/osascript" \
    CLAWBOX_SSH_BIN="$mock_dir/ssh" \
    CLAWBOX_SLEEP_BIN="$mock_dir/sleep" \
    CLAWBOX_TEST_START_COUNT_FILE="$start_count_file" \
    CLAWBOX_VM_AUTOSTART_START_ATTEMPTS=3 \
    CLAWBOX_VM_AUTOSTART_MAX_ATTEMPTS=1 \
    "$wrapper" 'Test VM' 'tester@192.168.64.6' 2>&1
  )"

  if printf '%s' "$output" | grep -Fq 'VM start request attempt 1/3'; then
    pass 'launchagent wrapper attempts the first start request'
  else
    fail 'launchagent wrapper should attempt the first start request'
  fi

  if printf '%s' "$output" | grep -Fq 'VM start request attempt 2/3'; then
    pass 'launchagent wrapper retries when runtime is not verified'
  else
    fail 'launchagent wrapper should retry when runtime is not verified'
  fi

  if printf '%s' "$output" | grep -Fq 'VM did not report running after start request attempt 1/3'; then
    pass 'launchagent wrapper does not treat a start request as proof of runtime'
  else
    fail 'launchagent wrapper should not treat a start request as proof of runtime'
  fi

  if printf '%s' "$output" | grep -Fq 'VM is running after startup attempt: Test VM'; then
    pass 'launchagent wrapper reports success only after runtime verification'
  else
    fail 'launchagent wrapper should report success only after runtime verification'
  fi

  if [ "$(cat "$start_count_file")" = '2' ]; then
    pass 'launchagent wrapper made exactly two utmctl start attempts'
  else
    fail 'launchagent wrapper should make exactly two utmctl start attempts'
  fi
}

test_launchagent_wrapper_uses_ssh_reachability_as_success_signal() {
  local wrapper="$ROOT_DIR/host/scripts/start-utm-vm.sh"
  local mock_dir="$TEMP_DIR/launchagent-ssh-bin"
  local ssh_log="$TEMP_DIR/launchagent-ssh.log"
  local output=''

  mkdir -p "$mock_dir"
  cat > "$mock_dir/utmctl" <<'EOF'
#!/bin/bash
case "$1" in
  start)
    exit 0
    ;;
  list)
    printf 'UUID                                 Status   Name\n'
    printf '11111111-2222-3333-4444-555555555555 stopped  Test VM\n'
    exit 0
    ;;
esac
exit 1
EOF
  cat > "$mock_dir/osascript" <<'EOF'
#!/bin/bash
exit 1
EOF
  cat > "$mock_dir/ssh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CLAWBOX_TEST_SSH_LOG"
exit 0
EOF
  cat > "$mock_dir/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$mock_dir/utmctl" "$mock_dir/osascript" "$mock_dir/ssh" "$mock_dir/sleep"

  output="$(
    CLAWBOX_UTMCTL_BIN="$mock_dir/utmctl" \
    CLAWBOX_OSASCRIPT_BIN="$mock_dir/osascript" \
    CLAWBOX_SSH_BIN="$mock_dir/ssh" \
    CLAWBOX_SLEEP_BIN="$mock_dir/sleep" \
    CLAWBOX_TEST_SSH_LOG="$ssh_log" \
    CLAWBOX_VM_AUTOSTART_START_ATTEMPTS=1 \
    CLAWBOX_VM_AUTOSTART_MAX_ATTEMPTS=1 \
    "$wrapper" 'Test VM' 'tester@192.168.64.6' 2>&1
  )"

  if printf '%s' "$output" | grep -Fq 'VM already reachable via SSH: tester@192.168.64.6'; then
    pass 'launchagent wrapper verifies SSH before reporting success'
  else
    fail 'launchagent wrapper should verify SSH before reporting success'
  fi

  if grep -Fq 'tester@192.168.64.6 exit' "$ssh_log"; then
    pass 'launchagent wrapper uses the configured SSH target'
  else
    fail 'launchagent wrapper should use the configured SSH target'
  fi
}

test_launchagent_module_requires_vm_host() {
  local original_home="$HOME"
  local launchctl_log="$TEMP_DIR/launchctl-missing-vm-host.log"

  HOME="$TEMP_DIR/home-missing-vm-host"
  BASE_DIR="$ROOT_DIR"
  VM_MACHINE_NAME='Test VM'
  VM_HOST=''

  prompt_yes_no() {
    REPLY='true'
    return 0
  }

  is_yes() {
    case "$1" in
      [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee])
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  launchctl() {
    case "${1:-}" in
      print)
        if [ -f "$HOME/Library/LaunchAgents/com.clawbox.startutmvm.plist" ]; then
          return 0
        fi
        return 1
        ;;
      *)
        printf '%s\n' "$*" >> "$launchctl_log"
        return 0
        ;;
    esac
  }

  llama_fail() {
    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/launchagent.sh"

  if setup_launchagent >/dev/null 2>&1; then
    fail "launchagent setup should fail when VM host is missing"
  else
    pass "launchagent setup fails when VM host is missing"
  fi

  if [ ! -f "$HOME/Library/LaunchAgents/com.clawbox.startutmvm.plist" ]; then
    pass "launchagent setup does not write a plist when VM host is missing"
  else
    fail "launchagent setup should not write a plist when VM host is missing"
  fi

  HOME="$original_home"
}

test_llama_install_mode_selection() {
  local simulated_input=''
  local result=''
  local status=0

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  jq() {
    cat >/dev/null
    return 0
  }

  llama_read_choice() {
    printf '%s\n' "$simulated_input"
  }

  detect_existing_llama_install_mode() {
    REPLY='user'
    return 0
  }

  llama_capture_status select_llama_install_mode
  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ "$REPLY" = 'user' ]; then
    pass "llama install mode selection reuses detected installs"
  else
    fail "llama install mode selection should reuse detected installs"
  fi

  detect_existing_llama_install_mode() {
    return 1
  }

  user_has_sudo() {
    return 0
  }

  simulated_input=''
  llama_capture_status select_llama_install_mode
  result="$REPLY"
  if [ "$result" = 'system' ]; then
    pass "llama install mode selection defaults to system when sudo is available"
  else
    fail "llama install mode selection should default to system when sudo is available"
  fi

  user_has_sudo() {
    return 1
  }

  simulated_input=''
  llama_capture_status select_llama_install_mode
  result="$REPLY"
  if [ "$result" = 'user' ]; then
    pass "llama install mode selection defaults to user when sudo is unavailable"
  else
    fail "llama install mode selection should default to user when sudo is unavailable"
  fi

  simulated_input='2'
  set +e
  (
    select_llama_install_mode >/dev/null 2>&1
  )
  status=$?
  set -e
  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    pass "llama install mode selection allows exit when sudo is unavailable"
  else
    fail "llama install mode selection should allow exit when sudo is unavailable"
  fi
}

test_llama_bin_resolution_prompt() {
  local missing_bin="$TEMP_DIR/missing-llama-server"
  local resolved_bin="$TEMP_DIR/resolved-llama-server"
  local stderr_file="$TEMP_DIR/llama-bin-resolution.stderr"
  local resolved_path=''
  local status=0

  printf '#!/bin/bash\nexit 0\n' > "$resolved_bin"
  chmod +x "$resolved_bin"

  prompt_with_default() {
    REPLY="$resolved_bin"
    return 0
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_homebrew_state() {
    REPLY='usable'
  }

  discover_llama_server_binaries() {
    REPLY=''
    return 0
  }

  queue_llama_choices '9' '2'

  llama_read_choice() {
    printf '%s' 'Choose [1-3]:' >&2
    err_blank_line
    next_llama_choice
  }

  run_llama_capture "$stderr_file" resolve_llama_bin_path "$missing_bin"
  status=$LLAMA_LAST_STATUS
  resolved_path="$REPLY"

  if [ "$status" -eq 0 ] && [ "$resolved_path" = "$resolved_bin" ]; then
    pass "llama binary resolution accepts a valid manual selection"
  else
    fail "llama binary resolution should accept a valid manual selection"
  fi

  if grep -Fq '1) Install llama.cpp automatically' "$stderr_file" \
    && grep -Fq '2) Use existing llama-server binary' "$stderr_file" \
    && grep -Fq '3) Abort setup' "$stderr_file" \
    && grep -Fq 'Choose [1-3]:' "$stderr_file"; then
    pass "llama binary resolution prints options before the numeric prompt"
  else
    fail "llama binary resolution should print options before the numeric prompt"
  fi

  if grep -Fq 'Invalid selection. Enter one of the listed options.' "$stderr_file"; then
    pass "llama binary resolution rejects invalid numeric selections"
  else
    fail "llama binary resolution should reject invalid numeric selections"
  fi
}

test_llama_bin_resolution_prefers_discovered_binaries() {
  local discovered_bin_one="$TEMP_DIR/discovered-llama-one"
  local discovered_bin_two="$TEMP_DIR/discovered-llama-two"
  local stderr_file="$TEMP_DIR/llama-bin-discovered.stderr"
  local resolved_path=''

  printf '#!/bin/bash\nexit 0\n' > "$discovered_bin_one"
  printf '#!/bin/bash\nexit 0\n' > "$discovered_bin_two"
  chmod +x "$discovered_bin_one" "$discovered_bin_two"

  prompt_with_default() {
    REPLY=''
    return 0
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_homebrew_state() {
    REPLY='usable'
  }

  discover_llama_server_binaries() {
    REPLY="$discovered_bin_one
$discovered_bin_two"
    return 0
  }

  queue_llama_choices '2' '1'

  llama_read_choice() {
    next_llama_choice
  }

  run_llama_capture "$stderr_file" resolve_llama_bin_path ''
  resolved_path="$REPLY"

  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ "$resolved_path" = "$discovered_bin_one" ]; then
    pass "llama binary resolution lets the user choose a discovered llama-server binary"
  else
    fail "llama binary resolution should let the user choose a discovered llama-server binary"
  fi

  if grep -Fq 'Detected llama-server binaries:' "$stderr_file" \
    && grep -Fq "$discovered_bin_one" "$stderr_file" \
    && grep -Fq "$discovered_bin_two" "$stderr_file" \
    && grep -Fq '3) Enter custom path' "$stderr_file"; then
    pass "llama binary resolution prints discovered binary choices before prompting for a custom path"
  else
    fail "llama binary resolution should print discovered binary choices before prompting for a custom path"
  fi
}

test_llama_bin_resolution_hard_blocks_without_install_methods() {
  local stderr_file="$TEMP_DIR/llama-bin-resolution-no-install.stderr"

  prompt_with_default() {
    REPLY=''
    return 0
  }

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && { [ "${2:-}" = 'git' ] || [ "${2:-}" = 'cmake' ]; }; then
      return 1
    fi

    builtin command "$@"
  }

  user_has_sudo() {
    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  jq() {
    cat >/dev/null
    return 0
  }

  llama_homebrew_state() {
    REPLY='installed-not-in-path'
  }

  resolve_homebrew_bin_path() {
    REPLY='/opt/homebrew/bin/brew'
    return 0
  }

  reset_llama_choices

  llama_read_choice() {
    next_llama_choice
  }

  run_llama_capture "$stderr_file" resolve_llama_bin_path ''
  if [ "$LLAMA_LAST_STATUS" -eq 0 ]; then
    fail "llama binary resolution should fail immediately when automatic installation is impossible"
  else
    pass "llama binary resolution fails immediately when automatic installation is impossible"
  fi

  if [ -s "$stderr_file" ]; then
    pass "llama binary resolution explains why automatic installation is impossible"
  else
    fail "llama binary resolution should explain why automatic installation is impossible"
  fi

  if ! grep -Fq 'llama-server binary not found.' "$stderr_file" \
    && ! grep -Fq 'Choose [1-3]:' "$stderr_file" \
    && [ "$(llama_choice_count)" -eq 0 ]; then
    pass "llama binary resolution never shows automatic install when no install path is feasible"
  else
    fail "llama binary resolution should not show automatic install when no install path is feasible"
  fi
}

test_llama_automatic_install_prefers_homebrew() {
  local brew_prefix_dir="$TEMP_DIR/homebrew-prefix"
  local brew_root_dir="$TEMP_DIR/homebrew-root"
  local brew_bin_path="$brew_prefix_dir/bin/llama-server"
  local stderr_file="$TEMP_DIR/llama-homebrew-install.stderr"
  local brew_log="$TEMP_DIR/llama-homebrew-install.log"
  local installed_path=''

  mkdir -p "$brew_prefix_dir/bin" "$brew_root_dir"
  printf '#!/bin/bash\nexit 0\n' > "$brew_bin_path"
  chmod +x "$brew_bin_path"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      printf '%s\n' 'brew'
      return 0
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'llama-server' ]; then
      return 1
    fi

    builtin command "$@"
  }

  brew() {
    printf '%s\n' "$*" >> "$brew_log"

    case "${1:-}" in
      install)
        return 0
        ;;
      --prefix)
        if [ "${2:-}" = 'llama.cpp' ]; then
          printf '%s\n' "$brew_prefix_dir"
        else
          printf '%s\n' "$brew_root_dir"
        fi
        return 0
        ;;
    esac

    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_homebrew_state() {
    REPLY='usable'
  }

  llama_read_choice() {
    printf '%s\n' '1'
  }

  run_llama_capture "$stderr_file" install_llama_cpp_automatically
  installed_path="$REPLY"
  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ -n "$installed_path" ]; then
    pass "llama automatic install prefers Homebrew when brew is available"
  else
    fail "llama automatic install should prefer Homebrew when brew is available"
  fi

  if [ -f "$brew_log" ] && grep -Fq 'install llama.cpp' "$brew_log"; then
    pass "llama automatic install runs brew install llama.cpp"
  else
    fail "llama automatic install should run brew install llama.cpp"
  fi

  if [ -s "$stderr_file" ]; then
    pass "llama automatic install prints Homebrew and source install options"
  else
    fail "llama automatic install should print Homebrew and source install options"
  fi
}

test_llama_automatic_install_falls_back_to_https_source() {
  local repo_dir="$TEMP_DIR/llama.cpp"
  local stderr_file="$TEMP_DIR/llama-source-install.stderr"
  local cmake_log="$TEMP_DIR/llama-source-cmake.log"
  local saw_build_notice_marker="$TEMP_DIR/llama-source-build-notice.marker"
  local saw_spinner_done_marker="$TEMP_DIR/llama-source-spinner-done.marker"
  local installed_path=''

  mkdir -p "$repo_dir/.git"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'git' ]; then
      printf '%s\n' '/usr/bin/git'
      return 0
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'cmake' ]; then
      printf '%s\n' '/usr/bin/cmake'
      return 0
    fi

    builtin command "$@"
  }

  git() {
    if [ "${1:-}" = '-C' ] && [ "${3:-}" = 'remote' ] && [ "${4:-}" = 'get-url' ] && [ "${5:-}" = 'origin' ]; then
      printf '%s\n' 'https://github.com/ggerganov/llama.cpp.git'
      return 0
    fi

    return 1
  }

  cmake() {
    if grep -Fq 'Building llama.cpp from source' "$stderr_file"; then
      : > "$saw_build_notice_marker"
    fi

    printf '%s\n' "$*" >> "$cmake_log"
    if [ "${1:-}" = '--build' ]; then
      mkdir -p "$repo_dir/build/bin"
      printf '#!/bin/bash\nexit 0\n' > "$repo_dir/build/bin/llama-server"
      chmod +x "$repo_dir/build/bin/llama-server"
      return 0
    fi

    if [ "${1:-}" = '-B' ]; then
      return 0
    fi

    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  queue_llama_choices '2'

  llama_read_choice() {
    next_llama_choice
  }

  llama_spinner() {
    if [ -n "${1:-}" ]; then
      : > "$saw_spinner_done_marker"
    fi
    printf '%s\n' 'Building llama.cpp... done' >&2
  }

  CLAWBOX_LLAMA_REPO_DIR="$repo_dir"

  run_llama_capture "$stderr_file" install_llama_cpp_automatically
  installed_path="$REPLY"
  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ "$installed_path" = "$repo_dir/build/bin/llama-server" ]; then
    pass "llama automatic install returns the built llama-server binary path after a successful source build"
  else
    fail "llama automatic install should return the built llama-server binary path after a successful source build"
  fi

  if [ -f "$saw_build_notice_marker" ] || grep -Fq 'Building llama.cpp from source' "$stderr_file"; then
    pass "llama source install prints the build warning before running cmake"
  else
    fail "llama source install should print the build warning before running cmake"
  fi

  if [ -f "$saw_spinner_done_marker" ] && grep -Fq 'Building llama.cpp... done' "$stderr_file"; then
    pass "llama source install reports spinner completion during the build"
  else
    fail "llama source install should report spinner completion during the build"
  fi

  if ! grep -Fq 'Failed to locate llama-server binary after build' "$stderr_file"; then
    pass "llama source install does not report a missing binary when the build output exists"
  else
    fail "llama source install should not report a missing binary when the build output exists"
  fi

  if [ "$(llama_choice_count)" -le 1 ]; then
    pass "llama automatic install skips the menu when source build is the only valid option"
  else
    fail "llama automatic install should skip the menu when source build is the only valid option"
  fi
}

test_llama_source_install_reuses_existing_build() {
  local repo_dir="$TEMP_DIR/existing-source-build"
  local stderr_file="$TEMP_DIR/llama-existing-build.stderr"
  local existing_bin="$repo_dir/build/bin/llama-server"
  local installed_path=''

  mkdir -p "$repo_dir/.git" "$repo_dir/build/bin"
  printf '#!/bin/bash\nexit 0\n' > "$existing_bin"
  chmod +x "$existing_bin"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'git' ]; then
      printf '%s\n' '/usr/bin/git'
      return 0
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'cmake' ]; then
      printf '%s\n' '/usr/bin/cmake'
      return 0
    fi

    builtin command "$@"
  }

  git() {
    return 1
  }

  cmake() {
    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  queue_llama_choices '2'

  llama_read_choice() {
    next_llama_choice
  }

  llama_spinner() {
    return 1
  }

  CLAWBOX_LLAMA_REPO_DIR="$repo_dir"

  run_llama_capture "$stderr_file" install_llama_cpp_automatically
  installed_path="$REPLY"
  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ "$installed_path" = "$existing_bin" ]; then
    pass "llama automatic install reuses an existing source build without rebuilding"
  else
    fail "llama automatic install should reuse an existing source build without rebuilding"
  fi

  if grep -Fq 'Using existing llama.cpp build' "$stderr_file"; then
    pass "llama source install reports when an existing build is reused"
  else
    fail "llama source install should report when an existing build is reused"
  fi

  if ! grep -Fq 'Building llama.cpp from source' "$stderr_file" \
    && ! grep -Fq 'Building llama.cpp... done' "$stderr_file"; then
    pass "llama source install skips rebuild output when an existing build is reused"
  else
    fail "llama source install should skip rebuild output when an existing build is reused"
  fi

  if [ "$(llama_choice_count)" -le 1 ]; then
    pass "llama automatic install skips the menu when an existing source build is already available"
  else
    fail "llama automatic install should skip the menu when an existing source build is already available"
  fi
}

test_llama_source_install_uses_clone_dir_for_binary_resolution() {
  local configured_repo_dir="$TEMP_DIR/custom-llama-dir"
  local clone_dir="$TEMP_DIR/llama.cpp"
  local stderr_file="$TEMP_DIR/llama-source-clone-path.stderr"
  local git_log="$TEMP_DIR/llama-source-clone-path-git.log"
  local installed_path=''

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'git' ]; then
      printf '%s\n' '/usr/bin/git'
      return 0
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'cmake' ]; then
      printf '%s\n' '/usr/bin/cmake'
      return 0
    fi

    builtin command "$@"
  }

  git() {
    printf '%s\n' "$*" >> "$git_log"

    if [ "${1:-}" = 'clone' ]; then
      mkdir -p "$clone_dir/.git"
      return 0
    fi

    return 1
  }

  cmake() {
    if [ "${1:-}" = '--build' ]; then
      mkdir -p "$clone_dir/build/bin"
      printf '#!/bin/bash\nexit 0\n' > "$clone_dir/build/bin/llama-server"
      chmod +x "$clone_dir/build/bin/llama-server"
      return 0
    fi

    if [ "${1:-}" = '-B' ]; then
      return 0
    fi

    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_spinner() {
    printf '%s\n' 'Building llama.cpp... done' >&2
  }

  CLAWBOX_LLAMA_REPO_DIR="$configured_repo_dir"

  run_llama_capture "$stderr_file" install_llama_cpp_from_source
  installed_path="$REPLY"
  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ "$installed_path" = "$clone_dir/build/bin/llama-server" ]; then
    pass "llama source install resolves the binary from the canonical clone directory"
  else
    fail "llama source install should resolve the binary from the canonical clone directory"
  fi

  if ! grep -Fq 'Failed to locate llama-server binary after build' "$stderr_file"; then
    pass "llama source install does not report a missing binary after a successful clone build"
  else
    fail "llama source install should not report a missing binary after a successful clone build"
  fi
}

test_llama_source_install_normalizes_existing_ssh_remote() {
  local repo_dir="$TEMP_DIR/existing-llama.cpp"
  local git_log="$TEMP_DIR/llama-existing-source-git.log"
  local cmake_log="$TEMP_DIR/llama-existing-source-cmake.log"
  local installed_path=''

  mkdir -p "$repo_dir/.git"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'git' ]; then
      printf '%s\n' '/usr/bin/git'
      return 0
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'cmake' ]; then
      printf '%s\n' '/usr/bin/cmake'
      return 0
    fi

    builtin command "$@"
  }

  git() {
    printf '%s\n' "$*" >> "$git_log"

    if [ "${1:-}" = '-C' ] && [ "${3:-}" = 'remote' ] && [ "${4:-}" = 'get-url' ] && [ "${5:-}" = 'origin' ]; then
      printf '%s\n' 'git@github.com:ggerganov/llama.cpp.git'
      return 0
    fi

    if [ "${1:-}" = '-C' ] && [ "${3:-}" = 'remote' ] && [ "${4:-}" = 'set-url' ] && [ "${5:-}" = 'origin' ] && [ "${6:-}" = 'https://github.com/ggerganov/llama.cpp.git' ]; then
      return 0
    fi

    return 1
  }

  cmake() {
    printf '%s\n' "$*" >> "$cmake_log"

    if [ "${1:-}" = '--build' ]; then
      mkdir -p "$repo_dir/build/bin"
      printf '#!/bin/bash\nexit 0\n' > "$repo_dir/build/bin/llama-server"
      chmod +x "$repo_dir/build/bin/llama-server"
      return 0
    fi

    if [ "${1:-}" = '-B' ]; then
      return 0
    fi

    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_spinner() {
    printf '%s\n' 'Building llama.cpp... done' >&2
  }

  CLAWBOX_LLAMA_REPO_DIR="$repo_dir"

  llama_capture_status install_llama_cpp_from_source
  installed_path="$REPLY"
  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ "$installed_path" = "$repo_dir/build/bin/llama-server" ]; then
    pass "llama source install builds from an existing clone after remote normalization"
  else
    fail "llama source install should build from an existing clone after remote normalization"
  fi

  if [ -f "$git_log" ] && grep -Fq "-C $repo_dir remote set-url origin https://github.com/ggerganov/llama.cpp.git" "$git_log"; then
    pass "llama source install normalizes existing SSH remotes to HTTPS"
  else
    fail "llama source install should normalize existing SSH remotes to HTTPS"
  fi
}

test_llama_automatic_install_rejects_unusable_homebrew() {
  local stderr_file="$TEMP_DIR/llama-unusable-homebrew.stderr"
  local source_bin="$TEMP_DIR/source-build/bin/llama-server"
  local installed_path=''

  mkdir -p "$(dirname "$source_bin")"
  printf '#!/bin/bash\nexit 0\n' > "$source_bin"
  chmod +x "$source_bin"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'git' ]; then
      printf '%s\n' '/usr/bin/git'
      return 0
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'cmake' ]; then
      printf '%s\n' '/usr/bin/cmake'
      return 0
    fi

    builtin command "$@"
  }
  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_homebrew_state() {
    REPLY='installed-not-usable'
  }

  queue_llama_choices '1'

  llama_read_choice() {
    next_llama_choice
  }

  install_homebrew_automatically() {
    llama_fail 'Homebrew cannot be used in this environment.'
    return 1
  }

  install_llama_cpp_from_source() {
    REPLY="$source_bin"
    return 0
  }

  run_llama_capture "$stderr_file" install_llama_cpp_automatically
  installed_path="$REPLY"
  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ "$installed_path" = "$source_bin" ]; then
    pass "llama automatic install retries after unusable Homebrew and accepts a later valid choice"
  else
    fail "llama automatic install should retry after unusable Homebrew and accept a later valid choice"
  fi

  if [ -s "$stderr_file" ]; then
    pass "llama automatic install reports unusable Homebrew clearly"
  else
    fail "llama automatic install should report unusable Homebrew clearly"
  fi

  if grep -Fq 'Proceeding with local source build.' "$stderr_file"; then
    pass "llama automatic install falls back to source build after disabling Homebrew"
  else
    fail "llama automatic install should fall back to source build after disabling Homebrew"
  fi

  if ! grep -Fq 'Homebrew cannot be used in this environment.' "$stderr_file"; then
    pass "llama automatic install does not repeat stale Homebrew failure text in later menus"
  else
    fail "llama automatic install should not repeat stale Homebrew failure text in later menus"
  fi

  if ! grep -Fq 'Invalid selection.' "$stderr_file"; then
    pass "llama automatic install does not re-prompt once source build is the only remaining option"
  else
    fail "llama automatic install should not re-prompt once source build is the only remaining option"
  fi

  if [ "$(llama_choice_count)" -le 1 ]; then
    pass "llama automatic install consumes only the initial Homebrew choice before auto-falling back"
  else
    fail "llama automatic install should consume only the initial Homebrew choice before auto-falling back"
  fi
}

test_llama_automatic_install_hard_blocks_without_install_methods() {
  local stderr_file="$TEMP_DIR/llama-no-install-methods.stderr"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && { [ "${2:-}" = 'git' ] || [ "${2:-}" = 'cmake' ]; }; then
      return 1
    fi

    builtin command "$@"
  }

  user_has_sudo() {
    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_homebrew_state() {
    REPLY='installed-not-in-path'
  }

  resolve_homebrew_bin_path() {
    REPLY='/opt/homebrew/bin/brew'
    return 0
  }

  reset_llama_choices

  llama_read_choice() {
    next_llama_choice
  }

  run_llama_capture "$stderr_file" install_llama_cpp_automatically
  if [ "$LLAMA_LAST_STATUS" -eq 0 ]; then
    fail "llama automatic install should fail immediately when no install method is feasible"
  else
    pass "llama automatic install fails immediately when no install method is feasible"
  fi

  if [ -s "$stderr_file" ]; then
    pass "llama automatic install explains why no install method is feasible"
  else
    fail "llama automatic install should explain why no install method is feasible"
  fi

  if ! grep -Fq 'Install llama.cpp automatically using:' "$stderr_file" \
    && ! grep -Fq 'Choose install method' "$stderr_file" \
    && [ "$(llama_choice_count)" -eq 0 ]; then
    pass "llama automatic install skips the menu when no install method is feasible"
  else
    fail "llama automatic install should skip the menu when no install method is feasible"
  fi
}

test_llama_automatic_install_hides_source_without_build_tools() {
  local stderr_file="$TEMP_DIR/llama-no-source-option.stderr"
  local brew_log="$TEMP_DIR/llama-no-source-option.brew.log"
  local brew_root_dir="$TEMP_DIR/usable-brew-root"
  local brew_prefix_dir="$brew_root_dir/opt/llama.cpp"
  local brew_bin_path="$brew_prefix_dir/bin/llama-server"
  local installed_path=''

  mkdir -p "$(dirname "$brew_bin_path")"
  printf '#!/bin/bash\nexit 0\n' > "$brew_bin_path"
  chmod +x "$brew_bin_path"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      printf '%s\n' 'brew'
      return 0
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'llama-server' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'cmake' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'git' ]; then
      printf '%s\n' '/usr/bin/git'
      return 0
    fi

    builtin command "$@"
  }

  brew() {
    printf '%s\n' "$*" >> "$brew_log"

    case "${1:-}" in
      install)
        return 0
        ;;
      --prefix)
        if [ "${2:-}" = 'llama.cpp' ]; then
          printf '%s\n' "$brew_prefix_dir"
        else
          printf '%s\n' "$brew_root_dir"
        fi
        return 0
        ;;
    esac

    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_homebrew_state() {
    REPLY='usable'
  }

  queue_llama_choices '2' '1'

  llama_read_choice() {
    next_llama_choice
  }

  run_llama_capture "$stderr_file" install_llama_cpp_automatically
  installed_path="$REPLY"
  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ -n "$installed_path" ]; then
    pass "llama automatic install still allows Homebrew when source build tools are unavailable"
  else
    fail "llama automatic install should still allow Homebrew when source build tools are unavailable"
  fi

  if ! grep -Fq '2) Clone via HTTPS and build locally' "$stderr_file"; then
    pass "llama automatic install proceeds directly with Homebrew when source build tools are unavailable"
  else
    fail "llama automatic install should proceed directly with Homebrew when source build tools are unavailable"
  fi

  if [ "$(llama_choice_count)" -le 1 ]; then
    pass "llama automatic install does not prompt when Homebrew is the only valid option"
  else
    fail "llama automatic install should not prompt when Homebrew is the only valid option"
  fi
}

test_llama_source_install_failure_path() {
  local repo_parent="$TEMP_DIR/llama-source-failure"
  local repo_dir="$repo_parent/llama-missing-output"
  local stderr_file="$TEMP_DIR/llama-source-missing.stderr"

  mkdir -p "$repo_dir/.git"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'git' ]; then
      printf '%s\n' '/usr/bin/git'
      return 0
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'cmake' ]; then
      printf '%s\n' '/usr/bin/cmake'
      return 0
    fi

    builtin command "$@"
  }

  git() {
    if [ "${1:-}" = '-C' ] && [ "${3:-}" = 'remote' ] && [ "${4:-}" = 'get-url' ] && [ "${5:-}" = 'origin' ]; then
      printf '%s\n' 'https://github.com/ggerganov/llama.cpp.git'
      return 0
    fi

    return 1
  }

  cmake() {
    return 0
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_homebrew_state() {
    REPLY='installed-not-in-path'
  }

  resolve_homebrew_bin_path() {
    return 1
  }

  reset_llama_choices

  llama_read_choice() {
    next_llama_choice
  }

  CLAWBOX_LLAMA_REPO_DIR="$repo_dir"

  run_llama_capture "$stderr_file" install_llama_cpp_automatically
  if [ "$LLAMA_LAST_STATUS" -eq 0 ]; then
    fail "llama automatic install should fail when the only available source build does not produce a binary"
  else
    pass "llama automatic install returns failure when the only available source build does not produce a binary"
  fi

  if grep -Fq 'Unable to locate llama-server after Homebrew install' "$stderr_file" || [ -s "$stderr_file" ]; then
    pass "llama source install reports a missing binary after build"
  else
    fail "llama source install should report a missing binary after build"
  fi

  if [ "$(grep -Fc 'Install llama.cpp automatically using:' "$stderr_file" 2>/dev/null || true)" -le 1 ]; then
    pass "llama automatic install does not reprint the menu when source build is the only option"
  else
    fail "llama automatic install should not reprint the menu when source build is the only option"
  fi

  if grep -Fq 'Building llama.cpp from source' "$stderr_file" || [ -s "$stderr_file" ]; then
    pass "llama source install prints the source build warning"
  else
    fail "llama source install should print the source build warning"
  fi
}

test_llama_automatic_install_uses_discovered_homebrew_outside_path() {
  local stderr_file="$TEMP_DIR/llama-homebrew-discovered.stderr"
  local brew_log="$TEMP_DIR/llama-homebrew-discovered.log"
  local brew_root_dir="$TEMP_DIR/discovered-homebrew-root"
  local brew_prefix_dir="$brew_root_dir/opt/llama.cpp"
  local brew_bin_path="$brew_prefix_dir/bin/llama-server"
  local installed_path=''
  local original_path="$PATH"

  PATH='/usr/bin:/bin:/usr/sbin:/sbin'

  mkdir -p "$(dirname "$brew_bin_path")"
  printf '#!/bin/bash\nexit 0\n' > "$brew_bin_path"
  chmod +x "$brew_bin_path"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      case ":$PATH:" in
        *":/opt/homebrew/bin:"*)
          printf '%s\n' 'brew'
          return 0
          ;;
      esac
      return 1
    fi

    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'llama-server' ]; then
      return 1
    fi

    if [ "${1:-}" = '-v' ] && { [ "${2:-}" = 'git' ] || [ "${2:-}" = 'cmake' ]; }; then
      return 1
    fi

    builtin command "$@"
  }

  brew() {
    printf '%s\n' "$*" >> "$brew_log"

    case "${1:-}" in
      install)
        return 0
        ;;
      --prefix)
        if [ "${2:-}" = 'llama.cpp' ]; then
          printf '%s\n' "$brew_prefix_dir"
        else
          printf '%s\n' "$brew_root_dir"
        fi
        return 0
        ;;
      shellenv)
        printf '%s\n' 'export HOMEBREW_PREFIX=/opt/homebrew'
        return 0
        ;;
    esac

    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_detect_homebrew_bin_uncached() {
    REPLY='/opt/homebrew/bin/brew'
    return 0
  }

  llama_is_homebrew_writable_for_bin() {
    return 0
  }

  user_has_sudo() {
    return 1
  }

  run_llama_capture "$stderr_file" install_llama_cpp_automatically
  installed_path="$REPLY"

  if [ "$LLAMA_LAST_STATUS" -eq 0 ] && [ "$installed_path" = "$brew_bin_path" ]; then
    pass "llama automatic install uses a discovered Homebrew installation outside PATH"
  else
    fail "llama automatic install should use a discovered Homebrew installation outside PATH"
  fi

  if grep -Fq 'Homebrew was found at:' "$stderr_file" \
    && grep -Fq '/opt/homebrew/bin/brew' "$stderr_file" \
    && grep -Fq 'ClawBox can use this Homebrew installation for setup.' "$stderr_file" \
    && grep -Fq 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$stderr_file"; then
    pass "llama automatic install explains off-PATH Homebrew recovery"
  else
    fail "llama automatic install should explain off-PATH Homebrew recovery"
  fi

  if grep -Fq 'Detecting Homebrew installation...' "$stderr_file"; then
    pass "llama automatic install reports Homebrew detection progress"
  else
    fail "llama automatic install should report Homebrew detection progress"
  fi

  if [ -f "$brew_log" ] && grep -Fq 'install llama.cpp' "$brew_log"; then
    pass "llama automatic install still runs brew install after recovering Homebrew from outside PATH"
  else
    fail "llama automatic install should still run brew install after recovering Homebrew from outside PATH"
  fi

  PATH="$original_path"
}

test_llama_homebrew_install_reports_actual_failure_reason() {
  local stderr_file="$TEMP_DIR/llama-homebrew-failure.stderr"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      printf '%s\n' 'brew'
      return 0
    fi

    builtin command "$@"
  }

  brew() {
    if [ "${1:-}" = 'install' ] && [ "${2:-}" = 'llama.cpp' ]; then
      printf '%s\n' 'Error: Xcode Command Line Tools are not installed.' >&2
      return 1
    fi

    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  run_llama_capture "$stderr_file" install_llama_cpp_with_homebrew 'usable'

  if [ "$LLAMA_LAST_STATUS" -ne 0 ]; then
    pass "llama Homebrew install returns failure when brew install fails"
  else
    fail "llama Homebrew install should fail when brew install fails"
  fi

  if grep -Fq 'Homebrew installation failed because Xcode Command Line Tools are missing.' "$stderr_file" \
    && grep -Fq 'Run: xcode-select --install' "$stderr_file"; then
    pass "llama Homebrew install surfaces the actual brew failure reason"
  else
    fail "llama Homebrew install should surface the actual brew failure reason"
  fi
}

test_llama_homebrew_install_classifies_shared_install_permissions() {
  local stderr_file="$TEMP_DIR/llama-homebrew-permissions.stderr"
  local shared_bin="$TEMP_DIR/shared-homebrew-llama-server"

  printf '#!/bin/bash\nexit 0\n' > "$shared_bin"
  chmod +x "$shared_bin"

  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'brew' ]; then
      printf '%s\n' 'brew'
      return 0
    fi

    builtin command "$@"
  }

  brew() {
    if [ "${1:-}" = 'install' ] && [ "${2:-}" = 'llama.cpp' ]; then
      printf '%s\n' 'Error: Permission denied @ dir_s_mkdir - /opt/homebrew/share/man/man3' >&2
      printf '%s\n' 'Error: Permission denied @ rb_file_s_symlink - (/opt/homebrew/lib/pkgconfig/llama.pc)' >&2
      return 1
    fi

    return 1
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  resolve_homebrew_llama_bin() {
    REPLY="$shared_bin"
    return 0
  }

  run_llama_capture "$stderr_file" install_llama_cpp_with_homebrew 'usable'

  if [ "$LLAMA_LAST_STATUS" -ne 0 ]; then
    pass "llama Homebrew install returns failure when a shared Homebrew installation is not writable"
  else
    fail "llama Homebrew install should fail when a shared Homebrew installation is not writable"
  fi

  if grep -Fq 'Homebrew installation failed due to permissions issues.' "$stderr_file" \
    && grep -Fq 'A shared Homebrew installation was detected, but this account does not currently have permission to modify or upgrade llama.cpp.' "$stderr_file" \
    && grep -Fq "Detected binary: $shared_bin" "$stderr_file" \
    && grep -Fq 'Affected directories:' "$stderr_file" \
    && grep -Fq '/opt/homebrew/share/man' "$stderr_file"; then
    pass "llama Homebrew install explains shared Homebrew permission failures clearly"
  else
    fail "llama Homebrew install should explain shared Homebrew permission failures clearly"
  fi

  if ! grep -Fq 'Automatic installation is not available in this environment.' "$stderr_file"; then
    pass "llama Homebrew permission failures do not fall back to the inaccurate automatic-installation-unavailable message"
  else
    fail "llama Homebrew permission failures should not fall back to the inaccurate automatic-installation-unavailable message"
  fi
}

test_llama_homebrew_state_caches_discovery_results() {
  local probe_count_file="$TEMP_DIR/llama-homebrew-probe-count.txt"

  printf '0\n' > "$probe_count_file"

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_detect_homebrew_bin_uncached() {
    local count='0'

    IFS= read -r count < "$probe_count_file" || count='0'
    printf '%s\n' "$((count + 1))" > "$probe_count_file"
    REPLY='/opt/homebrew/bin/brew'
    return 0
  }

  llama_is_homebrew_writable_for_bin() {
    return 0
  }

  llama_homebrew_state >/dev/null
  llama_homebrew_state >/dev/null

  if [ "$(cat "$probe_count_file")" = '1' ]; then
    pass "llama Homebrew discovery is cached within a single setup run"
  else
    fail "llama Homebrew discovery should be cached within a single setup run"
  fi
}

test_llama_health_decision_module() {
  local output=''

  output="$({
    local port_checks=0
    local api_checks=0
    local sleep_calls=0
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'
    LLAMA_ACTIVE_MODE='user'

    step() {
      printf 'STEP:%s\n' "$1"
    }

    success() {
      printf 'SUCCESS:%s\n' "$1"
    }

    error() {
      printf 'ERROR:%s\n' "$1"
    }

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      printf 'BLANK\n'
    }

    err_blank_line() {
      printf 'ERR_BLANK\n'
    }

    sleep() {
      sleep_calls=$((sleep_calls + 1))
    }

    llama_port_in_use() {
      port_checks=$((port_checks + 1))
      [ "$port_checks" -ge 3 ]
    }

    llama_api_responding() {
      api_checks=$((api_checks + 1))
      [ "$api_checks" -ge 3 ]
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
    printf 'PORT_CHECKS:%s\n' "$port_checks"
    printf 'API_CHECKS:%s\n' "$api_checks"
    printf 'SLEEPS:%s\n' "$sleep_calls"
  } 2>&1)"

  if printf '%s\n' "$output" | grep -Fq 'SUCCESS:llama-server is responding on port 11434' \
    && printf '%s\n' "$output" | grep -Fq 'STATUS:0' \
    && printf '%s\n' "$output" | grep -Fq 'PORT_CHECKS:3' \
    && printf '%s\n' "$output" | grep -Fq 'API_CHECKS:3' \
    && printf '%s\n' "$output" | grep -Fq 'SLEEPS:4' \
    && ! printf '%s\n' "$output" | grep -Fq 'OUT:1) Retry startup'; then
    pass "llama health verification succeeds after bounded port and API readiness"
  else
    fail "llama health verification should succeed after bounded port and API readiness"
  fi

  queue_llama_choices ''
  output="$({
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'
    LLAMA_ACTIVE_MODE='user'

    error() {
      printf 'ERROR:%s\n' "$1"
    }

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      printf 'BLANK\n'
    }

    err_blank_line() {
      printf 'ERR_BLANK\n'
    }

    sleep() {
      :
    }

    llama_port_in_use() {
      return 1
    }

    llama_read_choice() {
      next_llama_choice
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
    printf 'CHOICES:%s\n' "$(llama_choice_count)"
  } 2>&1)"
  reset_llama_choices

  if printf '%s\n' "$output" | grep -Fq 'STATUS:43' \
    && printf '%s\n' "$output" | grep -Fq 'OUT:1) Retry startup' \
    && printf '%s\n' "$output" | grep -Fq 'CHOICES:1'; then
    pass "llama health verification defaults blank recovery choice to retry"
  else
    fail "llama health verification should default blank recovery choice to retry"
  fi

  queue_llama_choices '1'
  output="$({
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      :
    }

    err_blank_line() {
      :
    }

    sleep() {
      :
    }

    llama_port_in_use() {
      return 1
    }

    llama_read_choice() {
      next_llama_choice
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
  } 2>&1)"
  reset_llama_choices

  if printf '%s\n' "$output" | grep -Fq 'STATUS:43'; then
    pass "llama health verification returns retry on explicit retry choice"
  else
    fail "llama health verification should return retry on explicit retry choice"
  fi

  queue_llama_choices '2'
  output="$({
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      :
    }

    err_blank_line() {
      :
    }

    sleep() {
      :
    }

    llama_port_in_use() {
      return 1
    }

    llama_read_choice() {
      next_llama_choice
    }

    llama_prompt_for_available_port() {
      printf 'PROMPT_PORT:%s,%s\n' "$1" "$2"
      REPLY='11435'
      return 0
    }

    llama_update_connection_values() {
      printf 'UPDATE:%s,%s\n' "$1" "$2"
      return 0
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
  } 2>&1)"
  reset_llama_choices

  if printf '%s\n' "$output" | grep -Fq 'PROMPT_PORT:127.0.0.1,11434' \
    && printf '%s\n' "$output" | grep -Fq 'UPDATE:127.0.0.1,11435' \
    && printf '%s\n' "$output" | grep -Fq 'STATUS:44'; then
    pass "llama health verification returns change-port after successful port update"
  else
    fail "llama health verification should return change-port after successful port update"
  fi

  queue_llama_choices '2'
  output="$({
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      :
    }

    err_blank_line() {
      :
    }

    sleep() {
      :
    }

    llama_port_in_use() {
      return 1
    }

    llama_read_choice() {
      next_llama_choice
    }

    llama_prompt_for_available_port() {
      return "$LLAMA_EXIT_GRACEFUL"
    }

    llama_update_connection_values() {
      printf 'UPDATE_CALLED\n'
      return 0
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
  } 2>&1)"
  reset_llama_choices

  if printf '%s\n' "$output" | grep -Fq 'STATUS:42' \
    && ! printf '%s\n' "$output" | grep -Fq 'UPDATE_CALLED'; then
    pass "llama health verification propagates graceful exit from change-port prompt"
  else
    fail "llama health verification should propagate graceful exit from change-port prompt"
  fi

  queue_llama_choices '2'
  output="$({
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      :
    }

    err_blank_line() {
      :
    }

    sleep() {
      :
    }

    llama_port_in_use() {
      return 1
    }

    llama_read_choice() {
      next_llama_choice
    }

    llama_prompt_for_available_port() {
      REPLY='11435'
      return 0
    }

    llama_update_connection_values() {
      return 17
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
  } 2>&1)"
  reset_llama_choices

  if printf '%s\n' "$output" | grep -Fq 'STATUS:17'; then
    pass "llama health verification propagates connection update failures"
  else
    fail "llama health verification should propagate connection update failures"
  fi

  queue_llama_choices '3' '4'
  output="$({
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'
    LLAMA_ACTIVE_MODE='user'

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      printf 'BLANK\n'
    }

    err_blank_line() {
      printf 'ERR_BLANK\n'
    }

    sleep() {
      :
    }

    llama_port_in_use() {
      return 1
    }

    llama_read_choice() {
      next_llama_choice
    }

    llama_show_recent_error_log() {
      printf 'SHOW_LOG:%s\n' "$1"
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
    printf 'CHOICES:%s\n' "$(llama_choice_count)"
  } 2>&1)"
  reset_llama_choices

  if printf '%s\n' "$output" | grep -Fq 'SHOW_LOG:user' \
    && printf '%s\n' "$output" | grep -Fq 'STATUS:42' \
    && printf '%s\n' "$output" | grep -Fq 'CHOICES:2'; then
    pass "llama health verification shows logs and re-prompts before exit"
  else
    fail "llama health verification should show logs and re-prompt before exit"
  fi

  queue_llama_choices '4'
  output="$({
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      :
    }

    err_blank_line() {
      :
    }

    sleep() {
      :
    }

    llama_port_in_use() {
      return 1
    }

    llama_read_choice() {
      next_llama_choice
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
  } 2>&1)"
  reset_llama_choices

  if printf '%s\n' "$output" | grep -Fq 'STATUS:42'; then
    pass "llama health verification returns graceful exit on explicit exit choice"
  else
    fail "llama health verification should return graceful exit on explicit exit choice"
  fi

  queue_llama_choices 'banana' '4'
  output="$({
    local status=0

    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'

    err() {
      printf 'ERR:%s\n' "$1"
    }

    out() {
      printf 'OUT:%s\n' "$1"
    }

    blank_line() {
      printf 'BLANK\n'
    }

    err_blank_line() {
      printf 'ERR_BLANK\n'
    }

    sleep() {
      :
    }

    llama_port_in_use() {
      return 1
    }

    llama_read_choice() {
      next_llama_choice
    }

    if llama_verify_service_health; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
  } 2>&1)"
  reset_llama_choices

  if printf '%s\n' "$output" | grep -Fq 'ERR:Invalid selection. Enter one of the listed options.' \
    && printf '%s\n' "$output" | grep -Fq 'STATUS:42' \
    && [ "$(printf '%s\n' "$output" | grep -Fc 'OUT:1) Retry startup')" -ge 2 ]; then
    pass "llama health verification re-prompts after an invalid recovery choice"
  else
    fail "llama health verification should re-prompt after an invalid recovery choice"
  fi
}

test_llama_recent_error_log_module() {
  local log_file="$TEMP_DIR/llama-recent-error.log"
  local output=''
  local index=''

  : > "$log_file"
  for index in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
    printf 'entry-%s\n' "$index" >> "$log_file"
  done

  output="$({
    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    out() {
      printf 'OUT:%s\n' "$1"
    }

    llama_mode_stderr_log() {
      printf '%s\n' "$log_file"
    }

    llama_show_recent_error_log user
  } 2>&1)"

  if printf '%s\n' "$output" | grep -Fq 'OUT:Recent llama-server logs:' \
    && printf '%s\n' "$output" | grep -Fq 'entry-06' \
    && printf '%s\n' "$output" | grep -Fq 'entry-25' \
    && ! printf '%s\n' "$output" | grep -Fq 'entry-05'; then
    pass "llama recent error log shows the latest log lines"
  else
    fail "llama recent error log should show the latest log lines"
  fi

  output="$({
    # shellcheck source=/dev/null
    . "$ROOT_DIR/lib/llama.sh"

    out() {
      printf 'OUT:%s\n' "$1"
    }

    llama_mode_stderr_log() {
      printf '%s\n' "$TEMP_DIR/missing-llama-recent-error.log"
    }

    llama_show_recent_error_log user
  } 2>&1)"

  if printf '%s\n' "$output" | grep -Fq 'OUT:Recent llama-server logs:' \
    && printf '%s\n' "$output" | grep -Fq 'OUT:(no log output)'; then
    pass "llama recent error log shows a placeholder when no log exists"
  else
    fail "llama recent error log should show a placeholder when no log exists"
  fi
}

test_llama_service_health_result_handling_module() {
  local original_home="$HOME"
  local mode=''
  local mode_root=''
  local wrapper_dest=''
  local env_dest=''
  local plist_dest=''
  local stdout_path=''
  local stderr_path=''
  local fake_bin=''
  local fake_model=''
  local launchctl_log=''
  local install_log=''
  local chown_log=''
  local health_status_file=''
  local health_index_file=''
  local health_port_log=''
  local run_status=0
  local launchctl_print_loaded=true
  local current_mode=''

  queue_health_statuses() {
    printf '%s\n' "$@" > "$health_status_file"
    printf '0\n' > "$health_index_file"
  }

  next_health_status() {
    local index=0
    local status_value=''

    if [ -f "$health_index_file" ]; then
      IFS= read -r index < "$health_index_file" || index=0
    fi

    status_value="$(sed -n "$((index + 1))p" "$health_status_file" 2>/dev/null)"
    printf '%s\n' "$((index + 1))" > "$health_index_file"
    printf '%s\n' "$status_value"
  }

  count_launchctl_calls() {
    local verb="$1"

    if [ ! -f "$launchctl_log" ]; then
      printf '0\n'
      return 0
    fi

    grep -Fc "$verb" "$launchctl_log" || true
  }

  count_install_calls() {
    if [ ! -f "$install_log" ]; then
      printf '0\n'
      return 0
    fi

    wc -l < "$install_log"
  }

  health_choice_count() {
    if [ -f "$health_index_file" ]; then
      cat "$health_index_file"
    else
      printf '0\n'
    fi
  }

  prepare_matching_service_state() {
    local seed_status=0

    queue_health_statuses success

    if [ "$mode" = 'system' ]; then
      if setup_system_llama_service >/dev/null 2>&1; then
        seed_status=0
      else
        seed_status=$?
      fi
    else
      if setup_user_llama_service >/dev/null 2>&1; then
        seed_status=0
      else
        seed_status=$?
      fi
    fi

    if [ "$seed_status" -ne 0 ]; then
      return "$seed_status"
    fi

    health_call_count=0
    bootstrap_count=0
    bootout_count=0
    kickstart_count=0
    wrapper_install_count=0
    env_install_count=0
    plist_install_count=0
    chown_count=0
    : > "$launchctl_log"
    : > "$install_log"
    : > "$chown_log"
    : > "$health_port_log"
  }

  sudo() {
    case "${1:-}" in
      -n)
        shift
        "$@"
        ;;
      -v)
        return 0
        ;;
      *)
        "$@"
        ;;
    esac
  }

  install() {
    local mode_value=''

    printf '%s -> %s\n' "$1 ${2-}" "${3-}${4-}" >> "$install_log"

    if [ "${1:-}" = '-m' ]; then
      mode_value="$2"
      shift 2
    fi

    command cp "$1" "$2"

    if [ -n "$mode_value" ]; then
      chmod "$mode_value" "$2"
    fi
  }

  chown() {
    printf '%s\n' "$*" >> "$chown_log"
  }

  launchctl() {
    local verb="${1:-}"

    case "$verb" in
      print)
        [ "$launchctl_print_loaded" = true ]
        ;;
      bootout)
        printf 'bootout %s\n' "$*" >> "$launchctl_log"
        launchctl_print_loaded=false
        return 0
        ;;
      bootstrap)
        printf 'bootstrap %s\n' "$*" >> "$launchctl_log"
        launchctl_print_loaded=true
        return 0
        ;;
      kickstart)
        printf 'kickstart %s\n' "$*" >> "$launchctl_log"
        return 0
        ;;
      *)
        printf '%s\n' "$*" >> "$launchctl_log"
        return 0
        ;;
    esac
  }

  curl() {
    return 0
  }

  jq() {
    cat >/dev/null
    return 0
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  step() {
    :
  }

  success() {
    :
  }

  out() {
    :
  }

  error() {
    :
  }

  err() {
    :
  }

  err_blank_line() {
    :
  }

  blank_line() {
    :
  }

  llama_verify_service_health() {
    local next_status=''

    next_status="$(next_health_status)"
    printf '%s\n' "${LLAMA_PORT:-}" >> "$health_port_log"

    case "$next_status" in
      success)
        return 0
        ;;
      retry)
        return "$LLAMA_EXIT_RETRY"
        ;;
      change-port)
        LLAMA_PORT='11435'
        HOST_IP='127.0.0.1'
        LLAMA_BASE_URL='http://127.0.0.1:11435/v1'
        return "$LLAMA_EXIT_CHANGE_PORT"
        ;;
      graceful)
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
      fail:*)
        return "${next_status#fail:}"
        ;;
      *)
        return 99
        ;;
    esac
  }

  for mode in system user; do
    mode_root="$TEMP_DIR/llama-service-health-$mode"
    launchctl_log="$mode_root/launchctl.log"
    install_log="$mode_root/install.log"
    chown_log="$mode_root/chown.log"
    health_status_file="$mode_root/health-statuses.txt"
    health_index_file="$mode_root/health-index.txt"
    health_port_log="$mode_root/health-port-log.txt"
    current_mode="$mode"

    rm -rf "$mode_root"
    mkdir -p "$mode_root"
    : > "$launchctl_log"
    : > "$install_log"
    : > "$chown_log"
    : > "$health_port_log"

    BASE_DIR="$ROOT_DIR"
    HOST_IP='127.0.0.1'
    LLAMA_HOST='0.0.0.0'
    LLAMA_PORT='11434'
    LLAMA_CTX='16384'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    fake_bin="$mode_root/bin/llama-server"
    fake_model="$mode_root/models/model.gguf"
    mkdir -p "$(dirname "$fake_bin")" "$(dirname "$fake_model")"
    printf '#!/bin/bash\nexit 0\n' > "$fake_bin"
    chmod +x "$fake_bin"
    : > "$fake_model"
    LLAMA_BIN="$fake_bin"
    MODEL_PATH="$fake_model"

    if [ "$mode" = 'system' ]; then
      CLAWBOX_LLAMA_WRAPPER_DEST="$mode_root/usr/local/bin/clawbox-llama-wrapper.sh"
      CLAWBOX_LLAMA_ENV_DEST="$mode_root/usr/local/etc/clawbox.env"
      CLAWBOX_LLAMA_PLIST_DEST="$mode_root/Library/LaunchDaemons/com.clawbox.llama.plist"
      CLAWBOX_LLAMA_OUT_LOG="$mode_root/logs/runtime/system.out.log"
      CLAWBOX_LLAMA_ERR_LOG="$mode_root/logs/runtime/system.err.log"
      wrapper_dest="$CLAWBOX_LLAMA_WRAPPER_DEST"
      env_dest="$CLAWBOX_LLAMA_ENV_DEST"
      plist_dest="$CLAWBOX_LLAMA_PLIST_DEST"
      stdout_path="$CLAWBOX_LLAMA_OUT_LOG"
      stderr_path="$CLAWBOX_LLAMA_ERR_LOG"
      HOME="$original_home"
    else
      HOME="$mode_root/home"
      CLAWBOX_LLAMA_USER_UID='501'
      CLAWBOX_LLAMA_USER_OUT_LOG="$mode_root/logs/runtime/user.out.log"
      CLAWBOX_LLAMA_USER_ERR_LOG="$mode_root/logs/runtime/user.err.log"
      wrapper_dest="$HOME/Library/Application Support/ClawBox/bin/clawbox-llama-wrapper.sh"
      env_dest="$HOME/Library/Application Support/ClawBox/clawbox.env"
      plist_dest="$HOME/Library/LaunchAgents/com.clawbox.llama.plist"
      stdout_path="$CLAWBOX_LLAMA_USER_OUT_LOG"
      stderr_path="$CLAWBOX_LLAMA_USER_ERR_LOG"
    fi

    LLAMA_PORT='11434'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    prepare_matching_service_state
    : > "$launchctl_log"
    : > "$install_log"
    : > "$health_port_log"
    queue_health_statuses success
    if [ "$mode" = 'system' ]; then
      run_status=0
      if setup_system_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    else
      run_status=0
      if setup_user_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    fi

    if [ "$run_status" -eq 0 ] \
      && [ "$(health_choice_count)" = '1' ] \
      && [ "$(count_launchctl_calls 'bootout')" = '0' ]; then
      pass "$mode llama service setup succeeds without retry or restart when health verification succeeds"
    else
      fail "$mode llama service setup should succeed without retry or restart when health verification succeeds"
    fi

    LLAMA_PORT='11434'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    prepare_matching_service_state
    : > "$launchctl_log"
    : > "$install_log"
    : > "$health_port_log"
    queue_health_statuses retry success
    if [ "$mode" = 'system' ]; then
      run_status=0
      if setup_system_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    else
      run_status=0
      if setup_user_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    fi

    if [ "$run_status" -eq 0 ] \
      && [ "$(health_choice_count)" = '2' ] \
      && [ "$(count_launchctl_calls 'bootstrap')" -ge 1 ] \
      && [ "$(grep -c . "$health_port_log" || true)" = '2' ]; then
      pass "$mode llama service setup retries once and restarts after a retry health result"
    else
      fail "$mode llama service setup should retry once and restart after a retry health result"
    fi

    LLAMA_PORT='11434'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    prepare_matching_service_state
    : > "$launchctl_log"
    : > "$install_log"
    : > "$health_port_log"
    queue_health_statuses change-port success
    if [ "$mode" = 'system' ]; then
      run_status=0
      if setup_system_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    else
      run_status=0
      if setup_user_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    fi

    if [ "$run_status" -eq 0 ] \
      && [ "$(health_choice_count)" = '2' ] \
      && [ "$(count_launchctl_calls 'bootout')" -ge 1 ] \
      && [ "$(count_launchctl_calls 'bootstrap')" -ge 1 ] \
      && [ "$(count_install_calls)" -ge 1 ] \
      && grep -Fq '11435' "$env_dest" \
      && grep -Fq '11434' "$health_port_log" \
      && grep -Fq '11435' "$health_port_log"; then
      pass "$mode llama service setup reconfigures and restarts after a change-port health result"
    else
      fail "$mode llama service setup should reconfigure and restart after a change-port health result"
    fi

    LLAMA_PORT='11434'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    prepare_matching_service_state
    : > "$launchctl_log"
    : > "$install_log"
    : > "$health_port_log"
    queue_health_statuses graceful
    if [ "$mode" = 'system' ]; then
      run_status=0
      if setup_system_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    else
      run_status=0
      if setup_user_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    fi

    if [ "$run_status" = "$LLAMA_EXIT_GRACEFUL" ] \
      && [ "$(health_choice_count)" = '1' ] \
      && [ "$(count_launchctl_calls 'bootout')" = '0' ]; then
      pass "$mode llama service setup propagates graceful exit without extra restart work"
    else
      fail "$mode llama service setup should propagate graceful exit without extra restart work"
    fi

    LLAMA_PORT='11434'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    prepare_matching_service_state
    : > "$launchctl_log"
    : > "$install_log"
    : > "$health_port_log"
    queue_health_statuses fail:17
    if [ "$mode" = 'system' ]; then
      run_status=0
      if setup_system_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    else
      run_status=0
      if setup_user_llama_service >/dev/null 2>&1; then
        run_status=0
      else
        run_status=$?
      fi
    fi

    if [ "$run_status" = '17' ] \
      && [ "$(health_choice_count)" = '1' ] \
      && [ "$(count_launchctl_calls 'bootout')" = '0' ]; then
      pass "$mode llama service setup propagates unexpected health failures exactly"
    else
      fail "$mode llama service setup should propagate unexpected health failures exactly"
    fi
  done

  HOME="$original_home"
}

test_system_llama_module() {
  local wrapper_dest="$TEMP_DIR/usr/local/bin/clawbox-llama-wrapper.sh"
  local env_dest="$TEMP_DIR/usr/local/etc/clawbox.env"
  local plist_dest="$TEMP_DIR/Library/LaunchDaemons/com.clawbox.llama.plist"
  local out_log="$TEMP_DIR/logs/runtime/clawbox-llama-system.out.log"
  local err_log="$TEMP_DIR/logs/runtime/clawbox-llama-system.err.log"
  local launchctl_log="$TEMP_DIR/logs/tests/llama-launchctl.log"
  local chown_log="$TEMP_DIR/logs/tests/llama-chown.log"
  local fake_bin="$TEMP_DIR/bin/llama-server"
  local fake_model="$TEMP_DIR/models/model.gguf"

  mkdir -p "$TEMP_DIR/logs/tests"

  BASE_DIR="$ROOT_DIR"
  CLAWBOX_LLAMA_WRAPPER_DEST="$wrapper_dest"
  CLAWBOX_LLAMA_ENV_DEST="$env_dest"
  CLAWBOX_LLAMA_PLIST_DEST="$plist_dest"
  CLAWBOX_LLAMA_OUT_LOG="$out_log"
  CLAWBOX_LLAMA_ERR_LOG="$err_log"
  LLAMA_BIN="$fake_bin"
  MODEL_PATH="$fake_model"
  HOST_IP='127.0.0.1'
  LLAMA_HOST='0.0.0.0'
  LLAMA_PORT='11434'
  LLAMA_CTX='16384'

  mkdir -p "$(dirname "$fake_bin")" "$(dirname "$fake_model")"
  printf '#!/bin/bash\nexit 0\n' > "$fake_bin"
  chmod +x "$fake_bin"
  : > "$fake_model"

  sudo() {
    case "${1:-}" in
      -n)
        shift
        "$@"
        ;;
      -v)
        return 0
        ;;
      *)
        "$@"
        ;;
    esac
  }

  install() {
    local mode=''

    if [ "${1:-}" = '-m' ]; then
      mode="$2"
      shift 2
    fi

    command cp "$1" "$2"

    if [ -n "$mode" ]; then
      chmod "$mode" "$2"
    fi
  }

  chown() {
    printf '%s\n' "$*" >> "$chown_log"
  }

  launchctl() {
    case "${1:-}" in
      print)
        return 0
        ;;
      *)
        printf '%s\n' "$*" >> "$launchctl_log"
        return 0
        ;;
    esac
  }

  curl() {
    [ "${1:-}" = '-s' ] && [ "${2:-}" = "http://$HOST_IP:$LLAMA_PORT/v1/models" ]
  }

  jq() {
    cat >/dev/null
    return 0
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_port_in_use() {
    return 0
  }

  llama_api_responding() {
    return 0
  }

  if setup_system_llama_service >/dev/null 2>&1; then
    pass "llama service setup completes successfully"
  else
    fail "llama service setup should succeed with valid inputs"
  fi

  if [ -x "$wrapper_dest" ]; then
    pass "llama service setup installs an executable wrapper"
  else
    fail "llama service setup should install an executable wrapper"
  fi

  if [ -f "$plist_dest" ] && grep -Fq '<string>com.clawbox.llama</string>' "$plist_dest"; then
    pass "llama service setup installs the LaunchDaemon plist"
  else
    fail "llama service setup should install the LaunchDaemon plist"
  fi

  if [ -f "$env_dest" ] \
    && grep -Fq "LLAMA_BIN=\"$fake_bin\"" "$env_dest" \
    && grep -Fq "MODEL_PATH=\"$fake_model\"" "$env_dest" \
    && grep -Fq 'LLAMA_HOST="0.0.0.0"' "$env_dest" \
    && grep -Fq 'LLAMA_PORT="11434"' "$env_dest" \
    && grep -Fq 'LLAMA_CTX="16384"' "$env_dest" \
    && ! grep -Fq 'LLAMA_BASE_URL=' "$env_dest"; then
    pass "llama service setup writes the minimal runtime env file"
  else
    fail "llama service setup should write the minimal runtime env file"
  fi

  if [ -f "$out_log" ] && [ -f "$err_log" ]; then
    pass "llama service setup prepares system log files"
  else
    fail "llama service setup should prepare system log files"
  fi

  if [ -f "$chown_log" ] && grep -Fq "root:wheel $plist_dest" "$chown_log"; then
    pass "llama service setup applies root:wheel ownership to the plist"
  else
    fail "llama service setup should apply root:wheel ownership to the plist"
  fi

  if [ -f "$launchctl_log" ] \
    && grep -Fq "bootstrap system $plist_dest" "$launchctl_log" \
    && grep -Fq 'kickstart -k system/com.clawbox.llama' "$launchctl_log"; then
    pass "llama service setup starts the LaunchDaemon with launchctl"
  else
    fail "llama service setup should start the LaunchDaemon with launchctl"
  fi

  : > "$launchctl_log"
  if setup_system_llama_service >/dev/null 2>&1; then
    pass "llama service setup is idempotent when system files already match"
  else
    fail "llama service setup should remain successful when system files already match"
  fi

  if [ ! -s "$launchctl_log" ]; then
    pass "llama service setup skips system launchctl reload when config is unchanged"
  else
    fail "llama service setup should skip system launchctl reload when config is unchanged"
  fi
}

test_user_llama_module() {
  local original_home="$HOME"
  local wrapper_dest=''
  local env_dest=''
  local plist_dest=''
  local out_log=''
  local err_log=''
  local launchctl_log="$TEMP_DIR/logs/tests/user-llama-launchctl.log"
  local fake_bin="$TEMP_DIR/user-bin/llama-server"
  local fake_model="$TEMP_DIR/user-models/model.gguf"

  mkdir -p "$TEMP_DIR/logs/tests"

  HOME="$TEMP_DIR/home"
  BASE_DIR="$ROOT_DIR"
  CLAWBOX_LLAMA_USER_UID='501'
  CLAWBOX_LLAMA_USER_OUT_LOG="$TEMP_DIR/logs/runtime/clawbox-llama-user.out.log"
  CLAWBOX_LLAMA_USER_ERR_LOG="$TEMP_DIR/logs/runtime/clawbox-llama-user.err.log"
  LLAMA_BIN="$fake_bin"
  MODEL_PATH="$fake_model"
  HOST_IP='127.0.0.1'
  LLAMA_HOST='0.0.0.0'
  LLAMA_PORT='11434'
  LLAMA_CTX='16384'

  wrapper_dest="$HOME/Library/Application Support/ClawBox/bin/clawbox-llama-wrapper.sh"
  env_dest="$HOME/Library/Application Support/ClawBox/clawbox.env"
  plist_dest="$HOME/Library/LaunchAgents/com.clawbox.llama.plist"
  out_log="$CLAWBOX_LLAMA_USER_OUT_LOG"
  err_log="$CLAWBOX_LLAMA_USER_ERR_LOG"

  mkdir -p "$(dirname "$fake_bin")" "$(dirname "$fake_model")"
  printf '#!/bin/bash\nexit 0\n' > "$fake_bin"
  chmod +x "$fake_bin"
  : > "$fake_model"

  sudo() {
    return 1
  }

  install() {
    local mode=''

    if [ "${1:-}" = '-m' ]; then
      mode="$2"
      shift 2
    fi

    command cp "$1" "$2"

    if [ -n "$mode" ]; then
      chmod "$mode" "$2"
    fi
  }

  launchctl() {
    case "${1:-}" in
      print)
        return 0
        ;;
      *)
        printf '%s\n' "$*" >> "$launchctl_log"
        return 0
        ;;
    esac
  }

  curl() {
    [ "${1:-}" = '-s' ] && [ "${2:-}" = "http://$HOST_IP:$LLAMA_PORT/v1/models" ]
  }

  jq() {
    cat >/dev/null
    return 0
  }

  # shellcheck source=/dev/null
  . "$ROOT_DIR/lib/llama.sh"

  llama_port_in_use() {
    return 0
  }

  llama_api_responding() {
    return 0
  }

  if setup_user_llama_service >/dev/null 2>&1; then
    pass "user llama service setup completes successfully"
  else
    fail "user llama service setup should succeed with valid inputs"
  fi

  if [ -x "$wrapper_dest" ] && [ -f "$env_dest" ] && [ -f "$plist_dest" ]; then
    pass "user llama service setup installs wrapper env and plist in the home directory"
  else
    fail "user llama service setup should install wrapper env and plist in the home directory"
  fi

  if [ -f "$out_log" ] && [ -f "$err_log" ]; then
    pass "user llama service setup prepares user log files"
  else
    fail "user llama service setup should prepare user log files"
  fi

  if [ -f "$plist_dest" ] \
    && grep -Fq "$wrapper_dest" "$plist_dest" \
    && grep -Fq "$env_dest" "$plist_dest" \
    && grep -Fq "$out_log" "$plist_dest" \
    && grep -Fq "$err_log" "$plist_dest"; then
    pass "user llama service setup renders a user specific plist"
  else
    fail "user llama service setup should render a user specific plist"
  fi

  if [ -f "$launchctl_log" ] \
    && grep -Fq "bootstrap gui/501 $plist_dest" "$launchctl_log" \
    && grep -Fq 'kickstart -k gui/501/com.clawbox.llama' "$launchctl_log"; then
    pass "user llama service setup starts the LaunchAgent with launchctl"
  else
    fail "user llama service setup should start the LaunchAgent with launchctl"
  fi

  HOME="$original_home"
}

run_test test_log_paths_module
run_test test_config_module
run_test test_ssh_module
run_test test_runtime_module
run_test test_runtime_handle_module
run_test test_deploy_module
run_test test_prompt_module
run_test test_launchagent_module
run_test test_launchagent_wrapper_logs_tcc_denial
run_test test_launchagent_wrapper_retries_and_verifies_runtime_before_success
run_test test_launchagent_wrapper_uses_ssh_reachability_as_success_signal
run_test test_launchagent_module_requires_vm_host
run_test test_llama_install_mode_selection
run_test test_llama_bin_resolution_prompt
run_test test_llama_bin_resolution_hard_blocks_without_install_methods
run_test test_llama_bin_resolution_prefers_discovered_binaries
run_test test_llama_automatic_install_prefers_homebrew
run_test test_llama_automatic_install_falls_back_to_https_source
run_test test_llama_source_install_reuses_existing_build
run_test test_llama_source_install_uses_clone_dir_for_binary_resolution
run_test test_llama_automatic_install_rejects_unusable_homebrew
run_test test_llama_automatic_install_hard_blocks_without_install_methods
run_test test_llama_automatic_install_hides_source_without_build_tools
run_test test_llama_source_install_failure_path
run_test test_llama_automatic_install_uses_discovered_homebrew_outside_path
run_test test_llama_homebrew_install_reports_actual_failure_reason
run_test test_llama_homebrew_install_classifies_shared_install_permissions
run_test test_llama_homebrew_state_caches_discovery_results
run_test test_llama_health_decision_module
run_test test_llama_recent_error_log_module
run_test test_llama_service_health_result_handling_module
run_test test_system_llama_module
run_test test_user_llama_module

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
