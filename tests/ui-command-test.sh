#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/helpers/setup-harness.sh"

TEMP_DIR="$(mktemp -d)"
trap cleanup_temp_dir EXIT

write_ui_env() {
  cat > "$TEMP_DIR/.env" <<'EOF'
VM_HOST="tester@vm.example"
CLAWBOX_OPENCLAW_GATEWAY_PORT="18789"
EOF
}

load_ui_command() {
  CLAWBOX_UI_LIB_ONLY=true source "$ROOT_DIR/scripts/ui.sh"
}

install_successful_ui_stubs() {
  local ssh_log="$1"
  local open_log="$2"
  local tunnel_marker="$3"

  ssh() {
    printf '%s\n' "$*" >> "$ssh_log"
    case "$*" in
      *'echo ok'*)
        printf 'ok\n'
        ;;
      *'-f -N'*)
        : > "$tunnel_marker"
        ;;
    esac
    return 0
  }

  lsof() {
    return 1
  }

  pgrep() {
    [ -f "$tunnel_marker" ] || return 1
    printf '%s\n' '4242'
  }

  ps() {
    if [[ "$*" == *'4242'* ]]; then
      printf '%s\n' 'ssh -f -N -o BatchMode=yes -o ExitOnForwardFailure=yes -L 127.0.0.1:18790:127.0.0.1:18789 tester@vm.example'
      return 0
    fi
    return 1
  }

  curl() {
    printf '200'
  }

  open() {
    printf '%s\n' "$*" >> "$open_log"
    return 0
  }
}

test_clawbox_help_lists_ui_command() {
  local output=''

  output="$("$ROOT_DIR/clawbox" help)"
  assert_contains 'top-level help lists ui command' "$output" 'ui          Open the VM OpenClaw Web UI through an SSH tunnel'
  assert_contains 'top-level help shows ui no-open example' "$output" './clawbox ui --no-open'
}

test_ui_creates_loopback_tunnel_with_defaults() {
  local output='' ssh_log="$TEMP_DIR/ui-default-ssh.log" open_log="$TEMP_DIR/ui-default-open.log"
  local tunnel_marker="$TEMP_DIR/ui-default-started"

  write_ui_env
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    main --no-open
  } 2>&1)"

  assert_contains 'ui uses configured VM_HOST' "$(cat "$ssh_log")" 'tester@vm.example'
  assert_contains 'ui uses loopback-only local forward' "$(cat "$ssh_log")" '127.0.0.1:18790:127.0.0.1:18789'
  assert_contains 'ui uses BatchMode for SSH probes and tunnel' "$(cat "$ssh_log")" 'BatchMode=yes'
  assert_contains 'ui requires forward startup success' "$(cat "$ssh_log")" 'ExitOnForwardFailure=yes'
  assert_contains 'ui prints configured VM target' "$output" 'VM target: tester@vm.example'
  assert_contains 'ui prints local tunnel URL' "$output" 'Local URL: http://127.0.0.1:18790/'
  assert_contains 'ui reports gateway readiness' "$output" 'Gateway readiness: reachable through tunnel'
  assert_contains 'ui no-open suppresses browser launch' "$output" 'Browser: not opened (--no-open)'
  if printf '%s\n' "$output" | grep -Eq '^  (VM target|Local URL|Tunnel|Gateway readiness|Browser):'; then
    fail 'ui routine output should not indent ordinary status lines'
  else
    pass 'ui routine output avoids ordinary leading indentation'
  fi
  assert_not_contains 'ui no-open does not open browser' "$(cat "$open_log" 2>/dev/null || true)" 'http://'
}

test_ui_supports_explicit_port_override() {
  local output='' ssh_log="$TEMP_DIR/ui-port-ssh.log" open_log="$TEMP_DIR/ui-port-open.log"
  local tunnel_marker="$TEMP_DIR/ui-port-started"

  write_ui_env
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    ps() {
      printf '%s\n' 'ssh -f -N -L 127.0.0.1:18791:127.0.0.1:18789 tester@vm.example'
    }
    main --port 18791 --no-open
  } 2>&1)"

  assert_contains 'ui explicit port appears in SSH forward' "$(cat "$ssh_log")" '127.0.0.1:18791:127.0.0.1:18789'
  assert_contains 'ui explicit port appears in local URL' "$output" 'Local URL: http://127.0.0.1:18791/'
}

