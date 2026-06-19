#!/bin/bash
set -euo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/.." && pwd)/tests/helpers/setup-harness.sh"

trap cleanup_temp_dir EXIT

TEMP_DIR="$(mktemp -d)"

test_error_exit_returns_failure() {
  local output
  local status=0

  output="$({
    load_setup_functions

    if error_exit 'coverage failure'; then
      status=0
    else
      status=$?
    fi

    printf 'STATUS:%s\n' "$status"
  } 2>&1)"

  assert_contains 'error_exit emits the provided failure message' "$output" 'coverage failure'
  assert_contains 'error_exit returns status 1' "$output" 'STATUS:1'
}

test_is_yes_accepts_expected_values() {
  load_setup_functions

  if is_yes 'yes'; then
    pass 'is_yes accepts yes'
  else
    fail 'is_yes should accept yes'
  fi

  if is_yes 'TRUE'; then
    pass 'is_yes accepts TRUE'
  else
    fail 'is_yes should accept TRUE'
  fi

  if is_yes 'no'; then
    fail 'is_yes should reject no'
  else
    pass 'is_yes rejects no'
  fi
}

test_doctor_llama_environment_reports_detected_capabilities() {
  local output

  output="$({
    load_setup_functions
    setup_mock_bin_dir

    write_mock_command git '#!/bin/bash
exit 0
'

    write_mock_command cmake '#!/bin/bash
exit 0
'

    llama_homebrew_state() {
      REPLY='installed-not-in-path'
    }

    resolve_homebrew_bin_path() {
      REPLY='/opt/homebrew/bin/brew'
      return 0
    }

    resolve_homebrew_shellenv_line() {
      REPLY='eval "$(/opt/homebrew/bin/brew shellenv)"'
      return 0
    }

    doctor_llama_environment
  } 2>&1)"

  assert_contains 'doctor mode shows the llama environment section' "$output" ' > LLaMA Environment Check'
  assert_contains 'doctor mode reports Homebrew not in PATH' "$output" 'Homebrew:       Installed (not in PATH)'
  assert_contains 'doctor mode reports git availability' "$output" 'git:            OK'
  assert_contains 'doctor mode reports cmake availability' "$output" 'cmake:          OK'
  assert_contains 'doctor mode prints the PATH remediation block' "$output" 'Fix Homebrew PATH:'
  assert_contains 'doctor mode prints the zprofile remediation line' "$output" 'echo '\''eval "$(/opt/homebrew/bin/brew shellenv)"'\'' >> ~/.zprofile'
}

test_open_full_disk_access_settings_uses_expected_url() {
  local output_file="$TEMP_DIR/open-command.log"

  load_setup_functions
  setup_mock_bin_dir

  write_mock_command open "#!/bin/bash
printf '%s\n' \"\$*\" > '$output_file'
exit 0
"

  if open_full_disk_access_settings; then
    pass 'open_full_disk_access_settings succeeds when open is available'
  else
    fail 'open_full_disk_access_settings should succeed when open is available'
  fi

  assert_equals 'open_full_disk_access_settings uses the Full Disk Access settings URL' "$(cat "$output_file")" 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles'
}

test_derive_runtime_path_appends_clawbox() {
  load_setup_functions

  derive_runtime_path '/Users/tester'
  assert_equals 'derive_runtime_path appends the ClawBox directory' "$REPLY" '/Users/tester/ClawBox'
}

