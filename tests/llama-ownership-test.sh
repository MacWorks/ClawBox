#!/bin/bash

set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"

# shellcheck source=/dev/null
. "$ROOT_DIR/tests/helpers/setup-harness.sh"

trap cleanup_temp_dir EXIT

set -e

capture_llama_menu_output() {
  local pid="$1"
  local owner="$2"
  local parent_pid="$3"
  local parent_command="$4"
  local existing_mode="$5"
  local listener_state="${6:-hidden}"

  {
    load_setup_functions
    install_prompt_stubs

    TEST_CURRENT_USER='testuser'
    TEST_LISTENING_PID="$pid"
    TEST_PROCESS_OWNER="$owner"
    TEST_PARENT_PID="$parent_pid"
    TEST_PARENT_COMMAND="$parent_command"
    TEST_EXISTING_MODE="$existing_mode"
    TEST_LISTENER_STATE="$listener_state"

    id() {
      if [ "${1:-}" = '-un' ]; then
        printf '%s\n' "$TEST_CURRENT_USER"
        return 0
      fi

      command id "$@"
    }

    whoami() {
      printf '%s\n' "$TEST_CURRENT_USER"
    }

    lsof() {
      if [ "${1:-}" = '-i' ] && [ "${2:-}" = ':11434' ]; then
        if [ -n "$TEST_LISTENING_PID" ]; then
          printf '%s\n' "$TEST_LISTENING_PID"
        fi
        return 0
      fi

      return 1
    }

    netstat() {
      if [ "$TEST_LISTENER_STATE" = 'hidden' ] || [ "$TEST_LISTENER_STATE" = 'visible' ]; then
        printf '%s\n' 'tcp4       0      0  127.0.0.1.11434        *.*                    LISTEN'
      fi

      return 0
    }

    ps() {
      if [ "${1:-}" = '-o' ] && [ "${2:-}" = 'user=' ] && [ "${3:-}" = '-p' ] && [ "${4:-}" = "$TEST_LISTENING_PID" ]; then
        printf '%s\n' "$TEST_PROCESS_OWNER"
        return 0
      fi

      if [ "${1:-}" = '-o' ] && [ "${2:-}" = 'ppid=' ] && [ "${3:-}" = '-p' ] && [ "${4:-}" = "$TEST_LISTENING_PID" ]; then
        printf '%s\n' "$TEST_PARENT_PID"
        return 0
      fi

      if [ "${1:-}" = '-o' ] && [ "${2:-}" = 'command=' ] && [ "${3:-}" = '-p' ] && [ "${4:-}" = "$TEST_PARENT_PID" ]; then
        printf '%s\n' "$TEST_PARENT_COMMAND"
        return 0
      fi

      return 1
    }

    detect_existing_llama_install_mode() {
      if [ -n "$TEST_EXISTING_MODE" ]; then
        REPLY="$TEST_EXISTING_MODE"
        return 0
      fi

      REPLY=''
      return 1
    }

    llama_port_in_use() {
      return 0
    }

    llama_api_responding() {
      return 0
    }

    llama_read_choice() {
      local prompt_label="$1"

      prompt "$prompt_label"
      REPLY='4'
      printf '4\n'
    }

    llama_capture_status handle_prestart_llama_instance_choice '127.0.0.1' '11434'
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
  } 2>&1
}

test_same_user_interactive_instance_is_not_recommended() {
  local output=''

  output="$(capture_llama_menu_output '1234' 'testuser' '900' '/bin/zsh' '')"

  assert_contains 'same-user interactive flow shows current-user owner context' "$output" 'Owner: testuser (current user session)'
  assert_contains 'same-user interactive flow warns that logout stops the instance' "$output" 'This instance will stop if you log out.'
  assert_contains 'same-user interactive flow recommends ClawBox-managed ownership first' "$output" '1) Stop existing instance and use ClawBox-managed instance (recommended)'
  assert_contains 'same-user interactive flow keeps reuse as a non-recommended second option' "$output" '2) Use existing instance'
  assert_not_contains 'same-user interactive flow removes the recommended tag from reuse' "$output" '2) Use existing instance (recommended)'
  assert_contains 'same-user interactive flow exits cleanly' "$output" 'STATUS:42'
}