test_ui_rejects_invalid_port() {
  local output='' status=0

  write_ui_env
  set +e
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    main --port nope --no-open
  } 2>&1)"
  status=$?
  set -e

  assert_equals 'ui invalid port exits non-zero' "$status" '1'
  assert_contains 'ui invalid port explains valid range' "$output" 'Use an integer from 1 to 65535.'
}

test_ui_reports_missing_configuration() {
  local output='' status=0

  set +e
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR/missing-config"
    ENV_FILE="$TEMP_DIR/missing-config/.env"
    main --no-open
  } 2>&1)"
  status=$?
  set -e

  assert_equals 'ui missing .env exits non-zero' "$status" '1'
  assert_contains 'ui missing .env tells user to run setup' "$output" 'Missing .env. Run ./clawbox setup first.'
}

test_ui_reuses_existing_tunnel_without_duplicate_forward() {
  local output='' ssh_log="$TEMP_DIR/ui-reuse-ssh.log" open_log="$TEMP_DIR/ui-reuse-open.log"
  local tunnel_marker="$TEMP_DIR/ui-reuse-started"

  write_ui_env
  : > "$tunnel_marker"
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    VM_HOST='tester@vm.example'
    openclaw_webui_write_state 4242 18790
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    main --no-open
  } 2>&1)"

  assert_contains 'ui reports reused tunnel' "$output" 'Tunnel: reused'
  assert_not_contains 'ui reuse does not create duplicate tunnel' "$(cat "$ssh_log")" '-f -N'
}

test_ui_uses_fallback_for_unrelated_default_port_owner() {
  local output='' ssh_log="$TEMP_DIR/ui-fallback-ssh.log" open_log="$TEMP_DIR/ui-fallback-open.log"
  local tunnel_marker="$TEMP_DIR/ui-fallback-started"

  write_ui_env
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    lsof() {
      if [[ "$*" == *18790* ]]; then
        return 0
      fi
      return 1
    }
    ps() {
      if [[ "$*" == *'4242'* ]]; then
        printf '%s\n' 'ssh -f -N -L 127.0.0.1:18791:127.0.0.1:18789 tester@vm.example'
        return 0
      fi
      return 1
    }
    main --no-open
  } 2>&1)"

  assert_contains 'ui skips unrelated default port owner' "$(cat "$ssh_log")" '127.0.0.1:18791:127.0.0.1:18789'
  assert_contains 'ui reports deterministic fallback port' "$output" 'Local URL: http://127.0.0.1:18791/'
}

test_ui_fails_when_explicit_port_is_unrelated() {
  local output='' status=0

  write_ui_env
  set +e
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    ssh() {
      if [[ "$*" == *'echo ok'* ]]; then
        printf 'ok\n'
        return 0
      fi
      return 0
    }
    lsof() { return 0; }
    pgrep() { return 1; }
    main --port 18791 --no-open
  } 2>&1)"
  status=$?
  set -e

  assert_equals 'ui unrelated explicit port exits non-zero' "$status" '1'
  assert_contains 'ui unrelated explicit port is not assumed safe' "$output" 'Local port 18791 is already in use by another process.'
}

test_ui_reports_ssh_and_forward_failures() {
  local ssh_output='' forward_output='' status=0

  write_ui_env
  set +e
  ssh_output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    ssh() { return 255; }
    main --no-open
  } 2>&1)"
  status=$?
  set -e
  assert_equals 'ui SSH failure exits non-zero' "$status" '1'
  assert_contains 'ui SSH failure is actionable' "$ssh_output" 'Unable to connect to the VM over SSH'

  set +e
  forward_output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    ssh() {
      if [[ "$*" == *'echo ok'* ]]; then
        printf 'ok\n'
        return 0
      fi
      return 255
    }
    lsof() { return 1; }
    main --no-open
  } 2>&1)"
  status=$?
  set -e
  assert_equals 'ui forward failure exits non-zero' "$status" '1'
  assert_contains 'ui forward failure is actionable' "$forward_output" 'Could not establish the OpenClaw Web UI SSH tunnel.'
}