test_value_needs_setup_distinguishes_placeholders_from_real_values() {
  load_setup_functions

  if value_needs_setup 'HOST_IP' ''; then
    pass 'value_needs_setup requires setup for empty values'
  else
    fail 'value_needs_setup should require setup for empty values'
  fi

  if value_needs_setup 'HOST_IP' '<host-ip>'; then
    pass 'value_needs_setup requires setup for placeholder host values'
  else
    fail 'value_needs_setup should require setup for placeholder host values'
  fi

  if value_needs_setup 'VM_HOST' '<vm-user>@<vm-ip>'; then
    pass 'value_needs_setup requires setup for placeholder vm host values'
  else
    fail 'value_needs_setup should require setup for placeholder vm host values'
  fi

  if value_needs_setup 'OPENCLAW_AUTOSTART' '<true-or-false>'; then
    pass 'value_needs_setup requires setup for placeholder autostart values'
  else
    fail 'value_needs_setup should require setup for placeholder autostart values'
  fi

  if value_needs_setup 'HOST_IP' '192.168.64.1'; then
    fail 'value_needs_setup should preserve real host values'
  else
    pass 'value_needs_setup preserves real host values'
  fi

  if value_needs_setup 'VM_HOST' 'tester@192.168.64.2'; then
    fail 'value_needs_setup should preserve real vm host values'
  else
    pass 'value_needs_setup preserves real vm host values'
  fi
}

test_write_env_from_template_creates_env_from_example_and_preserves_selected_values() {
  local output

  output="$({
    load_setup_functions

    BASE_DIR="$TEMP_DIR"
    ENV_EXAMPLE_FILE="$TEMP_DIR/.env.example"
    ENV_FILE="$TEMP_DIR/.env"

    cat > "$ENV_EXAMPLE_FILE" <<'EOF'
  # ClawBox EXAMPLE Configuration
HOST_IP="<host-ip>"
VM_USER="your-vm-username"
LLAMA_PORT="11434"
OPENCLAW_AUTOSTART="<true-or-false>"
EOF

    HOST_IP='192.168.64.1'
    VM_USER='tester'
    LLAMA_PORT='11434'
    OPENCLAW_AUTOSTART='true'
    ENV_BACKUP_DECISION_MADE=true
    ENV_BACKUP_ENABLED=false

    write_env_from_template
    printf 'CREATED:%s\n' "$( [ -f "$ENV_FILE" ] && printf yes || printf no )"
    printf 'CREATED_TITLE:%s\n' "$(head -n 1 "$ENV_FILE")"
    printf 'CREATED_HOST:%s\n' "$(grep '^HOST_IP=' "$ENV_FILE")"

    cat > "$ENV_FILE" <<'EOF'
  # ClawBox Configuration
HOST_IP="10.0.0.8"
VM_USER="preserved-user"
LLAMA_PORT="11555"
OPENCLAW_AUTOSTART="false"
EOF

    HOST_IP=''
    VM_USER=''
    LLAMA_PORT=''
    OPENCLAW_AUTOSTART=''
    source_env_file
    ENV_BACKUP_DECISION_MADE=true
    ENV_BACKUP_ENABLED=false
    write_env_from_template

    printf 'PRESERVED_HOST:%s\n' "$(grep '^HOST_IP=' "$ENV_FILE")"
    printf 'PRESERVED_USER:%s\n' "$(grep '^VM_USER=' "$ENV_FILE")"
    printf 'PRESERVED_PORT:%s\n' "$(grep '^LLAMA_PORT=' "$ENV_FILE")"
    printf 'PRESERVED_AUTOSTART:%s\n' "$(grep '^OPENCLAW_AUTOSTART=' "$ENV_FILE")"
  } 2>&1)"

  assert_contains 'write_env_from_template creates env from the example file' "$output" 'CREATED:yes'
  assert_contains 'write_env_from_template normalizes the example title' "$output" 'CREATED_TITLE:'
  assert_contains 'write_env_from_template rewrites the example banner text' "$output" 'ClawBox Configuration'
  assert_contains 'write_env_from_template writes configured host values into the created env file' "$output" 'CREATED_HOST:HOST_IP="192.168.64.1"'
  assert_contains 'write_env_from_template preserves an existing host value after reload' "$output" 'PRESERVED_HOST:HOST_IP="10.0.0.8"'
  assert_contains 'write_env_from_template preserves an existing vm user after reload' "$output" 'PRESERVED_USER:VM_USER="preserved-user"'
  assert_contains 'write_env_from_template preserves an existing llama port after reload' "$output" 'PRESERVED_PORT:LLAMA_PORT="11555"'
  assert_contains 'write_env_from_template preserves an existing autostart value after reload' "$output" 'PRESERVED_AUTOSTART:OPENCLAW_AUTOSTART="false"'
}