test_different_user_interactive_instance_is_not_recommended() {
  local output=''

  output="$(capture_llama_menu_output '1234' 'alice' '901' '/bin/zsh' '')"

  assert_contains 'different-user interactive flow shows interactive owner context' "$output" 'Owner: alice (interactive user session)'
  assert_contains 'different-user interactive flow explains the login dependency' "$output" 'This instance depends on the "alice" account remaining logged in.'
  assert_contains 'different-user interactive flow recommends a separate managed instance on another port first' "$output" '1) Start a separate ClawBox-managed instance on another port (recommended)'
  assert_contains 'different-user interactive flow keeps reuse as a non-recommended second option' "$output" '2) Use existing instance'
  assert_not_contains 'different-user interactive flow does not recommend reuse' "$output" '2) Use existing instance (recommended)'
  assert_contains 'different-user interactive flow exits cleanly' "$output" 'STATUS:42'
}

test_launchdaemon_instance_is_recommended() {
  local output=''

  output="$(capture_llama_menu_output '1234' 'root' '1' '/sbin/launchd' '')"

  assert_contains 'launchdaemon flow shows system-wide owner context' "$output" 'Owner: root (system-wide LaunchDaemon)'
  assert_contains 'launchdaemon flow explains system-wide durability' "$output" 'This service is managed system-wide by launchd.'
  assert_contains 'launchdaemon flow recommends managed replacement first' "$output" '1) Stop existing instance and use ClawBox-managed instance (recommended)'
  assert_contains 'launchdaemon flow keeps reuse as second option' "$output" '2) Use existing instance'
  assert_not_contains 'launchdaemon flow does not recommend reuse' "$output" '2) Use existing instance (recommended)'
  assert_contains 'launchdaemon flow exits cleanly' "$output" 'STATUS:42'
}

test_clawbox_managed_instance_is_recommended() {
  local output=''

  output="$(capture_llama_menu_output '1234' 'testuser' '1' '/sbin/launchd' 'user')"

  assert_contains 'ClawBox-managed flow identifies the managed service' "$output" 'Owner: testuser (ClawBox-managed LaunchAgent)'
  assert_contains 'ClawBox-managed flow explains current-user management' "$output" 'This instance is managed by ClawBox for the current user.'
  assert_contains 'ClawBox-managed flow recommends non-disruptive reuse first' "$output" '1) Use the existing running llama-server on port 11434 (recommended)'
  assert_contains 'ClawBox-managed flow keeps restart as second option' "$output" '2) Restart the existing llama-server on port 11434'
  assert_not_contains 'ClawBox-managed flow no longer recommends restart first' "$output" '1) Restart existing ClawBox-managed instance (recommended)'
  assert_contains 'ClawBox-managed flow exits cleanly' "$output" 'STATUS:42'
}

test_unknown_instance_is_not_recommended() {
  local output=''

  output="$(capture_llama_menu_output '' '' '' '' '' 'missing')"

  assert_contains 'unknown flow reports unknown ownership context' "$output" 'Owner: unknown (unknown ownership/runtime classification)'
  assert_contains 'unknown flow warns that durability is unknown' "$output" 'ClawBox could not determine whether this instance is durable.'
  assert_contains 'unknown flow recommends managed ownership first' "$output" '1) Stop existing instance and use ClawBox-managed instance (recommended)'
  assert_contains 'unknown flow keeps reuse as second option' "$output" '2) Use existing instance'
  assert_not_contains 'unknown flow does not recommend reuse' "$output" '2) Use existing instance (recommended)'
  assert_contains 'unknown flow exits cleanly' "$output" 'STATUS:42'
}