test_ui_reports_gateway_readiness_timeout() {
  local output='' status=0 ssh_log="$TEMP_DIR/ui-timeout-ssh.log" open_log="$TEMP_DIR/ui-timeout-open.log"
  local tunnel_marker="$TEMP_DIR/ui-timeout-started"

  write_ui_env
  set +e
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    OPENCLAW_WEBUI_READINESS_TIMEOUT=0
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    curl() { printf '000'; }
    main --no-open
  } 2>&1)"
  status=$?
  set -e

  assert_equals 'ui readiness timeout exits non-zero' "$status" '1'
  assert_contains 'ui readiness timeout names the tunnel URL' "$output" 'OpenClaw gateway did not become reachable through the tunnel at http://127.0.0.1:18790/.'
}

test_ui_opens_browser_without_gateway_token() {
  local output='' ssh_log="$TEMP_DIR/ui-browser-ssh.log" open_log="$TEMP_DIR/ui-browser-open.log"
  local tunnel_marker="$TEMP_DIR/ui-browser-started"

  write_ui_env
  output="$({
    load_ui_command
    BASE_DIR="$TEMP_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    main
  } 2>&1)"

  assert_contains 'ui opens local browser URL' "$(cat "$open_log")" 'http://127.0.0.1:18790/'
  assert_not_contains 'ui does not pass token in browser URL' "$(cat "$open_log")" 'token='
  assert_contains 'ui reports browser open success' "$output" 'OpenClaw Web UI opened in your browser.'
}

test_setup_offer_uses_shared_token_safe_tunnel() {
  local output='' ssh_log="$TEMP_DIR/ui-setup-ssh.log" open_log="$TEMP_DIR/ui-setup-open.log"
  local tunnel_marker="$TEMP_DIR/ui-setup-started"

  output="$({
    BASE_DIR="$TEMP_DIR"
    rm -rf "$BASE_DIR/.clawbox"
    VM_HOST='tester@vm.example'
    OPENCLAW_RUNTIME_MANAGEMENT_STATE='managed by VM launchd'
    source "$ROOT_DIR/lib/openclaw-webui.sh"
    prompt_yes_no() { REPLY=true; }
    is_yes() { [ "$1" = true ]; }
    openclaw_webui_can_prompt() { return 0; }
    vm_openclaw_gateway_port() { printf '18789\n'; }
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    offer_openclaw_webui
  } 2>&1)"

  assert_contains 'setup Web UI offer still opens browser' "$output" 'OpenClaw Web UI opened in your browser.'
  assert_contains 'setup Web UI offer uses loopback tunnel' "$(cat "$ssh_log")" '127.0.0.1:18790:127.0.0.1:18789'
  assert_not_contains 'setup Web UI offer does not pass token to open' "$(cat "$open_log")" 'token='
}