test_write_env_from_template_requires_explicit_backup_opt_in() {
  local output

  output="$({
    load_setup_functions

    BASE_DIR="$TEMP_DIR"
    ENV_EXAMPLE_FILE="$TEMP_DIR/.env.example"
    ENV_FILE="$TEMP_DIR/.env"

    cat > "$ENV_EXAMPLE_FILE" <<'EOF'
  # ClawBox EXAMPLE Configuration
HOST_IP="<host-ip>"
EOF

    cat > "$ENV_FILE" <<'EOF'
  # ClawBox Configuration
HOST_IP="192.168.64.2"
EOF

    HOST_IP='192.168.64.3'
    REPLY='yes'
    ENV_BACKUP_DECISION_MADE=false
    ENV_BACKUP_ENABLED=false

    write_env_from_template

    printf 'BACKUP_DECISION:%s\n' "$ENV_BACKUP_DECISION_MADE"
    printf 'BACKUP_ENABLED:%s\n' "$ENV_BACKUP_ENABLED"
    printf 'BACKUP_EXISTS:%s\n' "$( [ -f "$BASE_DIR/.env.bak" ] && printf yes || printf no )"
  } 2>&1)"

  assert_contains 'write_env_from_template should not infer backup opt-in from stale reply state' "$output" 'BACKUP_ENABLED:false'
  assert_contains 'write_env_from_template should not create a backup without explicit opt-in' "$output" 'BACKUP_EXISTS:no'
}

test_write_env_from_template_creates_backup_when_explicitly_enabled() {
  local output

  output="$({
    load_setup_functions

    BASE_DIR="$TEMP_DIR"
    ENV_EXAMPLE_FILE="$TEMP_DIR/.env.example"
    ENV_FILE="$TEMP_DIR/.env"

    cat > "$ENV_EXAMPLE_FILE" <<'EOF'
  # ClawBox EXAMPLE Configuration
HOST_IP="<host-ip>"
EOF

    cat > "$ENV_FILE" <<'EOF'
  # ClawBox Configuration
HOST_IP="192.168.64.2"
EOF

    HOST_IP='192.168.64.3'
    ENV_BACKUP_DECISION_MADE=true
    ENV_BACKUP_ENABLED=true

    write_env_from_template

    printf 'BACKUP_EXISTS:%s\n' "$( [ -f "$BASE_DIR/.env.bak" ] && printf yes || printf no )"
    printf 'BACKUP_HOST:%s\n' "$(grep '^HOST_IP=' "$BASE_DIR/.env.bak")"
    printf 'UPDATED_HOST:%s\n' "$(grep '^HOST_IP=' "$ENV_FILE")"
  } 2>&1)"

  assert_contains 'write_env_from_template creates a backup when explicit opt-in is enabled' "$output" 'BACKUP_EXISTS:yes'
  assert_contains 'write_env_from_template preserves the previous env contents in the backup file' "$output" 'BACKUP_HOST:HOST_IP="192.168.64.2"'
  assert_contains 'write_env_from_template still updates the current env file after creating the backup' "$output" 'UPDATED_HOST:HOST_IP="192.168.64.3"'
}

test_normalize_openclaw_autostart_maps_inputs() {
  load_setup_functions

  if normalize_openclaw_autostart 'yes'; then
    pass 'normalize_openclaw_autostart accepts yes'
  else
    fail 'normalize_openclaw_autostart should accept yes'
  fi
  assert_equals 'normalize_openclaw_autostart maps yes to true' "$REPLY" 'true'

  if normalize_openclaw_autostart 'No'; then
    pass 'normalize_openclaw_autostart accepts no'
  else
    fail 'normalize_openclaw_autostart should accept no'
  fi
  assert_equals 'normalize_openclaw_autostart maps no to false' "$REPLY" 'false'

  if normalize_openclaw_autostart 'later'; then
    fail 'normalize_openclaw_autostart should reject invalid values'
  else
    pass 'normalize_openclaw_autostart rejects invalid values'
  fi
}