test_hidden_owner_listener_is_classified_as_cross_user_session() {
  local output=''

  output="$(capture_llama_menu_output '' '' '' '' '' 'hidden')"

  assert_contains 'cross-user hidden listener flow reports inferred ownership context' "$output" 'Owner: another macOS user session (process ownership not accessible)'
  assert_contains 'cross-user hidden listener flow explains the logout risk' "$output" 'This instance may stop when the owning user logs out.'
  assert_contains 'cross-user hidden listener flow recommends a separate managed instance on another port first' "$output" '1) Start a separate ClawBox-managed instance on another port (recommended)'
  assert_contains 'cross-user hidden listener flow keeps reuse as second option' "$output" '2) Use existing instance'
  assert_not_contains 'cross-user hidden listener flow does not recommend reuse' "$output" '2) Use existing instance (recommended)'
  assert_contains 'cross-user hidden listener flow exits cleanly' "$output" 'STATUS:42'
}

test_healthy_remote_api_is_detected_when_local_port_probe_misses() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    llama_port_in_use() {
      return 1
    }

    llama_api_responding() {
      [ "${1:-}" = '192.168.64.1' ] && [ "${2:-}" = '11434' ]
    }

    llama_describe_existing_instance() {
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: another macOS user session (process ownership not accessible)'
      LLAMA_EXISTING_INSTANCE_RUNTIME='cross-user-session'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance may stop when the owning user logs out.'
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=false
      LLAMA_EXISTING_INSTANCE_CONTROLLABLE=false
      return 0
    }

    llama_show_port_conflict_warning() {
      printf 'PORT_CONFLICT_WARNING\n'
      return 0
    }

    queue_prompt_answers '4'

    llama_read_choice() {
      local prompt_label="$1"

      prompt "$prompt_label"
      take_prompt_answer
      REPLY="$PROMPT_ANSWER"
      printf '%s\n' "$PROMPT_ANSWER"
    }

    llama_capture_status handle_prestart_llama_instance_choice '192.168.64.1' '11434'
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
  } 2>&1)"

  assert_contains 'remote healthy API flow reports the detected endpoint' "$output" 'llama-server detected at http://192.168.64.1:11434'
  assert_contains 'remote healthy API flow reports cross-user ownership' "$output" 'Owner: another macOS user session (process ownership not accessible)'
  assert_contains 'remote healthy API flow recommends a separate managed instance first' "$output" '1) Start a separate ClawBox-managed instance on another port (recommended)'
  assert_not_contains 'remote healthy API flow does not treat a responding API as an empty port' "$output" 'PORT_CONFLICT_WARNING'
  assert_contains 'remote healthy API flow exits cleanly' "$output" 'STATUS:42'
}

test_dedicated_port_marks_runtime_env_drift_for_restart() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs
    LLAMA_BIN='/opt/homebrew/bin/llama-server'
    MODEL_PATH='/tmp/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf'
    LLAMA_HOST='0.0.0.0'
    LLAMA_PORT='11435'
    LLAMA_CTX='32768'
    LLAMA_EXTRA_ARGS='-ngl 99 --jinja -fa on'
    CLAWBOX_LLAMA_USER_ENV_DEST="$TEMP_DIR/dedicated-drift-clawbox.env"

    # Model an installed runtime env from before LLAMA_EXTRA_ARGS was added.
    # The desired rendered env includes the configured extra arguments.
    printf '%s\n' \
      'LLAMA_BIN="/opt/homebrew/bin/llama-server"' \
      'MODEL_PATH="/tmp/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"' \
      'LLAMA_HOST="0.0.0.0"' \
      'LLAMA_PORT="11435"' \
      'LLAMA_CTX="32768"' > "$CLAWBOX_LLAMA_USER_ENV_DEST"

    prompt_with_default() { prompt "$1 [$2]:"; REPLY='11435'; }
    llama_api_responding() { [ "${2:-}" = '11435' ]; }
    llama_describe_existing_instance() {
      LLAMA_EXISTING_INSTANCE_RUNTIME='ClawBox-managed LaunchAgent'
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: testuser (ClawBox-managed LaunchAgent)'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance is managed by ClawBox for the current user.'
      LLAMA_EXISTING_INSTANCE_LAUNCH_LABEL='com.clawbox.llama'
      LLAMA_EXISTING_INSTANCE_BINARY_PATH="$LLAMA_BIN"
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=true
      LLAMA_EXISTING_INSTANCE_CONTROLLABLE=true
    }
    queue_prompt_answers '1'
    llama_read_choice() { prompt "$1"; take_prompt_answer; REPLY="$PROMPT_ANSWER"; printf '%s\n' "$REPLY"; }
    llama_prompt_for_available_port '127.0.0.1' '11434' 'dedicated'
  } 2>&1)"

  assert_contains 'dedicated drift warns about current env mismatch' "$output" 'does not match the current .env runtime settings'
  assert_contains 'dedicated drift makes reuse explicitly non-applying' "$output" 'without applying .env changes'
  assert_contains 'dedicated drift recommends restart update' "$output" 'to apply .env changes (recommended)'
  assert_not_contains 'dedicated drift does not recommend reuse' "$output" '1) Use the existing running llama-server on port 11435 (recommended)'
}