test_ui_installs_launchagent_service_with_default_port() {
  local output='' ssh_log="$TEMP_DIR/ui-service-ssh.log" open_log="$TEMP_DIR/ui-service-open.log"
  local launchctl_log="$TEMP_DIR/ui-service-launchctl.log"
  local tunnel_marker="$TEMP_DIR/ui-service-started"
  local home="$TEMP_DIR/ui-service-home"

  write_ui_env
  output="$({
    load_ui_command
    HOME="$home"
    BASE_DIR="$ROOT_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    launchctl() {
      printf '%s\n' "$*" >> "$launchctl_log"
      if [ "${1:-}" = 'print' ]; then
        return 1
      fi
      if [ "${1:-}" = 'load' ] || [ "${1:-}" = 'unload' ]; then
        return 0
      fi
      return 1
    }
    main --install-service --no-open
  } 2>&1)"

  assert_contains 'ui install service reports verification' "$output" 'OpenClaw Web UI tunnel service installed and verified.'
  assert_contains 'ui install service uses expected label' "$output" 'Service label: com.clawbox.openclaw-ui-tunnel'
  assert_contains 'ui install service loads LaunchAgent' "$(cat "$launchctl_log")" "load $home/Library/LaunchAgents/com.clawbox.openclaw-ui-tunnel.plist"
  assert_contains 'ui install service wrapper is installed executable' "$(stat -f '%A %N' "$home/Library/Application Support/ClawBox/bin/openclaw-ui-tunnel.sh" 2>/dev/null || stat -c '%a %n' "$home/Library/Application Support/ClawBox/bin/openclaw-ui-tunnel.sh")" '755'
  assert_contains 'ui install service env persists default port' "$(cat "$home/Library/Application Support/ClawBox/openclaw-ui-tunnel.env")" 'OPENCLAW_WEBUI_TUNNEL_PORT=18790'
  assert_contains 'ui install service env persists VM target' "$(cat "$home/Library/Application Support/ClawBox/openclaw-ui-tunnel.env")" 'VM_HOST=tester@vm.example'
  assert_contains 'ui install service plist keeps launchd retry on failure' "$(cat "$home/Library/LaunchAgents/com.clawbox.openclaw-ui-tunnel.plist")" '<key>SuccessfulExit</key>'
  assert_not_contains 'ui install service output does not print token' "$output" 'token='
}

test_ui_installs_launchagent_service_with_explicit_port() {
  local output='' ssh_log="$TEMP_DIR/ui-service-port-ssh.log" open_log="$TEMP_DIR/ui-service-port-open.log"
  local tunnel_marker="$TEMP_DIR/ui-service-port-started"
  local home="$TEMP_DIR/ui-service-port-home"

  write_ui_env
  output="$({
    load_ui_command
    HOME="$home"
    BASE_DIR="$ROOT_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    ps() {
      printf '%s\n' 'ssh -f -N -L 127.0.0.1:18791:127.0.0.1:18789 tester@vm.example'
    }
    launchctl() {
      if [ "${1:-}" = 'print' ]; then
        return 1
      fi
      if [ "${1:-}" = 'load' ] || [ "${1:-}" = 'unload' ]; then
        return 0
      fi
      return 1
    }
    main --install-service --port 18791
  } 2>&1)"

  assert_contains 'ui install service explicit port is reported' "$output" 'Local URL: http://127.0.0.1:18791/'
  assert_contains 'ui install service explicit port is persisted' "$(cat "$home/Library/Application Support/ClawBox/openclaw-ui-tunnel.env")" 'OPENCLAW_WEBUI_TUNNEL_PORT=18791'
}

test_ui_service_rejects_unrelated_configured_port_owner() {
  local output='' status=0
  local home="$TEMP_DIR/ui-service-occupied-home"

  write_ui_env
  set +e
  output="$({
    load_ui_command
    HOME="$home"
    BASE_DIR="$ROOT_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    ssh() {
      if [[ "$*" == *'echo ok'* ]]; then
        printf 'ok\n'
        return 0
      fi
      return 0
    }
    pgrep() { return 1; }
    lsof() { return 0; }
    main --install-service --port 18790
  } 2>&1)"
  status=$?
  set -e

  assert_equals 'ui install service occupied port exits non-zero' "$status" '1'
  assert_contains 'ui install service occupied port does not fallback silently' "$output" 'Choose another persistent port with ./clawbox ui --install-service --port <port>.'
}