test_source_env_file_rejects_invalid_env_syntax() {
  local output

  output="$({
    load_setup_functions

    ENV_FILE="$TEMP_DIR/.env-invalid"
    cat > "$ENV_FILE" <<'EOF'
HOST_IP="192.168.64.1"
if then
EOF

    if source_env_file; then
      printf 'STATUS:0\n'
    else
      printf 'STATUS:%s\n' "$?"
    fi
  } 2>&1)"

  assert_contains 'source_env_file reports invalid env syntax' "$output" 'Invalid .env syntax:'
  assert_contains 'source_env_file returns failure for invalid env syntax' "$output" 'STATUS:1'
}

test_prompt_openclaw_autostart_respects_existing_default_and_reprompts_on_invalid_input() {
  local output

  output="$({
    load_setup_functions

    prompt_with_suffix() {
      prompt "$1 $2:"
      take_prompt_answer
      prompt_complete
      REPLY="$PROMPT_ANSWER"
      return 0
    }

    ENV_CREATED_FROM_EXAMPLE=false
    queue_prompt_answers ''
    prompt_openclaw_autostart 'false'
    printf 'PRESERVED_DEFAULT:%s\n' "$REPLY"

    ENV_CREATED_FROM_EXAMPLE=true
    queue_prompt_answers ''
    prompt_openclaw_autostart 'false'
    printf 'EXAMPLE_DEFAULT:%s\n' "$REPLY"

    ENV_CREATED_FROM_EXAMPLE=false
    queue_prompt_answers 'later' 'n'
    prompt_openclaw_autostart 'true'
    printf 'RECOVERED_VALUE:%s\n' "$REPLY"
  } 2>&1)"

  assert_contains 'prompt_openclaw_autostart preserves the existing false default on reruns' "$output" 'PRESERVED_DEFAULT:false'
  assert_contains 'prompt_openclaw_autostart resets to true when bootstrapping from the example file' "$output" 'EXAMPLE_DEFAULT:true'
  assert_contains 'prompt_openclaw_autostart rejects invalid input before reprompting' "$output" 'Invalid input. Enter y, yes, n, or no.'
  assert_contains 'prompt_openclaw_autostart accepts the corrected no response after reprompting' "$output" 'RECOVERED_VALUE:false'
}

test_host_ip_and_firewall_subnet_derivation_use_vm_ip_defaults() {
  load_setup_functions

  parse_host_ip_from_base_url ''
  assert_equals 'parse_host_ip_from_base_url leaves host empty when the base url is unset' "$REPLY" ''

  derive_host_ip_from_vm_ip '192.168.64.2'
  assert_equals 'derive_host_ip_from_vm_ip maps the vm ip to the shared host gateway' "$REPLY" '192.168.64.1'

  configured_or_default 'HOST_IP' '' "$REPLY"
  assert_equals 'configured_or_default falls back to the derived host ip when host ip is unset' "$REPLY" '192.168.64.1'

  derive_shared_subnet_from_vm_ip '192.168.64.2'
  assert_equals 'derive_shared_subnet_from_vm_ip maps the vm ip to the shared subnet' "$REPLY" '192.168.64.0/24'
}

test_resolve_configured_llama_bin_uses_real_wrapper_logic() {
  local output

  output="$({
    load_setup_functions

    llama_capture_status() {
      REPLY='/tmp/llama-server'
      LLAMA_LAST_STATUS=0
      return 0
    }

    if resolve_configured_llama_bin '/candidate'; then
      printf 'SUCCESS_STATUS:0\n'
    else
      printf 'SUCCESS_STATUS:%s\n' "$?"
    fi
    printf 'SUCCESS_REPLY:%s\n' "$REPLY"

    llama_capture_status() {
      REPLY=''
      LLAMA_LAST_STATUS="$LLAMA_EXIT_GRACEFUL"
      return 0
    }

    if resolve_configured_llama_bin '/candidate'; then
      printf 'GRACEFUL_STATUS:0\n'
    else
      printf 'GRACEFUL_STATUS:%s\n' "$?"
    fi

    llama_capture_status() {
      REPLY=''
      LLAMA_LAST_STATUS=1
      return 0
    }

    if resolve_configured_llama_bin '/candidate'; then
      printf 'FAIL_STATUS:0\n'
    else
      printf 'FAIL_STATUS:%s\n' "$?"
    fi
  } 2>&1)"

  assert_contains 'resolve_configured_llama_bin returns success when llama capture succeeds' "$output" 'SUCCESS_STATUS:0'
  assert_contains 'resolve_configured_llama_bin forwards the resolved binary path' "$output" 'SUCCESS_REPLY:/tmp/llama-server'
  assert_contains 'resolve_configured_llama_bin returns the graceful exit code unchanged' "$output" 'GRACEFUL_STATUS:42'
  assert_contains 'resolve_configured_llama_bin returns non-zero failures unchanged' "$output" 'FAIL_STATUS:1'
}