test_cross_user_option_two_uses_alternate_port_without_stop_attempt() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    TEST_CURRENT_USER='testuser'

    id() {
      if [ "${1:-}" = '-un' ]; then
        printf '%s\n' "$TEST_CURRENT_USER"
        return 0
      fi

      command id "$@"
    }

    whoami() {
      printf '%s\n' "$TEST_CURRENT_USER"
    }

    llama_port_in_use() {
      if [ "${1:-}" = '11434' ]; then
        return 0
      fi

      return 1
    }

    llama_api_responding() {
      if [ "${2:-}" = '11434' ]; then
        return 0
      fi

      return 1
    }

    llama_describe_existing_instance() {
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: another macOS user session (process ownership not accessible)'
      LLAMA_EXISTING_INSTANCE_RUNTIME='cross-user-session'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance may stop when the owning user logs out.'
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=false
      LLAMA_EXISTING_INSTANCE_CONTROLLABLE=false
      return 0
    }

    llama_prompt_for_available_port() {
      if [ "${3:-}" = 'dedicated' ]; then
        printf 'ALT_PORT_MODE:dedicated\n'
      fi
      printf 'ALT_PORT_FLOW\n'
      REPLY='11435'
      return 0
    }

    stop_user_owned_llama_instance() {
      printf 'STOP_ATTEMPTED\n'
      return 1
    }

    queue_prompt_answers '1'

    llama_read_choice() {
      local prompt_label="$1"

      prompt "$prompt_label"
      take_prompt_answer
      REPLY="$PROMPT_ANSWER"
      printf '%s\n' "$PROMPT_ANSWER"
    }

    llama_capture_status handle_prestart_llama_instance_choice '127.0.0.1' '11434'
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
    printf 'REPLY:%s\n' "$REPLY"
  } 2>&1)"

  assert_contains 'cross-user alternate-port flow invokes the alternate-port prompt' "$output" 'ALT_PORT_FLOW'
  assert_contains 'cross-user alternate-port flow uses dedicated port-selection mode' "$output" 'ALT_PORT_MODE:dedicated'
  assert_not_contains 'cross-user alternate-port flow does not attempt to stop the existing instance' "$output" 'STOP_ATTEMPTED'
  assert_contains 'cross-user alternate-port flow returns success' "$output" 'STATUS:0'
  assert_contains 'cross-user alternate-port flow returns the new port' "$output" 'REPLY:11435'
}