test_ui_status_reports_launchagent_and_tunnel() {
  local output='' ssh_log="$TEMP_DIR/ui-status-ssh.log" open_log="$TEMP_DIR/ui-status-open.log"
  local tunnel_marker="$TEMP_DIR/ui-status-started"
  local home="$TEMP_DIR/ui-status-home"

  write_ui_env
  output="$({
    load_ui_command
    HOME="$home"
    BASE_DIR="$ROOT_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    mkdir -p "$home/Library/Application Support/ClawBox/bin" "$home/Library/Application Support/ClawBox/state" "$home/Library/LaunchAgents"
    : > "$home/Library/LaunchAgents/com.clawbox.openclaw-ui-tunnel.plist"
    cp "$ROOT_DIR/host/scripts/openclaw-ui-tunnel.sh" "$home/Library/Application Support/ClawBox/bin/openclaw-ui-tunnel.sh"
    chmod +x "$home/Library/Application Support/ClawBox/bin/openclaw-ui-tunnel.sh"
    cat > "$home/Library/Application Support/ClawBox/openclaw-ui-tunnel.env" <<EOF
VM_HOST=tester@vm.example
OPENCLAW_WEBUI_TUNNEL_PORT=18790
OPENCLAW_WEBUI_GATEWAY_PORT=18789
OPENCLAW_WEBUI_STATE_DIR="$home/Library/Application Support/ClawBox/state"
EOF
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    VM_HOST='tester@vm.example'
    OPENCLAW_WEBUI_STATE_DIR="$home/Library/Application Support/ClawBox/state"
    openclaw_webui_write_state 4242 18790
    launchctl() { return 0; }
    main --status
  } 2>&1)"

  assert_contains 'ui status reports operational service' "$output" 'OpenClaw Web UI tunnel service: loaded and operational'
  assert_contains 'ui status reports tunnel ready' "$output" 'OpenClaw Web UI tunnel: ready'
  if printf '%s\n' "$output" | grep -Eq '^  (Service label|Configured VM target|Local URL|stdout log|stderr log):'; then
    fail 'ui status service output should not indent ordinary lines'
  else
    pass 'ui status service output avoids ordinary leading indentation'
  fi
}

test_ui_stop_unloads_service_before_stopping_tunnel() {
  local output='' ssh_log="$TEMP_DIR/ui-stop-ssh.log" open_log="$TEMP_DIR/ui-stop-open.log"
  local kill_log="$TEMP_DIR/ui-stop-kill.log" launchctl_log="$TEMP_DIR/ui-stop-launchctl.log"
  local tunnel_marker="$TEMP_DIR/ui-stop-started"
  local home="$TEMP_DIR/ui-stop-home"

  write_ui_env
  output="$({
    load_ui_command
    HOME="$home"
    BASE_DIR="$ROOT_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    mkdir -p "$home/Library/Application Support/ClawBox/state"
    cat > "$home/Library/Application Support/ClawBox/openclaw-ui-tunnel.env" <<EOF
VM_HOST=tester@vm.example
OPENCLAW_WEBUI_TUNNEL_PORT=18790
OPENCLAW_WEBUI_GATEWAY_PORT=18789
OPENCLAW_WEBUI_STATE_DIR="$home/Library/Application Support/ClawBox/state"
EOF
    VM_HOST='tester@vm.example'
    OPENCLAW_WEBUI_STATE_DIR="$home/Library/Application Support/ClawBox/state"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    openclaw_webui_write_state 4242 18790
    launchctl() {
      printf '%s\n' "$*" >> "$launchctl_log"
      return 0
    }
    kill() {
      printf '%s\n' "$*" >> "$kill_log"
      return 0
    }
    main --stop
  } 2>&1)"

  assert_contains 'ui stop unloads service to avoid respawn' "$output" 'OpenClaw Web UI tunnel service unloaded to prevent automatic restart.'
  assert_contains 'ui stop unloads launchd label' "$(cat "$launchctl_log")" 'unload'
  assert_contains 'ui stop kills only recorded matching tunnel' "$(cat "$kill_log")" '4242'
}

test_ui_remove_service_removes_managed_artifacts() {
  local output='' home="$TEMP_DIR/ui-remove-home"

  write_ui_env
  output="$({
    load_ui_command
    HOME="$home"
    BASE_DIR="$ROOT_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    mkdir -p "$home/Library/Application Support/ClawBox/bin" "$home/Library/Application Support/ClawBox/state" "$home/Library/LaunchAgents"
    : > "$home/Library/Application Support/ClawBox/bin/openclaw-ui-tunnel.sh"
    : > "$home/Library/Application Support/ClawBox/openclaw-ui-tunnel.env"
    : > "$home/Library/LaunchAgents/com.clawbox.openclaw-ui-tunnel.plist"
    launchctl() { return 1; }
    main --remove-service
  } 2>&1)"

  assert_contains 'ui remove service reports removal' "$output" 'OpenClaw Web UI tunnel service removed.'
  if [ ! -e "$home/Library/LaunchAgents/com.clawbox.openclaw-ui-tunnel.plist" ] \
    && [ ! -e "$home/Library/Application Support/ClawBox/openclaw-ui-tunnel.env" ]; then
    pass 'ui remove service removes managed plist and environment'
  else
    fail 'ui remove service should remove managed plist and environment'
  fi
}