test_select_requested_llama_install_mode_uses_real_wrapper_logic() {
  local output

  output="$({
    load_setup_functions

    llama_capture_status() {
      REPLY='user'
      LLAMA_LAST_STATUS=0
      return 0
    }

    if select_requested_llama_install_mode; then
      printf 'SUCCESS_STATUS:0\n'
    else
      printf 'SUCCESS_STATUS:%s\n' "$?"
    fi
    printf 'SUCCESS_REPLY:%s\n' "$REPLY"

    llama_capture_status() {
      REPLY=''
      LLAMA_LAST_STATUS="$LLAMA_EXIT_GRACEFUL"
      return 0
    }

    if select_requested_llama_install_mode; then
      printf 'GRACEFUL_STATUS:0\n'
    else
      printf 'GRACEFUL_STATUS:%s\n' "$?"
    fi

    llama_capture_status() {
      REPLY=''
      LLAMA_LAST_STATUS=1
      return 0
    }

    if select_requested_llama_install_mode; then
      printf 'FAIL_STATUS:0\n'
    else
      printf 'FAIL_STATUS:%s\n' "$?"
    fi
  } 2>&1)"

  assert_contains 'select_requested_llama_install_mode returns success when llama capture succeeds' "$output" 'SUCCESS_STATUS:0'
  assert_contains 'select_requested_llama_install_mode preserves the chosen install mode reply' "$output" 'SUCCESS_REPLY:user'
  assert_contains 'select_requested_llama_install_mode returns the graceful exit code unchanged' "$output" 'GRACEFUL_STATUS:42'
  assert_contains 'select_requested_llama_install_mode returns non-zero failures unchanged' "$output" 'FAIL_STATUS:1'
}