test_dedicated_port_reuses_existing_current_user_managed_instance() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    LLAMA_BIN='/opt/homebrew/bin/llama-server'
    MODEL_PATH='/tmp/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf'
    LLAMA_HOST='0.0.0.0'
    LLAMA_PORT='11435'
    LLAMA_CTX='32768'
    LLAMA_EXTRA_ARGS=''
    CLAWBOX_LLAMA_USER_ENV_DEST="$TEMP_DIR/dedicated-clean-clawbox.env"
    write_llama_runtime_env "$CLAWBOX_LLAMA_USER_ENV_DEST"

    prompt_calls=0

    prompt_with_default() {
      local label="$1"
      local default_value="$2"

      prompt_calls=$((prompt_calls + 1))
      prompt "$label [$default_value]:"
      REPLY='11435'
      return 0
    }

    llama_api_responding() {
      [ "${2:-}" = '11435' ]
    }

    llama_describe_existing_instance() {
      LLAMA_EXISTING_INSTANCE_RUNTIME='ClawBox-managed LaunchAgent'
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: testuser (ClawBox-managed LaunchAgent)'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance is managed by ClawBox for the current user.'
      LLAMA_EXISTING_INSTANCE_LAUNCH_LABEL='com.clawbox.llama'
      LLAMA_EXISTING_INSTANCE_BINARY_PATH="$LLAMA_BIN"
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=true
      LLAMA_EXISTING_INSTANCE_CONTROLLABLE=true
      return 0
    }

    queue_prompt_answers '1'

    llama_read_choice() {
      local prompt_label="$1"

      prompt "$prompt_label"
      take_prompt_answer
      REPLY="$PROMPT_ANSWER"
      printf '%s\n' "$PROMPT_ANSWER"
    }

    llama_prompt_for_available_port '127.0.0.1' '11434' 'dedicated'
    printf 'STATUS:%s\n' "$?"
    printf 'REPLY:%s\n' "$REPLY"
    printf 'USE_EXISTING:%s\n' "$LLAMA_USE_EXISTING_INSTANCE"
    printf 'EXTERNAL:%s\n' "$LLAMA_EXTERNAL"
    printf 'PROMPT_CALLS:%s\n' "$prompt_calls"
  } 2>&1)"

  assert_contains 'dedicated managed-port flow shows the dedicated reuse option' "$output" '1) Use the existing running llama-server on port 11435 (recommended)'
  assert_contains 'dedicated managed-port flow shows the restart option' "$output" '2) Restart the existing llama-server on port 11435'
  assert_contains 'dedicated managed-port flow shows launch label details' "$output" 'Launch label: com.clawbox.llama'
  assert_contains 'dedicated managed-port flow shows binary details' "$output" 'Binary: /opt/homebrew/bin/llama-server'
  assert_contains 'dedicated managed-port flow returns success' "$output" 'STATUS:0'
  assert_contains 'dedicated managed-port flow returns the managed port' "$output" 'REPLY:11435'
  assert_contains 'dedicated managed-port flow reuses the existing managed instance' "$output" 'USE_EXISTING:true'
  assert_contains 'dedicated managed-port flow keeps the reused managed instance non-external' "$output" 'EXTERNAL:false'
  assert_contains 'dedicated managed-port flow avoids a port retry loop' "$output" 'PROMPT_CALLS:1'
}

test_dedicated_port_can_restart_existing_current_user_managed_instance() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    restart_attempts=0

    prompt_with_default() {
      local label="$1"
      local default_value="$2"

      prompt "$label [$default_value]:"
      REPLY='11435'
      return 0
    }

    llama_api_responding() {
      [ "${2:-}" = '11435' ]
    }

    llama_describe_existing_instance() {
      LLAMA_EXISTING_INSTANCE_RUNTIME='ClawBox-managed LaunchAgent'
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: testuser (ClawBox-managed LaunchAgent)'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance is managed by ClawBox for the current user.'
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=true
      LLAMA_EXISTING_INSTANCE_CONTROLLABLE=true
      return 0
    }

    stop_user_owned_llama_instance() {
      restart_attempts=$((restart_attempts + 1))
      return 0
    }

    queue_prompt_answers '2'

    llama_read_choice() {
      local prompt_label="$1"

      prompt "$prompt_label"
      take_prompt_answer
      REPLY="$PROMPT_ANSWER"
      printf '%s\n' "$PROMPT_ANSWER"
    }

    llama_prompt_for_available_port '127.0.0.1' '11434' 'dedicated'
    printf 'STATUS:%s\n' "$?"
    printf 'REPLY:%s\n' "$REPLY"
    printf 'USE_EXISTING:%s\n' "$LLAMA_USE_EXISTING_INSTANCE"
    printf 'EXTERNAL:%s\n' "$LLAMA_EXTERNAL"
    printf 'RESTART_ATTEMPTS:%s\n' "$restart_attempts"
  } 2>&1)"

  assert_contains 'dedicated managed-port restart flow returns success' "$output" 'STATUS:0'
  assert_contains 'dedicated managed-port restart flow keeps the managed port' "$output" 'REPLY:11435'
  assert_contains 'dedicated managed-port restart flow continues with managed setup' "$output" 'USE_EXISTING:false'
  assert_contains 'dedicated managed-port restart flow keeps the restarted managed instance non-external' "$output" 'EXTERNAL:false'
  assert_contains 'dedicated managed-port restart flow restarts once' "$output" 'RESTART_ATTEMPTS:1'
}