test_ui_prompts_once_for_persistent_service_after_success() {
  local output='' ssh_log="$TEMP_DIR/ui-prompt-ssh.log" open_log="$TEMP_DIR/ui-prompt-open.log"
  local tunnel_marker="$TEMP_DIR/ui-prompt-started"
  local home="$TEMP_DIR/ui-prompt-home"

  write_ui_env
  output="$({
    load_ui_command
    HOME="$home"
    BASE_DIR="$ROOT_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    openclaw_webui_can_prompt() { return 0; }
    prompt_yes_no() {
      printf 'PROMPT:%s %s\n' "$1" "$2"
      REPLY='false'
    }
    is_yes() { [ "$1" = true ]; }
    main --no-open
  } 2>&1)"

  assert_contains 'ui prompts after successful on-demand tunnel' "$output" 'PROMPT:Keep the OpenClaw UI tunnel available automatically at login? n'
  mkdir -p "$home/Library/Application Support/ClawBox/bin" "$home/Library/LaunchAgents"
  : > "$home/Library/Application Support/ClawBox/bin/openclaw-ui-tunnel.sh"
  chmod +x "$home/Library/Application Support/ClawBox/bin/openclaw-ui-tunnel.sh"
  : > "$home/Library/Application Support/ClawBox/openclaw-ui-tunnel.env"
  : > "$home/Library/LaunchAgents/com.clawbox.openclaw-ui-tunnel.plist"

  output="$({
    load_ui_command
    HOME="$home"
    BASE_DIR="$ROOT_DIR"
    ENV_FILE="$TEMP_DIR/.env"
    install_successful_ui_stubs "$ssh_log" "$open_log" "$tunnel_marker"
    openclaw_webui_can_prompt() { return 0; }
    prompt_yes_no() {
      printf 'PROMPT:%s %s\n' "$1" "$2"
      REPLY='false'
    }
    is_yes() { [ "$1" = true ]; }
    main --no-open
  } 2>&1)"
  assert_not_contains 'ui does not repeat persistence prompt when service installed' "$output" 'Keep the OpenClaw UI tunnel available automatically at login?'
}

run_test test_clawbox_help_lists_ui_command
run_test test_ui_creates_loopback_tunnel_with_defaults
run_test test_ui_supports_explicit_port_override
run_test test_ui_rejects_invalid_port
run_test test_ui_reports_missing_configuration
run_test test_ui_reuses_existing_tunnel_without_duplicate_forward
run_test test_ui_uses_fallback_for_unrelated_default_port_owner
run_test test_ui_fails_when_explicit_port_is_unrelated
run_test test_ui_reports_ssh_and_forward_failures
run_test test_ui_reports_gateway_readiness_timeout
run_test test_ui_opens_browser_without_gateway_token
run_test test_setup_offer_uses_shared_token_safe_tunnel
run_test test_ui_installs_launchagent_service_with_default_port
run_test test_ui_installs_launchagent_service_with_explicit_port
run_test test_ui_service_rejects_unrelated_configured_port_owner
run_test test_ui_status_reports_launchagent_and_tunnel
run_test test_ui_stop_unloads_service_before_stopping_tunnel
run_test test_ui_remove_service_removes_managed_artifacts
run_test test_ui_prompts_once_for_persistent_service_after_success

if [ "$FAILURES" -ne 0 ]; then
  printf 'FAIL: ui command test suite failed with %s issues\n' "$FAILURES"
  exit 1
fi

printf 'PASS: ui command test suite\n'