test_setup_preserves_existing_openclaw_provider_name() {
  local output
  local expected_provider='custom-provider'

  output="$({
    load_setup_functions
    install_prompt_stubs

    local env_example="$TEMP_DIR/.env.example"
    local env_file="$TEMP_DIR/.env"
    local temp_file="$TEMP_DIR/env.tmp"
    local models_dir="$TEMP_DIR/models"
    local fake_bin="$TEMP_DIR/llama-server"

    mkdir -p "$models_dir"
    : > "$models_dir/alpha.gguf"
    : > "$fake_bin"
    chmod +x "$fake_bin"

    cp "$ROOT_DIR/.env.example" "$env_example"
    cp "$env_example" "$env_file"

    queue_prompt_answers \
      "$models_dir" \
      '' \
      '' \
      '' \
      '' \
      '' \
      ''

    ENV_EXAMPLE_FILE="$env_example"
    ENV_FILE="$env_file"
    BASE_DIR="$TEMP_DIR"
    ENV_BACKUP_DECISION_MADE=true
    ENV_BACKUP_ENABLED=false
    ENV_CREATED_FROM_EXAMPLE=false
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=false

    awk '
      /^HOST_IP=/ { print "HOST_IP=\"127.0.0.1\""; next }
      /^VM_IP=/ { print "VM_IP=\"192.168.64.2\""; next }
      /^VM_USER=/ { print "VM_USER=\"tester\""; next }
      /^VM_USER_PATH=/ { print "VM_USER_PATH=\"/Users/tester\""; next }
      /^VM_HOST=/ { print "VM_HOST=\"tester@192.168.64.2\""; next }
      /^VM_RUNTIME_PATH=/ { print "VM_RUNTIME_PATH=\"/Users/tester/ClawBox\""; next }
      /^VM_MACHINE_NAME=/ { print "VM_MACHINE_NAME=\"ClawVM\""; next }
      /^LLAMA_BIN=/ { print "LLAMA_BIN=\"\""; next }
      /^LLAMA_HOST=/ { print "LLAMA_HOST=\"0.0.0.0\""; next }
      /^LLAMA_PORT=/ { print "LLAMA_PORT=\"11434\""; next }
      /^LLAMA_CTX=/ { print "LLAMA_CTX=\"16384\""; next }
      /^LLAMA_BASE_URL=/ { print "LLAMA_BASE_URL=\"http://127.0.0.1:11434/v1\""; next }
      /^MODEL_PATH=/ { print "MODEL_PATH=\"'"$models_dir"'/alpha.gguf\""; next }
      /^FIREWALL_SHARED_SUBNET=/ { print "FIREWALL_SHARED_SUBNET=\"192.168.64.0/24\""; next }
      /^OPENCLAW_PROVIDER_NAME=/ { print "OPENCLAW_PROVIDER_NAME=\"'"$expected_provider"'\""; next }
      /^OPENCLAW_DEFAULT_MODEL=/ { print "OPENCLAW_DEFAULT_MODEL=\"alpha\""; next }
      /^OPENCLAW_AUTOSTART=/ { print "OPENCLAW_AUTOSTART=\"false\""; next }
      { print }
    ' "$env_file" > "$temp_file"
    mv "$temp_file" "$env_file"

    ensure_vm_connection_setup() {
      return 0
    }

    ensure_vm_connectivity_or_repair() {
      return 0
    }

    run_prestart_llama_instance_flow() {
      REPLY='11434'
      LLAMA_USE_EXISTING_INSTANCE=false
      LLAMA_EXTERNAL=false
      return 0
    }

    resolve_configured_llama_bin() {
      REPLY="$fake_bin"
      return 0
    }

    ensure_env_bootstrap < <(printf '')
    printf 'OPENCLAW_PROVIDER_NAME=%s\n' "$OPENCLAW_PROVIDER_NAME"
    printf 'ENV_FILE_PROVIDER=%s\n' "$(grep '^OPENCLAW_PROVIDER_NAME=' "$ENV_FILE")"
  } 2>&1)"

  assert_contains 'setup preserves the existing openclaw provider name in memory' "$output" "OPENCLAW_PROVIDER_NAME=$expected_provider"
  assert_contains 'setup preserves the existing openclaw provider name in the env file' "$output" "ENV_FILE_PROVIDER=OPENCLAW_PROVIDER_NAME=\"$expected_provider\""
}

printf 'Running setup coverage tests\n'

run_test test_error_exit_returns_failure
run_test test_is_yes_accepts_expected_values
run_test test_doctor_llama_environment_reports_detected_capabilities
run_test test_open_full_disk_access_settings_uses_expected_url
run_test test_derive_runtime_path_appends_clawbox
run_test test_value_needs_setup_distinguishes_placeholders_from_real_values
run_test test_write_env_from_template_creates_env_from_example_and_preserves_selected_values
run_test test_write_env_from_template_requires_explicit_backup_opt_in
run_test test_write_env_from_template_creates_backup_when_explicitly_enabled
run_test test_normalize_openclaw_autostart_maps_inputs
run_test test_source_env_file_rejects_invalid_env_syntax
run_test test_prompt_openclaw_autostart_respects_existing_default_and_reprompts_on_invalid_input
run_test test_host_ip_and_firewall_subnet_derivation_use_vm_ip_defaults
run_test test_resolve_configured_llama_bin_uses_real_wrapper_logic
run_test test_select_requested_llama_install_mode_uses_real_wrapper_logic
run_test test_setup_preserves_existing_openclaw_provider_name

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