test_dedicated_port_prompt_defaults_to_next_available_port() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    prompt_with_default() {
      local label="$1"
      local default_value="$2"

      printf 'PROMPT:%s [%s]\n' "$label" "$default_value"
      REPLY="$default_value"
      return 0
    }

    llama_port_in_use() {
      [ "${1:-}" = '11434' ]
    }

    llama_api_responding() {
      return 1
    }

    llama_prompt_for_available_port '127.0.0.1' '11434' 'dedicated'
    printf 'STATUS:%s\n' "$?"
    printf 'REPLY:%s\n' "$REPLY"
  } 2>&1)"

  assert_contains 'dedicated alternate-port prompt suggests the next free port' "$output" 'PROMPT:Port for llama-server [11435]'
  assert_contains 'dedicated alternate-port prompt returns the suggested free port' "$output" 'REPLY:11435'
  assert_contains 'dedicated alternate-port prompt succeeds with the suggested free port' "$output" 'STATUS:0'
}

test_dedicated_port_prompt_skips_busy_sequential_ports() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    prompt_with_default() {
      local label="$1"
      local default_value="$2"

      printf 'PROMPT:%s [%s]\n' "$label" "$default_value"
      REPLY="$default_value"
      return 0
    }

    llama_port_in_use() {
      [ "${1:-}" = '11434' ] || [ "${1:-}" = '11435' ]
    }

    llama_api_responding() {
      return 1
    }

    llama_prompt_for_available_port '127.0.0.1' '11434' 'dedicated'
    printf 'STATUS:%s\n' "$?"
    printf 'REPLY:%s\n' "$REPLY"
  } 2>&1)"

  assert_contains 'dedicated alternate-port prompt skips the next busy port' "$output" 'PROMPT:Port for llama-server [11436]'
  assert_contains 'dedicated alternate-port prompt returns the next available sequential port' "$output" 'REPLY:11436'
  assert_contains 'dedicated alternate-port prompt succeeds after skipping busy ports' "$output" 'STATUS:0'
}

test_runtime_health_classification_requires_listener_and_health_endpoint() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    llama_port_has_local_listener() {
      return 1
    }

    llama_api_responding() {
      return 0
    }

    llama_service_loaded() {
      return 0
    }

    ps() {
      if [ "${1:-}" = '-axo' ]; then
        printf '123 /opt/homebrew/bin/llama-server --port 11434\n'
        return 0
      fi

      command ps "$@"
    }

    llama_classify_runtime_health '127.0.0.1' '11434'
    printf 'HEALTH:%s\n' "$LLAMA_INSTANCE_HEALTH"
    printf 'PROCESS:%s\n' "$LLAMA_INSTANCE_HAS_PROCESS"
    printf 'LISTENER:%s\n' "$LLAMA_INSTANCE_HAS_LISTENER"
    printf 'HEALTHCHECK:%s\n' "$LLAMA_INSTANCE_HEALTHCHECK_OK"
    printf 'LAUNCHD:%s\n' "$LLAMA_INSTANCE_LAUNCHD_LOADED"
  } 2>&1)"

  assert_contains 'runtime health classification marks process-only state as unhealthy' "$output" 'HEALTH:unhealthy'
  assert_contains 'runtime health classification records process presence' "$output" 'PROCESS:true'
  assert_contains 'runtime health classification records missing listener' "$output" 'LISTENER:false'
  assert_contains 'runtime health classification records endpoint probe state' "$output" 'HEALTHCHECK:true'
  assert_contains 'runtime health classification records loaded launchd state' "$output" 'LAUNCHD:true'
}

test_runtime_health_classification_marks_healthy_only_with_listener_and_health() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    llama_port_has_local_listener() {
      return 0
    }

    llama_api_responding() {
      return 0
    }

    llama_service_loaded() {
      return 1
    }

    ps() {
      if [ "${1:-}" = '-axo' ]; then
        printf ''
        return 0
      fi

      command ps "$@"
    }

    llama_classify_runtime_health '127.0.0.1' '11435'
    printf 'HEALTH:%s\n' "$LLAMA_INSTANCE_HEALTH"
  } 2>&1)"

  assert_contains 'runtime health classification marks listener-plus-health state as healthy' "$output" 'HEALTH:healthy'
}

test_listening_port_parser_extracts_ports_without_gawk_match_captures() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    netstat() {
      cat <<'EOF'
tcp4       0      0  127.0.0.1.11434        *.*                    LISTEN
tcp4       0      0  *.11435                *.*                    LISTEN
tcp6       0      0  ::1.11435              *.*                    LISTEN
EOF
    }

    llama_listening_port_numbers
    printf '%s\n' "$REPLY"
  } 2>&1)"

  assert_contains 'listening port parser includes first listening port' "$output" '11434'
  assert_contains 'listening port parser includes alternate listening port' "$output" '11435'
}

test_llama_api_health_probe_uses_bounded_timeouts() {
  local output=''

  output="$({
    setup_mock_bin_dir

    write_mock_command curl '#!/bin/bash
printf "%s\n" "$*" > "$CLAWBOX_TEST_CURL_ARGS_FILE"
exit 28'

    CLAWBOX_TEST_CURL_ARGS_FILE="$TEMP_DIR/llama-curl-args.txt"
    export CLAWBOX_TEST_CURL_ARGS_FILE

    load_setup_functions
    install_prompt_stubs

    HOST_IP='127.0.0.1'
    LLAMA_PORT='11434'

    if llama_api_responding '127.0.0.1' '11434'; then
      printf 'STATUS:0\n'
    else
      printf 'STATUS:1\n'
    fi

    printf 'ARGS:%s\n' "$(cat "$CLAWBOX_TEST_CURL_ARGS_FILE")"
  } 2>&1)"

  assert_contains 'llama api health probe forwards a connect timeout guard' "$output" '--connect-timeout 1'
  assert_contains 'llama api health probe forwards an overall max-time guard' "$output" '--max-time 2'
  assert_contains 'llama api health probe still reports failure when curl exits non-zero' "$output" 'STATUS:1'
}

test_prestart_resolver_reports_unhealthy_primary_and_finds_healthy_alternate() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    llama_classify_runtime_health() {
      if [ "$2" = '11434' ]; then
        LLAMA_INSTANCE_HEALTH='unhealthy'
        LLAMA_INSTANCE_HAS_PROCESS=true
        LLAMA_INSTANCE_HAS_LISTENER=false
        LLAMA_INSTANCE_HEALTHCHECK_OK=false
        LLAMA_INSTANCE_LAUNCHD_LOADED=true
      else
        LLAMA_INSTANCE_HEALTH='healthy'
        LLAMA_INSTANCE_HAS_PROCESS=true
        LLAMA_INSTANCE_HAS_LISTENER=true
        LLAMA_INSTANCE_HEALTHCHECK_OK=true
        LLAMA_INSTANCE_LAUNCHD_LOADED=true
      fi

      REPLY="$LLAMA_INSTANCE_HEALTH"
      return 0
    }

    llama_discover_healthy_instance_port() {
      REPLY='11435'
      return 0
    }

    resolve_prestart_llama_port '127.0.0.1' '11434'
    printf 'RESOLVED:%s\n' "$REPLY"
  } 2>&1)"

  assert_contains 'prestart resolver warns when configured port is unhealthy' "$output" 'Detected unhealthy llama-server state at http://127.0.0.1:11434'
  assert_contains 'prestart resolver explains that the configured endpoint is unhealthy' "$output" 'Configured endpoint 11434 is unhealthy.'
  assert_contains 'prestart resolver reports switching to the discovered healthy endpoint' "$output" 'Using discovered healthy endpoint 11435 instead.'
  assert_contains 'prestart resolver returns the healthy alternate port' "$output" 'RESOLVED:11435'
}

test_prestart_flow_prefers_discovered_healthy_port_before_binary_setup() {
  local output=''

  output="$({
    load_setup_functions
    install_prompt_stubs

    local model_path="$TEMP_DIR/model.gguf"
    : > "$model_path"

    HOST_IP='127.0.0.1'
    VM_IP='192.168.64.2'
    VM_USER='tester'
    VM_USER_PATH='/Users/tester'
    VM_HOST='tester@192.168.64.2'
    VM_RUNTIME_PATH='/Users/tester/ClawBox'
    VM_MACHINE_NAME='ClawVM'
    LLAMA_BIN='/missing/llama-server'
    LLAMA_HOST='0.0.0.0'
    LLAMA_PORT='11434'
    LLAMA_CTX='16384'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    MODEL_PATH="$model_path"
    FIREWALL_SHARED_SUBNET='192.168.64.0/24'
    OPENCLAW_PROVIDER_NAME='clawbox'
    OPENCLAW_DEFAULT_MODEL='model'
    OPENCLAW_AUTOSTART='true'

    llama_discover_healthy_instance_port() {
      REPLY='11435'
      return 0
    }

    handle_prestart_llama_instance_choice() {
      printf 'CHOICE_PORT:%s\n' "$2"
      LLAMA_USE_EXISTING_INSTANCE=true
      LLAMA_EXTERNAL=true
      REPLY="$2"
      return 0
    }

    ensure_llama_bin_ready() {
      printf 'ENSURE_BIN_CALLED\n'
      return 0
    }

    require_file() {
      return 0
    }

    require_command() {
      return 0
    }

    require_value() {
      return 0
    }

    source_env_file() {
      return 0
    }

    run_provisioning_and_deployment() {
      return 0
    }

    write_env_from_template() {
      return 0
    }

    main
    printf 'STATUS:%s\n' "$?"
  } 2>&1)"

  assert_contains 'prestart flow routes through the discovered healthy port first' "$output" 'CHOICE_PORT:11435'
  assert_not_contains 'prestart flow skips binary setup when reusing discovered healthy instance' "$output" 'ENSURE_BIN_CALLED'
  assert_contains 'prestart flow main path still succeeds' "$output" 'STATUS:0'
}

run_test test_same_user_interactive_instance_is_not_recommended
run_test test_different_user_interactive_instance_is_not_recommended
run_test test_launchdaemon_instance_is_recommended
run_test test_clawbox_managed_instance_is_recommended
run_test test_unknown_instance_is_not_recommended
run_test test_hidden_owner_listener_is_classified_as_cross_user_session
run_test test_healthy_remote_api_is_detected_when_local_port_probe_misses
run_test test_cross_user_option_two_uses_alternate_port_without_stop_attempt
run_test test_dedicated_port_reuses_existing_current_user_managed_instance
run_test test_dedicated_port_marks_runtime_env_drift_for_restart
run_test test_dedicated_port_can_restart_existing_current_user_managed_instance
run_test test_dedicated_port_prompt_defaults_to_next_available_port
run_test test_dedicated_port_prompt_skips_busy_sequential_ports
run_test test_runtime_health_classification_requires_listener_and_health_endpoint
run_test test_runtime_health_classification_marks_healthy_only_with_listener_and_health
run_test test_listening_port_parser_extracts_ports_without_gawk_match_captures
run_test test_llama_api_health_probe_uses_bounded_timeouts
run_test test_prestart_resolver_reports_unhealthy_primary_and_finds_healthy_alternate
run_test test_prestart_flow_prefers_discovered_healthy_port_before_binary_setup

if [ "$FAILURES" -ne 0 ]; then
  exit 1
fi
