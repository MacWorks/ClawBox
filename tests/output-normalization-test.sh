#!/bin/bash
set -euo pipefail

if [[ $- == *x* ]]; then
  exec 9>&2
  export BASH_XTRACEFD=9
fi

# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/.." && pwd)/tests/helpers/setup-harness.sh"

trap cleanup_temp_dir EXIT

test_model_selection_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    local models_dir="$TEMP_DIR/models"
    local fake_bin="$TEMP_DIR/llama-server"
    mkdir -p "$models_dir"
    touch "$models_dir/alpha.gguf" "$models_dir/beta.gguf"
    chmod +x "$fake_bin" 2>/dev/null || true
    : > "$fake_bin"
    chmod +x "$fake_bin"

    queue_prompt_answers \
      "$models_dir" \
      '2' \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      ''

    ENV_FILE="$TEMP_DIR/.env"
    ENV_CREATED_FROM_EXAMPLE=true
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=false
    HOST_IP=''
    VM_IP=''
    VM_USER=''
    VM_USER_PATH=''
    VM_HOST=''
    VM_RUNTIME_PATH=''
    VM_MACHINE_NAME=''
    LLAMA_BIN=''
    LLAMA_HOST=''
    LLAMA_PORT=''
    LLAMA_CTX=''
    LLAMA_BASE_URL=''
    MODEL_PATH=''
    FIREWALL_SHARED_SUBNET=''
    OPENCLAW_PROVIDER_NAME=''
    OPENCLAW_DEFAULT_MODEL=''
    OPENCLAW_AUTOSTART=''

    source_env_file() { :; }
    write_env_from_template() { :; }
    ensure_vm_connection_setup() {
      VM_IP='192.168.64.2'
      VM_USER='tester'
      VM_USER_PATH='/Users/tester'
      VM_HOST='tester@192.168.64.2'
      VM_RUNTIME_PATH='/Users/tester/ClawBox'
      VM_MACHINE_NAME='ClawVM'
      return 0
    }
    ensure_vm_connectivity_or_repair() {
      return 0
    }
    resolve_configured_llama_bin() {
      REPLY="$fake_bin"
      return 0
    }
    llama_api_responding() {
      return 1
    }
    llama_port_in_use() {
      return 1
    }
    llama_show_port_conflict_warning() {
      return 0
    }

    ensure_env_bootstrap < <(printf '')
  } 2>&1)"

  assert_contains 'model flow shows model section' "$output" ' > Model Configuration'
  assert_contains 'model flow shows llama section' "$output" ' > LLaMA Server Configuration'
  assert_contains 'model flow shows openclaw section' "$output" ' > OpenClaw Configuration'
  assert_contains 'model flow lists available models' "$output" 'Available Models:'
  assert_contains 'model flow shows summary section' "$output" ' > Configuration Summary'
  assert_no_excessive_blank_lines 'model flow avoids excessive blank lines' "$output"
}

test_model_selection_recovery_accepts_corrected_directory_after_empty_scan() {
  local output
  local expected_model_path="$TEMP_DIR/valid-models/model-alpha.gguf"

  output="$({
    load_setup_functions
    install_prompt_stubs

    local empty_models_dir="$TEMP_DIR/empty-models"
    local valid_model_dir="$TEMP_DIR/valid-models"
    local valid_model_path="$valid_model_dir/model-alpha.gguf"
    local fake_bin="$TEMP_DIR/llama-server"

    mkdir -p "$empty_models_dir" "$valid_model_dir"
    : > "$valid_model_path"
    : > "$fake_bin"
    chmod +x "$fake_bin"

    queue_prompt_answers \
      "$empty_models_dir" \
      '1' \
      "$valid_model_dir" \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      ''

    ENV_FILE="$TEMP_DIR/.env"
    ENV_CREATED_FROM_EXAMPLE=true
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=false
    HOST_IP=''
    VM_IP=''
    VM_USER=''
    VM_USER_PATH=''
    VM_HOST=''
    VM_RUNTIME_PATH=''
    VM_MACHINE_NAME=''
    LLAMA_BIN=''
    LLAMA_HOST=''
    LLAMA_PORT=''
    LLAMA_CTX=''
    LLAMA_BASE_URL=''
    MODEL_PATH=''
    FIREWALL_SHARED_SUBNET=''
    OPENCLAW_PROVIDER_NAME=''
    OPENCLAW_DEFAULT_MODEL=''
    OPENCLAW_AUTOSTART=''

    source_env_file() { :; }
    write_env_from_template() { :; }
    ensure_vm_connection_setup() {
      VM_IP='192.168.64.2'
      VM_USER='tester'
      VM_USER_PATH='/Users/tester'
      VM_HOST='tester@192.168.64.2'
      VM_RUNTIME_PATH='/Users/tester/ClawBox'
      VM_MACHINE_NAME='ClawVM'
      return 0
    }
    ensure_vm_connectivity_or_repair() {
      return 0
    }
    resolve_configured_llama_bin() {
      REPLY="$fake_bin"
      return 0
    }
    llama_api_responding() {
      return 1
    }
    llama_port_in_use() {
      return 1
    }
    llama_show_port_conflict_warning() {
      return 0
    }

    ensure_env_bootstrap < <(printf '') || true
    printf 'MODEL_PATH=%s\n' "$MODEL_PATH"
  } 2>&1)"

  assert_contains 'empty model directory recovery shows the options menu' "$output" '1) Enter a different models directory'
  assert_contains 'empty model directory recovery offers explicit manual mode' "$output" '2) Enter a full model file path manually'
  assert_contains 'empty model directory recovery offers re-scan mode' "$output" '3) Re-scan current directory'
  assert_contains 'empty model directory recovery offers abort mode' "$output" '4) Abort setup'
  assert_contains 'empty model directory recovery accepts a corrected models directory' "$output" "MODEL_PATH=$expected_model_path"
}

test_model_selection_requires_explicit_file_path_when_directory_is_empty() {
  local output
  local valid_model_path="$TEMP_DIR/valid-models/model-alpha.gguf"

  output="$({
    load_setup_functions
    install_prompt_stubs

    local empty_models_dir="$TEMP_DIR/empty-models"
    local valid_model_dir="$TEMP_DIR/valid-models"
    local valid_model_path="$valid_model_dir/model-alpha.gguf"
    local fake_bin="$TEMP_DIR/llama-server"

    mkdir -p "$empty_models_dir" "$valid_model_dir"
    : > "$valid_model_path"
    : > "$fake_bin"
    chmod +x "$fake_bin"

    queue_prompt_answers \
      "$empty_models_dir" \
      '2' \
      "$empty_models_dir" \
      "$valid_model_path" \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      ''

    ENV_FILE="$TEMP_DIR/.env"
    ENV_CREATED_FROM_EXAMPLE=true
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=false
    HOST_IP=''
    VM_IP=''
    VM_USER=''
    VM_USER_PATH=''
    VM_HOST=''
    VM_RUNTIME_PATH=''
    VM_MACHINE_NAME=''
    LLAMA_BIN=''
    LLAMA_HOST=''
    LLAMA_PORT=''
    LLAMA_CTX=''
    LLAMA_BASE_URL=''
    MODEL_PATH=''
    FIREWALL_SHARED_SUBNET=''
    OPENCLAW_PROVIDER_NAME=''
    OPENCLAW_DEFAULT_MODEL=''
    OPENCLAW_AUTOSTART=''

    source_env_file() { :; }
    write_env_from_template() { :; }
    ensure_vm_connection_setup() {
      VM_IP='192.168.64.2'
      VM_USER='tester'
      VM_USER_PATH='/Users/tester'
      VM_HOST='tester@192.168.64.2'
      VM_RUNTIME_PATH='/Users/tester/ClawBox'
      VM_MACHINE_NAME='ClawVM'
      return 0
    }
    ensure_vm_connectivity_or_repair() {
      return 0
    }
    resolve_configured_llama_bin() {
      REPLY="$fake_bin"
      return 0
    }
    llama_api_responding() {
      return 1
    }
    llama_port_in_use() {
      return 1
    }
    llama_show_port_conflict_warning() {
      return 0
    }

    ensure_env_bootstrap < <(printf '') || true
    printf 'MODEL_PATH=%s\n' "$MODEL_PATH"
    printf 'OPENCLAW_DEFAULT_MODEL=%s\n' "$OPENCLAW_DEFAULT_MODEL"
  } 2>&1)"

  assert_contains 'empty model directory is reported' "$output" 'No supported .gguf model files were found in'
  assert_contains 'empty directory does not become a model path' "$output" 'Model path must be an existing .gguf file.'
  assert_contains 'manual file path is accepted as the model path' "$output" "MODEL_PATH=$valid_model_path"
  assert_contains 'manual file path keeps the stable OpenClaw model alias' "$output" 'OPENCLAW_DEFAULT_MODEL=local'
}

test_model_selection_recovery_rescans_current_directory() {
  local output
  local expected_model_path="$TEMP_DIR/rescan-models/rescanned.gguf"
  local scan_count_file="$TEMP_DIR/rescan-model-scan-count.txt"

  output="$({
    load_setup_functions
    install_prompt_stubs

    local rescan_models_dir="$TEMP_DIR/rescan-models"
    local fake_bin="$TEMP_DIR/llama-server"

    mkdir -p "$rescan_models_dir"
    : > "$fake_bin"
    chmod +x "$fake_bin"
    printf '0\n' > "$scan_count_file"

    list_models_in_directory() {
      local current_count=0

      current_count="$(cat "$scan_count_file")"
      current_count=$((current_count + 1))
      printf '%s\n' "$current_count" > "$scan_count_file"

      if [ "$current_count" -eq 1 ]; then
        return 0
      fi

      printf '%s\n' 'rescanned.gguf'
      return 0
    }

    queue_prompt_answers \
      "$rescan_models_dir" \
      '3' \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      ''

    ENV_FILE="$TEMP_DIR/.env"
    ENV_CREATED_FROM_EXAMPLE=true
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=false
    HOST_IP=''
    VM_IP=''
    VM_USER=''
    VM_USER_PATH=''
    VM_HOST=''
    VM_RUNTIME_PATH=''
    VM_MACHINE_NAME=''
    LLAMA_BIN=''
    LLAMA_HOST=''
    LLAMA_PORT=''
    LLAMA_CTX=''
    LLAMA_BASE_URL=''
    MODEL_PATH=''
    FIREWALL_SHARED_SUBNET=''
    OPENCLAW_PROVIDER_NAME=''
    OPENCLAW_DEFAULT_MODEL=''
    OPENCLAW_AUTOSTART=''

    source_env_file() { :; }
    write_env_from_template() { :; }
    ensure_vm_connection_setup() {
      VM_IP='192.168.64.2'
      VM_USER='tester'
      VM_USER_PATH='/Users/tester'
      VM_HOST='tester@192.168.64.2'
      VM_RUNTIME_PATH='/Users/tester/ClawBox'
      VM_MACHINE_NAME='ClawVM'
      return 0
    }
    ensure_vm_connectivity_or_repair() {
      return 0
    }
    resolve_configured_llama_bin() {
      REPLY="$fake_bin"
      return 0
    }
    llama_api_responding() {
      return 1
    }
    llama_port_in_use() {
      return 1
    }
    llama_show_port_conflict_warning() {
      return 0
    }

    ensure_env_bootstrap < <(printf '') || true
    printf 'MODEL_PATH=%s\n' "$MODEL_PATH"
    printf 'SCAN_CALLS=%s\n' "$(cat "$scan_count_file")"
  } 2>&1)"

  assert_contains 'model recovery re-scan mode is available' "$output" '3) Re-scan current directory'
  assert_contains 'model recovery re-scan mode keeps setup in directory flow' "$output" "MODEL_PATH=$expected_model_path"
  assert_contains 'model recovery re-scan mode re-runs model enumeration on the same directory' "$output" 'SCAN_CALLS=2'
}

test_ensure_env_bootstrap_auto_selects_single_model_without_selection_prompt() {
  local output
  local expected_model_path="$TEMP_DIR/single-models/lone.gguf"

  output="$({
    load_setup_functions
    install_prompt_stubs

    local models_dir="$TEMP_DIR/single-models"
    local fake_bin="$TEMP_DIR/llama-server"

    mkdir -p "$models_dir"
    : > "$models_dir/lone.gguf"
    : > "$fake_bin"
    chmod +x "$fake_bin"

    queue_prompt_answers \
      "$models_dir" \
      '' \
      '' \
      '' \
      '' \
      '' \
      '' \
      ''

    ENV_FILE="$TEMP_DIR/.env"
    ENV_CREATED_FROM_EXAMPLE=true
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=false
    HOST_IP=''
    VM_IP=''
    VM_USER=''
    VM_USER_PATH=''
    VM_HOST=''
    VM_RUNTIME_PATH=''
    VM_MACHINE_NAME=''
    LLAMA_BIN=''
    LLAMA_HOST=''
    LLAMA_PORT=''
    LLAMA_CTX=''
    LLAMA_BASE_URL=''
    MODEL_PATH=''
    FIREWALL_SHARED_SUBNET=''
    OPENCLAW_PROVIDER_NAME=''
    OPENCLAW_DEFAULT_MODEL=''
    OPENCLAW_AUTOSTART=''

    source_env_file() { :; }
    write_env_from_template() { :; }
    ensure_vm_connection_setup() {
      VM_IP='192.168.64.2'
      VM_USER='tester'
      VM_USER_PATH='/Users/tester'
      VM_HOST='tester@192.168.64.2'
      VM_RUNTIME_PATH='/Users/tester/ClawBox'
      VM_MACHINE_NAME='ClawVM'
      return 0
    }
    ensure_vm_connectivity_or_repair() {
      return 0
    }
    resolve_configured_llama_bin() {
      REPLY="$fake_bin"
      return 0
    }
    llama_api_responding() {
      return 1
    }
    llama_port_in_use() {
      return 1
    }
    llama_show_port_conflict_warning() {
      return 0
    }

    ensure_env_bootstrap < <(printf '') || true
    printf 'MODEL_PATH=%s\n' "$MODEL_PATH"
  } 2>&1)"

  assert_contains 'single model flow auto-selects the only discovered model' "$output" 'Using model: lone.gguf'
  assert_not_contains 'single model flow skips the multi-model menu' "$output" 'Available Models:'
  assert_not_contains 'single model flow skips the explicit model selection prompt' "$output" 'Choose AI model'
  assert_contains 'single model flow stores the single discovered model path' "$output" "MODEL_PATH=$expected_model_path"
}

test_first_run_bootstrap_detects_cross_user_llama_before_binary_setup() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    local models_dir="$TEMP_DIR/cross-user-models"
    mkdir -p "$models_dir"
    : > "$models_dir/lone.gguf"

    queue_prompt_answers \
      "$models_dir" \
      '' \
      '' \
      '2' \
      ''

    ENV_FILE="$TEMP_DIR/.env"
    ENV_CREATED_FROM_EXAMPLE=true
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=false
    HOST_IP=''
    VM_IP=''
    VM_USER=''
    VM_USER_PATH=''
    VM_HOST=''
    VM_RUNTIME_PATH=''
    VM_MACHINE_NAME=''
    LLAMA_BIN=''
    LLAMA_HOST=''
    LLAMA_PORT=''
    LLAMA_CTX=''
    LLAMA_BASE_URL=''
    MODEL_PATH=''
    FIREWALL_SHARED_SUBNET=''
    OPENCLAW_PROVIDER_NAME=''
    OPENCLAW_DEFAULT_MODEL=''
    OPENCLAW_AUTOSTART=''

    source_env_file() { :; }
    write_env_from_template() { :; }
    ensure_vm_connection_setup() {
      VM_IP='192.168.64.2'
      VM_USER='tester'
      VM_USER_PATH='/Users/tester'
      VM_HOST='tester@192.168.64.2'
      VM_RUNTIME_PATH='/Users/tester/ClawBox'
      VM_MACHINE_NAME='ClawVM'
      return 0
    }
    ensure_vm_connectivity_or_repair() {
      return 0
    }
    llama_classify_runtime_health() {
      LLAMA_INSTANCE_HEALTH='healthy'
      LLAMA_INSTANCE_HAS_PROCESS=true
      LLAMA_INSTANCE_HAS_LISTENER=false
      LLAMA_INSTANCE_HEALTHCHECK_OK=true
      LLAMA_INSTANCE_LAUNCHD_LOADED=false
      return 0
    }
    llama_discover_healthy_instance_port() {
      REPLY='11434'
      return 0
    }
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
    llama_read_choice() {
      local prompt_label="$1"

      prompt "$prompt_label"
      take_prompt_answer
      REPLY="$PROMPT_ANSWER"
      printf '%s\n' "$PROMPT_ANSWER"
    }
    resolve_configured_llama_bin() {
      printf 'BINARY_RESOLUTION_CALLED\n'
      return 1
    }

    ensure_env_bootstrap < <(printf '')
    printf 'STATUS:%s\n' "$?"
    printf 'USE_EXISTING:%s\n' "$LLAMA_USE_EXISTING_INSTANCE"
    printf 'LLAMA_BASE_URL:%s\n' "$LLAMA_BASE_URL"
  } 2>&1)"

  assert_contains 'first-run bootstrap reports the healthy cross-user endpoint' "$output" 'llama-server detected at http://192.168.64.1:11434'
  assert_contains 'first-run bootstrap reports cross-user ownership before binary setup' "$output" 'Owner: another macOS user session (process ownership not accessible)'
  assert_contains 'first-run bootstrap offers the separate managed instance recommendation' "$output" '1) Start a separate ClawBox-managed instance on another port (recommended)'
  assert_contains 'first-run bootstrap lets the user reuse the existing service' "$output" '2) Use existing instance'
  assert_contains 'first-run bootstrap records existing-instance reuse' "$output" 'USE_EXISTING:true'
  assert_contains 'first-run bootstrap keeps the configured host and port as the base URL' "$output" 'LLAMA_BASE_URL:http://192.168.64.1:11434/v1'
  assert_not_contains 'first-run bootstrap does not enter binary resolution after reuse decision' "$output" 'BINARY_RESOLUTION_CALLED'
  assert_not_contains 'first-run bootstrap does not show binary install options after reuse decision' "$output" 'llama-server binary not found.'
}

test_ensure_env_bootstrap_fast_path_rewrites_env_after_prestart_port_change() {
  local output

  output="$({
    load_setup_functions

    local env_example="$TEMP_DIR/.env.example"
    local env_file="$TEMP_DIR/.env"
    local temp_file="$TEMP_DIR/env.tmp"

    cp "$ROOT_DIR/.env.example" "$env_example"
    cp "$env_example" "$env_file"

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
      /^LLAMA_BIN=/ { print "LLAMA_BIN=\"/Users/tester/bin/llama-server\""; next }
      /^LLAMA_HOST=/ { print "LLAMA_HOST=\"0.0.0.0\""; next }
      /^LLAMA_PORT=/ { print "LLAMA_PORT=\"11434\""; next }
      /^LLAMA_CTX=/ { print "LLAMA_CTX=\"16384\""; next }
      /^LLAMA_BASE_URL=/ { print "LLAMA_BASE_URL=\"http://127.0.0.1:11434/v1\""; next }
      /^MODEL_PATH=/ { print "MODEL_PATH=\"/Users/tester/models/alpha.gguf\""; next }
      /^FIREWALL_SHARED_SUBNET=/ { print "FIREWALL_SHARED_SUBNET=\"192.168.64.0/24\""; next }
      /^OPENCLAW_PROVIDER_NAME=/ { print "OPENCLAW_PROVIDER_NAME=\"clawbox\""; next }
      /^OPENCLAW_DEFAULT_MODEL=/ { print "OPENCLAW_DEFAULT_MODEL=\"alpha\""; next }
      /^OPENCLAW_AUTOSTART=/ { print "OPENCLAW_AUTOSTART=\"true\""; next }
      { print }
    ' "$env_file" > "$temp_file"
    mv "$temp_file" "$env_file"

    run_prestart_llama_instance_flow() {
      REPLY='11435'
      LLAMA_USE_EXISTING_INSTANCE=false
      return 0
    }

    ensure_env_bootstrap < <(printf '')
    printf 'LLAMA_PORT=%s\n' "$LLAMA_PORT"
    printf 'LLAMA_BASE_URL=%s\n' "$LLAMA_BASE_URL"
    printf 'ENV_FILE_PORT=%s\n' "$(grep '^LLAMA_PORT=' "$ENV_FILE")"
    printf 'ENV_FILE_BASE_URL=%s\n' "$(grep '^LLAMA_BASE_URL=' "$ENV_FILE")"
  } 2>&1)"

  assert_contains 'fast path updates the in-memory llama port after prestart discovery' "$output" 'LLAMA_PORT=11435'
  assert_contains 'fast path updates the in-memory llama base url after prestart discovery' "$output" 'LLAMA_BASE_URL=http://127.0.0.1:11435/v1'
  assert_contains 'fast path rewrites the env file llama port after prestart discovery' "$output" 'ENV_FILE_PORT=LLAMA_PORT="11435"'
  assert_contains 'fast path rewrites the env file llama base url after prestart discovery' "$output" 'ENV_FILE_BASE_URL=LLAMA_BASE_URL="http://127.0.0.1:11435/v1"'
}

test_setup_preserves_explicit_external_llama_base_url() {
  local output
  local configured_base_url='http://host.internal:19090/custom/v1'

  output="$({
    load_setup_functions

    local env_example="$TEMP_DIR/.env.example"
    local env_file="$TEMP_DIR/.env"
    local temp_file="$TEMP_DIR/env.tmp"

    cp "$ROOT_DIR/.env.example" "$env_example"
    cp "$env_example" "$env_file"

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
      /^LLAMA_BIN=/ { print "LLAMA_BIN=\"/Users/tester/bin/llama-server\""; next }
      /^LLAMA_HOST=/ { print "LLAMA_HOST=\"0.0.0.0\""; next }
      /^LLAMA_PORT=/ { print "LLAMA_PORT=\"11434\""; next }
      /^LLAMA_CTX=/ { print "LLAMA_CTX=\"16384\""; next }
      /^LLAMA_BASE_URL=/ { print "LLAMA_BASE_URL=\"'"$configured_base_url"'\""; next }
      /^LLAMA_EXTERNAL=/ { print "LLAMA_EXTERNAL=\"true\""; next }
      /^MODEL_PATH=/ { print "MODEL_PATH=\"/Users/tester/models/alpha.gguf\""; next }
      /^FIREWALL_SHARED_SUBNET=/ { print "FIREWALL_SHARED_SUBNET=\"192.168.64.0/24\""; next }
      /^OPENCLAW_PROVIDER_NAME=/ { print "OPENCLAW_PROVIDER_NAME=\"clawbox\""; next }
      /^OPENCLAW_DEFAULT_MODEL=/ { print "OPENCLAW_DEFAULT_MODEL=\"alpha\""; next }
      /^OPENCLAW_AUTOSTART=/ { print "OPENCLAW_AUTOSTART=\"true\""; next }
      { print }
    ' "$env_file" > "$temp_file"
    mv "$temp_file" "$env_file"

    run_prestart_llama_instance_flow() {
      REPLY='11434'
      LLAMA_USE_EXISTING_INSTANCE=true
      LLAMA_EXTERNAL=true
      return 0
    }

    ensure_env_bootstrap < <(printf '')
    printf 'LLAMA_BASE_URL=%s\n' "$LLAMA_BASE_URL"
    printf 'ENV_FILE_BASE_URL=%s\n' "$(grep '^LLAMA_BASE_URL=' "$ENV_FILE")"
  } 2>&1)"

  assert_contains 'setup preserves the explicit external llama base url in memory' "$output" "LLAMA_BASE_URL=$configured_base_url"
  assert_contains 'setup preserves the explicit external llama base url in the env file' "$output" "ENV_FILE_BASE_URL=LLAMA_BASE_URL=\"$configured_base_url\""
}

test_ensure_env_bootstrap_repair_mode_skips_model_llama_and_openclaw_sections() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    ENV_FILE="$TEMP_DIR/.env"
    ENV_CREATED_FROM_EXAMPLE=false
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=true
    VM_IP=''
    VM_USER=''
    VM_USER_PATH=''
    VM_HOST=''
    VM_RUNTIME_PATH=''
    VM_MACHINE_NAME=''
    HOST_IP=''
    LLAMA_BIN=''
    LLAMA_HOST=''
    LLAMA_PORT=''
    LLAMA_CTX=''
    LLAMA_BASE_URL=''
    MODEL_PATH=''
    FIREWALL_SHARED_SUBNET=''
    OPENCLAW_PROVIDER_NAME=''
    OPENCLAW_DEFAULT_MODEL=''
    OPENCLAW_AUTOSTART=''

    source_env_file() { :; }
    write_env_from_template() { :; }
    ensure_vm_connection_setup() {
      VM_IP='192.168.64.2'
      VM_USER='tester'
      VM_USER_PATH='/Users/tester'
      VM_HOST='tester@192.168.64.2'
      VM_RUNTIME_PATH='/Users/tester/ClawBox'
      VM_MACHINE_NAME='ClawVM'
      return 0
    }
    ensure_vm_connectivity_or_repair() {
      return 0
    }

    ensure_env_bootstrap < <(printf '')
    printf 'ENV_BOOTSTRAPPED=%s\n' "$ENV_BOOTSTRAPPED"
    printf 'VM_HOST=%s\n' "$VM_HOST"
  } 2>&1)"

  assert_not_contains 'repair mode skips the model configuration section' "$output" ' > Model Configuration'
  assert_not_contains 'repair mode skips the llama configuration section' "$output" ' > LLaMA Server Configuration'
  assert_not_contains 'repair mode skips the openclaw configuration section' "$output" ' > OpenClaw Configuration'
  assert_contains 'repair mode still marks env bootstrap complete' "$output" 'ENV_BOOTSTRAPPED=true'
  assert_contains 'repair mode still persists vm connection state' "$output" 'VM_HOST=tester@192.168.64.2'
}

test_ensure_env_bootstrap_requires_tty_when_setup_is_needed() {
  local output

  output="$({
    load_setup_functions

    ENV_FILE="$TEMP_DIR/.env"
    ENV_CREATED_FROM_EXAMPLE=false
    ENV_BOOTSTRAPPED=false
    VM_REPAIR_MODE=false
    HOST_IP=''
    VM_IP=''
    VM_USER=''
    VM_USER_PATH=''
    VM_HOST=''
    VM_RUNTIME_PATH=''
    VM_MACHINE_NAME=''
    LLAMA_BIN=''
    LLAMA_HOST=''
    LLAMA_PORT=''
    LLAMA_CTX=''
    LLAMA_BASE_URL=''
    MODEL_PATH=''
    FIREWALL_SHARED_SUBNET=''
    OPENCLAW_PROVIDER_NAME=''
    OPENCLAW_DEFAULT_MODEL=''
    OPENCLAW_AUTOSTART=''

    source_env_file() { :; }

    if ensure_env_bootstrap; then
      printf 'STATUS:0\n'
    else
      printf 'STATUS:%s\n' "$?"
    fi
  } </dev/null 2>&1)"

  assert_contains 'tty guard reports that interactive setup requires a tty' "$output" 'Interactive setup requires a TTY'
  assert_contains 'tty guard reports how to rerun setup interactively' "$output" 'Run ./clawbox setup in a terminal to complete .env setup.'
  assert_contains 'tty guard returns failure when setup is needed without a tty' "$output" 'STATUS:1'
}

test_vm_platform_check_without_utm_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'n'

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 1
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    list_detected_utm_vm_names() {
      return 0
    }

    if ensure_vm_platform_ready; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
  } 2>&1)"

  assert_contains 'vm platform check shows section' "$output" ' > VM Platform Check'
  assert_contains 'vm platform check shows apple silicon ready' "$output" '- Apple Silicon Host ✅'
  assert_contains 'vm platform check shows utm missing' "$output" '- UTM virtualization ❌'
  assert_contains 'vm platform check shows guest vms missing' "$output" '- macOS guest VMs ❌'
  assert_contains 'vm platform check shows install utm step' "$output" '1) Install UTM'
  assert_contains 'vm platform check shows create vm step' "$output" '2) Create a macOS VM in UTM'
  assert_contains 'vm platform check shows ssh step' "$output" '3) Enable SSH inside the VM (Settings > General > Sharing > Remote Login)'
  assert_contains 'vm platform check shows rerun step' "$output" '4) Continue or re-run setup'
  assert_contains 'vm platform check shows utm link' "$output" 'https://mac.getutm.app/'
  assert_contains 'vm platform check prompts before exit' "$output" 'Have you completed the above steps? [y/N]:'
  assert_contains 'vm platform check exits gracefully when incomplete' "$output" 'STATUS:42'
}

test_vm_platform_check_without_vms_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'n'

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    list_detected_utm_vm_names() {
      return 0
    }

    if ensure_vm_platform_ready; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
  } 2>&1)"

  assert_contains 'vm platform check shows utm ready' "$output" '- UTM virtualization ✅'
  assert_contains 'vm platform check shows vms missing' "$output" '- macOS guest VMs ❌'
  assert_contains 'vm platform check shows create vm step when utm exists' "$output" '1) Create a macOS VM in UTM'
  assert_contains 'vm platform check shows enable ssh step when utm exists' "$output" '2) Enable SSH inside the VM (Settings > General > Sharing > Remote Login)'
  assert_contains 'vm platform check shows rerun step when utm exists' "$output" '3) Continue or re-run setup'
  assert_contains 'vm platform check exits gracefully when no vm exists' "$output" 'STATUS:42'
}

test_single_detected_utm_vm_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'y'

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    list_detected_utm_vm_names() {
      printf 'Jimmy\n'
    }

    VM_MACHINE_NAME=''
    llama_capture_status ensure_vm_platform_ready
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
    printf 'VM_MACHINE_NAME:%s\n' "$VM_MACHINE_NAME"
  } 2>&1)"

  assert_contains 'single detected vm flow shows detection section' "$output" ' > VM Detection'
  assert_contains 'single detected vm flow shows detected vm label' "$output" 'Detected existing UTM VM:'
  assert_contains 'single detected vm flow shows detected vm entry' "$output" '- Jimmy'
  assert_contains 'single detected vm flow prompts to use vm' "$output" 'Use this VM? [Y/n]:'
  assert_contains 'single detected vm flow succeeds' "$output" 'STATUS:0'
  assert_contains 'single detected vm flow uses detected name' "$output" 'VM_MACHINE_NAME:Jimmy'
}

test_multiple_detected_utm_vms_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers '2'

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    list_detected_utm_vm_names() {
      printf 'Alpha\nBeta\n'
    }

    VM_MACHINE_NAME=''
    llama_capture_status ensure_vm_platform_ready
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
    printf 'VM_MACHINE_NAME:%s\n' "$VM_MACHINE_NAME"
  } 2>&1)"

  assert_contains 'multiple detected vm flow shows detection section' "$output" ' > VM Detection'
  assert_contains 'multiple detected vm flow shows menu heading' "$output" 'Detected UTM VMs:'
  assert_contains 'multiple detected vm flow shows first option' "$output" '1) Alpha'
  assert_contains 'multiple detected vm flow shows second option' "$output" '2) Beta'
  assert_contains 'multiple detected vm flow shows create new option' "$output" '0) I want to create a new VM'
  assert_contains 'multiple detected vm flow prompts for vm choice' "$output" 'Choose VM [0-2]:'
  assert_contains 'multiple detected vm flow succeeds' "$output" 'STATUS:0'
  assert_contains 'multiple detected vm flow returns selected vm' "$output" 'VM_MACHINE_NAME:Beta'
}

test_decline_existing_vm_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'n' 'n'

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    list_detected_utm_vm_names() {
      printf 'ReadyVM\n'
    }

    if ensure_vm_platform_ready; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
  } 2>&1)"

  assert_contains 'decline vm flow shows detection section first' "$output" ' > VM Detection'
  assert_not_contains 'decline vm flow does not incorrectly fall into onboarding when an existing vm was simply declined' "$output" 'Next steps:'
  assert_contains 'decline vm flow keeps the platform-ready path successful after declining automatic selection' "$output" 'STATUS:0'
}

test_vm_platform_ready_existing_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'y'

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    list_detected_utm_vm_names() {
      printf 'ReadyVM\n'
    }

    VM_MACHINE_NAME=''
    llama_capture_status ensure_vm_platform_ready
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
    printf 'VM_MACHINE_NAME:%s\n' "$VM_MACHINE_NAME"
  } 2>&1)"

  assert_contains 'vm platform ready flow succeeds' "$output" 'STATUS:0'
  assert_contains 'vm platform ready flow uses detected vm' "$output" 'VM_MACHINE_NAME:ReadyVM'
  if printf '%s' "$output" | grep -Fq 'Next steps:'; then
    fail 'vm platform ready flow should not show next steps when requirements are satisfied'
  else
    pass 'vm platform ready flow keeps successful path unchanged'
  fi
}

test_vm_detection_permission_block_graceful_exit_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers '1'

    FDA_OPEN_ATTEMPTS=0
    HOME="$TEMP_DIR/permission-block-home"
    mkdir -p "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    ls() {
      return 1
    }

    open_full_disk_access_settings() {
      FDA_OPEN_ATTEMPTS=$((FDA_OPEN_ATTEMPTS + 1))
      return 0
    }

    if ensure_vm_platform_ready; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
    printf 'FDA_OPEN_ATTEMPTS:%s\n' "$FDA_OPEN_ATTEMPTS"
  } 2>&1)"

  assert_contains 'permission block flow shows vm detection section' "$output" ' > VM Detection'
  assert_contains 'permission block flow explains privacy block' "$output" 'UTM access is blocked by macOS privacy settings.'
  assert_contains 'permission block flow shows guided detection guidance' "$output" 'Guided VM detection requires:'
  assert_contains 'permission block flow shows full disk access option' "$output" '1) Grant Full Disk Access and re-run setup (recommended)'
  assert_contains 'permission block flow shows manual option' "$output" '2) Continue with manual VM configuration'
  assert_contains 'permission block flow shows exit option' "$output" '3) Exit'
  assert_contains 'permission block flow prompts for an option' "$output" 'Choose option [1-3]:'
  assert_contains 'permission block flow explains why guided detection cannot continue' "$output" 'ClawBox cannot continue with guided VM detection until macOS allows access to the UTM VM directory.'
  assert_contains 'permission block flow identifies which app needs access' "$output" 'Grant Full Disk Access to the app running setup (Terminal, iTerm, or Visual Studio Code).'
  assert_contains 'permission block flow repeats the exact settings path' "$output" 'System Settings > Privacy & Security > Full Disk Access'
  assert_contains 'permission block flow attempts to open settings' "$output" 'Attempting to open the Full Disk Access settings pane...'
  assert_contains 'permission block flow tells the user what to do next' "$output" 'After granting Full Disk Access, re-run setup.'
  assert_contains 'permission block flow exits gracefully' "$output" 'STATUS:42'
  assert_contains 'permission block flow calls the settings opener once' "$output" 'FDA_OPEN_ATTEMPTS:1'
  assert_not_contains 'permission block exit flow should not show vm platform checklist' "$output" 'macOS guest VMs ❌'
}

test_vm_detection_permission_block_manual_fallback_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers '2' 'Manual VM'
    HOME="$TEMP_DIR/permission-block-manual-home"
    mkdir -p "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    ls() {
      return 1
    }

    llama_capture_status ensure_vm_platform_ready
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
    resolve_vm_machine_name_value '' 'FallbackVM'
    printf 'VM_MACHINE_NAME:%s\n' "$REPLY"
  } 2>&1)"

  assert_contains 'permission block manual flow returns success' "$output" 'STATUS:0'
  assert_contains 'permission block manual flow uses manual vm prompt' "$output" 'Enter VM name [FallbackVM]:'
  assert_contains 'permission block manual flow returns manual vm name' "$output" 'VM_MACHINE_NAME:Manual VM'
  assert_not_contains 'permission block manual flow skips automatic vm discovery ux' "$output" 'Detected UTM VMs:'
  assert_not_contains 'permission block manual flow skips onboarding steps' "$output" 'Next steps:'
}

test_existing_llama_instance_flow() {
  local output
  local warning_prefix
  local error_prefix
  local bold_prefix
  local reset_suffix

  bold_prefix="$(printf '\033[1m')"
  warning_prefix="$(printf '\033[33m\033[1m')"
  error_prefix="$(printf '\033[31m\033[1m')"
  reset_suffix="$(printf '\033[0m')"

  output="$({
    load_setup_functions
    install_prompt_stubs

    COLOR_BOLD="$bold_prefix"
    COLOR_YELLOW="$(printf '\033[33m')"
    COLOR_RED="$(printf '\033[31m')"
    COLOR_RESET="$reset_suffix"

    LLAMA_BIN='/opt/homebrew/bin/llama-server'

    llama_port_in_use() {
      return 0
    }

    llama_api_responding() {
      return 0
    }

    llama_runtime_env_matches_mode() {
      return 0
    }

    llama_describe_existing_instance() {
      LLAMA_EXISTING_INSTANCE_LAUNCH_LABEL='com.clawbox.llama'
      LLAMA_EXISTING_INSTANCE_BINARY_PATH="$LLAMA_BIN"
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: testuser (ClawBox-managed LaunchAgent)'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance is managed by ClawBox for the current user.'
      LLAMA_EXISTING_INSTANCE_RUNTIME='ClawBox-managed LaunchAgent'
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=true
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

    llama_capture_status handle_prestart_llama_instance_choice '127.0.0.1' '11434'
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
  } 2>&1)"

  assert_contains 'existing llama flow shows detection message' "$output" 'llama-server detected at http://127.0.0.1:11434'
  assert_contains 'existing llama flow uses warning styling for managed decision state' "$output" "${warning_prefix}llama-server detected at http://127.0.0.1:11434${reset_suffix}"
  assert_not_contains 'existing llama flow does not use error styling for managed decision state' "$output" "${error_prefix}llama-server detected at http://127.0.0.1:11434${reset_suffix}"
  assert_contains 'existing llama flow shows the selected port' "$output" 'Port: 11434'
  assert_contains 'existing llama flow shows the launch label' "$output" 'Launch label: com.clawbox.llama'
  assert_contains 'existing llama flow shows the binary path' "$output" 'Binary: /opt/homebrew/bin/llama-server'
  assert_contains 'existing llama flow shows ownership context' "$output" 'Owner: testuser (ClawBox-managed LaunchAgent)'
  assert_contains 'existing llama flow shows non-disruptive reuse first' "$output" '1) Use the existing running llama-server on port 11434 (recommended)'
  assert_contains 'existing llama flow shows restart option second' "$output" '2) Restart the existing llama-server on port 11434'
  assert_contains 'existing llama flow shows different port option' "$output" '3) Choose a different port'
  assert_contains 'existing llama flow shows exit option' "$output" '4) Exit'
  assert_contains 'existing llama flow exits cleanly from the menu' "$output" 'STATUS:42'
  assert_no_excessive_blank_lines 'existing llama flow avoids excessive blank lines' "$output"
}

test_external_llama_instance_cannot_be_managed_flow() {
  local output
  local choice_file="$TEMP_DIR/external-llama-choices.txt"
  local choice_index_file="$TEMP_DIR/external-llama-choice-index.txt"
  local warning_prefix
  local error_prefix
  local reset_suffix

  warning_prefix="$(printf '\033[33m\033[1m')"
  error_prefix="$(printf '\033[31m\033[1m')"
  reset_suffix="$(printf '\033[0m')"

  printf '4\n' > "$choice_file"
  printf '0\n' > "$choice_index_file"

  output="$({
    load_setup_functions
    install_prompt_stubs

    llama_port_in_use() {
      return 0
    }

    llama_api_responding() {
      return 0
    }

    llama_describe_existing_instance() {
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: alice (interactive user session)'
      LLAMA_EXISTING_INSTANCE_RUNTIME='interactive user session'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance depends on the "alice" account remaining logged in.'
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=false
      LLAMA_EXISTING_INSTANCE_CONTROLLABLE=false
      return 0
    }

    pgrep() {
      return 1
    }

    llama_read_choice() {
      local prompt_label="$1"
      local choice_index=0
      local answer=''

      prompt "$prompt_label"

      if [ -f "$choice_index_file" ]; then
        IFS= read -r choice_index < "$choice_index_file" || choice_index=0
      fi

      answer="$(sed -n "$((choice_index + 1))p" "$choice_file" 2>/dev/null)"
      printf '%s\n' "$((choice_index + 1))" > "$choice_index_file"

      REPLY="$answer"
      printf '%s\n' "$answer"
    }

    llama_capture_status handle_prestart_llama_instance_choice '127.0.0.1' '11434'
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
  } 2>&1)"

  assert_contains 'external llama flow shows ownership context' "$output" 'Owner: alice (interactive user session)'
  assert_contains 'external llama flow recommends starting a separate managed instance on another port as option one' "$output" '1) Start a separate ClawBox-managed instance on another port (recommended)'
  assert_not_contains 'external llama flow keeps the note informational rather than red' "$output" "${error_prefix}This instance depends on the \"alice\" account remaining logged in.${reset_suffix}"
  assert_contains 'external llama flow exits cleanly from the menu' "$output" 'STATUS:42'
}

test_cross_user_hidden_llama_instance_flow() {
  local output
  local choice_file="$TEMP_DIR/cross-user-hidden-llama-choices.txt"
  local choice_index_file="$TEMP_DIR/cross-user-hidden-llama-choice-index.txt"
  local warning_prefix
  local error_prefix
  local reset_suffix

  warning_prefix="$(printf '\033[33m\033[1m')"
  error_prefix="$(printf '\033[31m\033[1m')"
  reset_suffix="$(printf '\033[0m')"

  printf '4\n' > "$choice_file"
  printf '0\n' > "$choice_index_file"

  output="$({
    load_setup_functions
    install_prompt_stubs

    llama_port_in_use() {
      return 0
    }

    llama_api_responding() {
      return 0
    }

    llama_describe_existing_instance() {
      err 'Checking for existing llama-server instances...'
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: another macOS user session (process ownership not accessible)'
      LLAMA_EXISTING_INSTANCE_RUNTIME='cross-user-session'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance may stop when the owning user logs out.'
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=false
      LLAMA_EXISTING_INSTANCE_CONTROLLABLE=false
      return 0
    }

    llama_read_choice() {
      local prompt_label="$1"
      local choice_index=0
      local answer=''

      prompt "$prompt_label"

      if [ -f "$choice_index_file" ]; then
        IFS= read -r choice_index < "$choice_index_file" || choice_index=0
      fi

      answer="$(sed -n "$((choice_index + 1))p" "$choice_file" 2>/dev/null)"
      printf '%s\n' "$((choice_index + 1))" > "$choice_index_file"

      REPLY="$answer"
      printf '%s\n' "$answer"
    }

    llama_capture_status handle_prestart_llama_instance_choice '127.0.0.1' '11434'
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
  } 2>&1)"

  assert_contains 'cross-user hidden llama flow shows inferred ownership context' "$output" 'Owner: another macOS user session (process ownership not accessible)'
  assert_contains 'cross-user hidden llama flow explains logout risk' "$output" 'This instance may stop when the owning user logs out.'
  assert_contains 'cross-user hidden llama flow renders the warning note text' "$output" 'This instance may stop when the owning user logs out.'
  assert_not_contains 'cross-user hidden llama flow does not render the note as yellow' "$output" "${warning_prefix}This instance may stop when the owning user logs out.${reset_suffix}"
  assert_contains 'cross-user hidden llama flow recommends a separate managed instance on another port as option one' "$output" '1) Start a separate ClawBox-managed instance on another port (recommended)'
  assert_contains 'cross-user hidden llama flow keeps reuse as the second option' "$output" '2) Use existing instance'
  assert_not_contains 'cross-user hidden llama flow removes the recommended tag from reuse' "$output" '2) Use existing instance (recommended)'
  assert_contains 'cross-user hidden llama flow exits cleanly' "$output" 'STATUS:42'
  assert_no_excessive_blank_lines 'cross-user hidden llama flow avoids excessive blank lines' "$output"
}

test_owned_llama_instance_can_restart_flow() {
  local output
  local choice_file="$TEMP_DIR/owned-llama-choices.txt"
  local choice_index_file="$TEMP_DIR/owned-llama-choice-index.txt"

  printf '1\n' > "$choice_file"
  printf '0\n' > "$choice_index_file"

  output="$({
    load_setup_functions
    install_prompt_stubs

    llama_port_in_use() {
      return 0
    }

    api_state='up'

    llama_api_responding() {
      [ "$api_state" = 'up' ]
    }

    llama_describe_existing_instance() {
      LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: testuser (current user session)'
      LLAMA_EXISTING_INSTANCE_RUNTIME='current user session'
      LLAMA_EXISTING_INSTANCE_NOTE='This instance will stop if you log out.'
      LLAMA_EXISTING_INSTANCE_RECOMMENDED=false
      LLAMA_EXISTING_INSTANCE_CONTROLLABLE=true
      return 0
    }

    pgrep() {
      return 0
    }

    pkill() {
      api_state='down'
      return 0
    }

    stop_user_owned_llama_instance() {
      api_state='down'
      return 0
    }

    detect_existing_llama_install_mode() {
      REPLY='user'
      return 0
    }

    launchctl() {
      return 0
    }

    llama_read_choice() {
      local prompt_label="$1"
      local choice_index=0
      local answer=''

      prompt "$prompt_label"

      if [ -f "$choice_index_file" ]; then
        IFS= read -r choice_index < "$choice_index_file" || choice_index=0
      fi

      answer="$(sed -n "$((choice_index + 1))p" "$choice_file" 2>/dev/null)"
      printf '%s\n' "$((choice_index + 1))" > "$choice_index_file"

      REPLY="$answer"
      printf '%s\n' "$answer"
    }

    llama_capture_status handle_prestart_llama_instance_choice '127.0.0.1' '11434'
    printf 'STATUS:%s\n' "$LLAMA_LAST_STATUS"
    printf 'REPLY:%s\n' "$REPLY"
    printf 'USE_EXISTING:%s\n' "$LLAMA_USE_EXISTING_INSTANCE"
  } 2>&1)"

  assert_contains 'owned llama flow returns success after stop' "$output" 'STATUS:0'
  assert_contains 'owned llama flow keeps the selected port' "$output" 'REPLY:11434'
  assert_contains 'owned llama flow continues with managed setup' "$output" 'USE_EXISTING:false'
}

test_llama_install_flows() {
  local auto_output
  local manual_output

  auto_output="$(printf '1\n' | {
    source "$ROOT_DIR/lib/output.sh"
    source "$ROOT_DIR/lib/prompt.sh"
    source "$ROOT_DIR/lib/log.sh"
    source "$ROOT_DIR/lib/llama.sh"

    local fake_bin="$TEMP_DIR/auto-llama-server"
    : > "$fake_bin"
    chmod +x "$fake_bin"

    llama_homebrew_state() {
      REPLY='usable'
    }

    install_llama_cpp_automatically() {
      step 'Installing llama.cpp automatically'
      REPLY="$fake_bin"
      return 0
    }

    resolve_llama_bin_path '' >/dev/null
  } 2>&1)"

  manual_output="$({
    source "$ROOT_DIR/lib/output.sh"
    source "$ROOT_DIR/lib/prompt.sh"
    source "$ROOT_DIR/lib/log.sh"
    source "$ROOT_DIR/lib/llama.sh"

    local fake_bin="$TEMP_DIR/manual-llama-server"
    : > "$fake_bin"
    chmod +x "$fake_bin"

    llama_homebrew_state() {
      REPLY='not-installed'
    }

    llama_can_auto_install() {
      return 1
    }

    user_has_sudo() {
      return 1
    }

    llama_can_install_homebrew_automatically() {
      return 1
    }

    print_llama_auto_install_recovery_plan 'not-installed'
    err 'If you have a llama-server binary available, you can continue without fixing Homebrew:'
    err_blank_line
    prompt 'Enter full path to llama-server (or press Enter to cancel):'
    prompt_complete
    out "$fake_bin"
  } 2>&1)"

  assert_contains 'auto llama flow shows missing binary options' "$auto_output" 'llama-server binary not found.'
  assert_contains 'auto llama flow shows install options' "$auto_output" '1) Install llama.cpp automatically'
  assert_no_excessive_blank_lines 'auto llama flow avoids excessive blank lines' "$auto_output"

  assert_contains 'manual llama flow shows recovery callout' "$manual_output" 'Automatic installation is not available in this environment.'
  assert_contains 'manual llama flow shows manual binary guidance' "$manual_output" 'If you have a llama-server binary available, you can continue without fixing Homebrew:'
  assert_no_excessive_blank_lines 'manual llama flow avoids excessive blank lines' "$manual_output"
}

test_vm_connectivity_repair_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'n'

    source_env_file() { :; }
    write_env_from_template() { :; }
    ssh_check() {
      return 1
    }
    setup_vm_is_running() {
      return 1
    }

    VM_MACHINE_NAME='RepairVM'
    VM_IP='192.168.64.2'
    VM_USER='repair-user'
    VM_USER_PATH='/Users/repair-user'
    VM_HOST='repair-user@192.168.64.2'

    ensure_vm_connectivity_or_repair || true
  } 2>&1)"

  assert_contains 'repair flow warns when VM is stopped' "$output" 'VM is not running.'
  assert_contains 'repair flow reports the initial vm state check before a possible pause' "$output" 'Checking VM state...'
  assert_not_contains 'repair flow omits the low-value vm state completion line' "$output" 'VM state checked.'
  assert_contains 'repair flow offers VM start prompt' "$output" 'Start the VM now? [Y/n]:'
  assert_no_excessive_blank_lines 'repair flow avoids excessive blank lines' "$output"
}

test_vm_running_without_ssh_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'n'

    ssh_check() {
      return 1
    }

    probe_vm_ssh_endpoint() {
      REPLY='unknown'
      return 0
    }

    setup_vm_is_running() {
      VM_RUNNING_STATE_CONFIDENCE='exact'
      return 0
    }

    VM_RECENTLY_STARTED=false

    ensure_vm_connectivity_or_repair || true
  } 2>&1)"

  assert_contains 'running vm flow reports ssh delay instead of stopped' "$output" 'VM is running but is not yet reachable via SSH.'
  assert_contains 'running vm flow shows booting cause' "$output" '- VM is still booting'
  assert_contains 'running vm flow shows remote login cause' "$output" '- Remote Login is disabled'
  assert_contains 'running vm flow shows networking cause' "$output" '- Networking is not ready yet'
}

test_vm_connection_setup_reports_vm_settings_completion_without_progress_spinner() {
  local output
  local rendered_output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers '192.168.64.2' 'tester' '/Users/tester'

    ensure_vm_platform_ready() {
      return 0
    }

    resolve_vm_machine_name_value() {
      REPLY='ClawVM'
      return 0
    }

    derive_runtime_path() {
      REPLY='/Users/tester/ClawBox'
      return 0
    }

    source_env_file() {
      return 0
    }

    write_env_from_template() {
      return 0
    }

    ensure_vm_connection_setup
  } 2>&1)"
  rendered_output="$(render_terminal_output "$output")"

  assert_not_contains 'vm connection setup omits unnecessary vm settings progress output' "$output" 'Saving VM settings...'
  assert_contains 'vm connection setup reports vm settings completion' "$output" 'VM settings saved.'
  if [[ "$rendered_output" == *$'\n\n\nVM settings saved.'* ]]; then
    fail 'vm connection setup does not leave two blank separators before settings saved'
  else
    pass 'vm connection setup does not leave two blank separators before settings saved'
  fi
}

test_vm_connection_setup_prefers_configured_vm_ip_default() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers '' '' ''

    ensure_vm_platform_ready() {
      return 0
    }

    resolve_vm_machine_name_value() {
      REPLY='ClawVM'
      return 0
    }

    derive_runtime_path() {
      REPLY='/Users/tester/ClawBox'
      return 0
    }

    source_env_file() {
      return 0
    }

    write_env_from_template() {
      return 0
    }

    VM_IP='192.168.64.7'
    VM_HOST='tester@192.168.64.2'
    VM_USER='tester'

    ensure_vm_connection_setup
  } 2>&1)"

  assert_contains 'vm connection rerun uses configured vm ip as the prompt default' "$output" 'Enter VM IP address [192.168.64.7]:'
  assert_contains 'vm connection rerun keeps the configured vm ip after accepting the default' "$output" 'VM settings saved.'
}

test_manual_ssh_setup_uses_section_heading() {
  local output

  output="$({
    load_setup_functions

    VM_HOST='vm-user@192.168.64.2'

    print_manual_ssh_setup_instructions
  } 2>&1)"

  assert_contains 'manual ssh setup uses a section heading' "$output" ' > Manual SSH Setup'
  assert_not_contains 'manual ssh setup no longer uses the old inline heading' "$output" 'Manual SSH setup commands:'
}

test_status_helper_suppresses_duplicate_noninteractive_wait_lines() {
  local output

  output="$({
    load_setup_functions

    status_begin 'Waiting for VM network...'
    status_tick 'Waiting for VM network...'
    status_tick 'Waiting for VM network...'
    status_tick 'Waiting for VM network...'
    status_end 'VM network detected.'
  } 2>&1)"

  assert_equals 'status helper emits a noninteractive wait line once' "$(printf '%s' "$output" | grep -F -c 'Waiting for VM network...')" '1'
  assert_contains 'status helper emits the stable completion line' "$output" 'VM network detected.'
}

test_status_helper_renders_trailing_spinner_frames() {
  local output

  output="$({
    load_setup_functions

    _status_can_spin() {
      return 0
    }

    status_begin 'Waiting for VM network...'
    status_tick 'Waiting for VM network...'
    status_tick 'Waiting for VM network...'
    status_tick 'Waiting for VM network...'
    status_end 'VM network detected.'
  } 2>&1)"

  assert_contains 'status helper renders slash as a trailing spinner frame' "$output" 'Waiting for VM network /'
  assert_contains 'status helper renders dash as a trailing spinner frame' "$output" 'Waiting for VM network -'
  assert_contains 'status helper renders a single trailing backslash spinner frame' "$output" 'Waiting for VM network \'
  assert_not_contains 'status helper does not render a leading spinner frame' "$output" '/ Waiting for VM network...'
  assert_not_contains 'status helper strips the ellipsis while spinning' "$output" 'Waiting for VM network... /'
}

test_status_helper_uses_fast_spinner_cadence() {
  local interval=''

  load_setup_functions
  interval="$(status_tick_interval)"

  assert_equals 'status helper doubles the default spinner cadence' "$interval" '0.075'
}

test_status_helper_applies_semantic_result_styling() {
  local output
  local success_color
  local warning_color
  local error_color
  local bold_prefix
  local reset_suffix
  local success_prefix
  local warning_prefix
  local error_prefix

  bold_prefix="$(printf '\033[1m')"
  success_color="$(printf '\033[32m')"
  warning_color="$(printf '\033[33m')"
  error_color="$(printf '\033[31m')"
  reset_suffix="$(printf '\033[0m')"
  success_prefix="${success_color}${bold_prefix}"
  warning_prefix="${warning_color}${bold_prefix}"
  error_prefix="${error_color}${bold_prefix}"

  output="$({
    load_setup_functions

    COLOR_GREEN="$success_color"
    COLOR_YELLOW="$warning_color"
    COLOR_RED="$error_color"
    COLOR_BOLD="$bold_prefix"
    COLOR_RESET="$reset_suffix"

    _status_can_spin() {
      return 0
    }

    status_begin 'Waiting for VM runtime...'
    status_end 'VM runtime detected.' 'success'
    status_begin 'Waiting for VM network...'
    status_end 'VM network was not detected within the expected time window.' 'warning'
    status_begin 'Starting VM with UTM...'
    status_end 'VM start request via UTM failed.' 'error'
    status_begin 'Saving VM settings...'
    status_end 'VM start requested.' 'info'
  } 2>&1)"

  assert_contains 'status helper styles success results green and bold' "$output" "${success_prefix}VM runtime detected.${reset_suffix}"
  assert_contains 'status helper styles warning results yellow and bold' "$output" "${warning_prefix}VM network was not detected within the expected time window.${reset_suffix}"
  assert_contains 'status helper styles error results red and bold' "$output" "${error_prefix}VM start request via UTM failed.${reset_suffix}"
  assert_contains 'status helper keeps info results unstyled' "$output" 'VM start requested.'
  assert_not_contains 'status helper does not bold plain info results' "$output" "${bold_prefix}VM start requested.${reset_suffix}"
}

test_status_helper_restores_cursor_after_completion() {
  local output
  local hide_cursor
  local show_cursor

  hide_cursor="$(printf '\033[?25l')"
  show_cursor="$(printf '\033[?25h')"

  output="$({
    load_setup_functions

    _status_can_spin() {
      return 0
    }

    progress() {
      return 0
    }

    progress_done() {
      return 0
    }

    status_begin 'Waiting for VM network...'
    status_end 'VM network detected.'
  } 2>&1)"

  assert_contains 'status helper hides the cursor while spinning' "$output" "$hide_cursor"
  assert_contains 'status helper restores the cursor when the spinner completes' "$output" "$show_cursor"
}

test_status_helper_avoids_extra_blank_lines_after_prompt() {
  local output
  local rendered_output

  output="$({
    load_setup_functions

    _status_can_spin() {
      return 0
    }

    prompt 'Start the VM now? [Y/n]:'
    printf 'y\n' >&2
    prompt_complete
    status_begin 'Starting VM with UTM...'
    status_end 'VM start requested.'
  } 2>&1)"

  rendered_output="$(render_terminal_output "$output")"

  if [[ "$rendered_output" == *$'Start the VM now? [Y/n]: y\n\n\nVM start requested.'* ]]; then
    fail 'status helper avoids extra blank lines after prompt responses'
  else
    pass 'status helper avoids extra blank lines after prompt responses'
  fi
}

test_status_helper_keeps_one_separator_after_empty_spinner_completion() {
  local output
  local rendered_output

  output="$({
    load_setup_functions

    _status_can_spin() {
      return 0
    }

    prompt 'Start the VM now? [Y/n]:'
    printf 'y\n' >&2
    prompt_complete
    status_begin 'Starting VM with UTM...'
    status_end ''
    status_begin 'Waiting for VM runtime...'
    status_end 'VM runtime detected.'
  } 2>&1)"

  rendered_output="$(render_terminal_output "$output")"

  if [[ "$rendered_output" == *$'Start the VM now? [Y/n]: y\n\nVM runtime detected.'* ]]; then
    pass 'status helper keeps one separator after empty spinner completion'
  else
    fail 'status helper keeps one separator after empty spinner completion'
  fi

  if [[ "$rendered_output" == *$'Start the VM now? [Y/n]: y\n\n\nVM runtime detected.'* ]]; then
    fail 'status helper does not leave two separators after empty spinner completion'
  else
    pass 'status helper does not leave two separators after empty spinner completion'
  fi
}

test_prompt_spacing_surrounds_prompts_with_single_blank_lines() {
  local output
  local rendered_output

  output="$({
    load_setup_functions

    out 'Detected possible VM addresses:'
    out '1) 192.168.64.6'
    out '2) Retry manual entry'
    prompt 'Choose VM address [1-2]:'
    printf '1\n' >&2
    prompt_complete
    out 'Continuing setup.'
  } 2>&1)"

  rendered_output="$(render_terminal_output "$output")"

  assert_contains 'prompt spacing keeps one blank line above the menu prompt' "$rendered_output" $'2) Retry manual entry\n\nChoose VM address [1-2]: 1'
  assert_contains 'prompt spacing keeps one blank line below the menu prompt' "$rendered_output" $'Choose VM address [1-2]: 1\n\nContinuing setup.'
  if [[ "$rendered_output" == *$'Choose VM address [1-2]: 1\n\n\nContinuing setup.'* ]]; then
    fail 'prompt spacing does not produce double blank lines around prompts'
  else
    pass 'prompt spacing does not produce double blank lines around prompts'
  fi
}

test_status_helper_suspends_spinner_before_long_output() {
  local output
  local rendered_output

  output="$({
    load_setup_functions

    _status_can_spin() {
      return 0
    }

    status_begin 'Configuring SSH access...'
    out 'No SSH key found. Generating ~/.ssh/id_ed25519 now.'
    status_end 'SSH access configured.'
  } 2>&1)"

  rendered_output="$(render_terminal_output "$output")"

  assert_contains 'status helper preserves long-form output after suspending the spinner' "$rendered_output" 'No SSH key found. Generating ~/.ssh/id_ed25519 now.'
  assert_contains 'status helper clears the spinner line before long-form output' "$output" $'\r\033[2K\n'
  assert_contains 'status helper still emits the final completion line after suspension' "$rendered_output" 'SSH access configured.'
}

test_status_helper_keeps_spinner_and_final_lines_separate() {
  local output
  local rendered_output

  output="$({
    load_setup_functions

    _status_can_spin() {
      return 0
    }

    status_begin 'Starting VM with UTM...'
    status_tick 'Starting VM with UTM...'
    status_end 'VM start requested.'
    status_begin 'Waiting for VM runtime...'
    status_end 'VM runtime detected.'
  } 2>&1)"

  rendered_output="$(render_terminal_output "$output")"

  assert_not_contains 'status helper does not concatenate spinner and final startup lines' "$rendered_output" 'Starting VM with UTM /VM start requested.'
  assert_not_contains 'status helper does not concatenate spinner and final runtime lines' "$rendered_output" 'Waiting for VM runtime /VM runtime detected.'
  assert_contains 'status helper renders the startup final line separately' "$rendered_output" 'VM start requested.'
  assert_contains 'status helper renders the runtime final line separately' "$rendered_output" 'VM runtime detected.'
}

test_vm_startup_progress_flow() {
  local output
  local rendered_output
  local runtime_checks=0

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'y' 'y'

    start_vm_with_utm() {
      status_begin 'Starting VM with UTM...'
      status_tick 'Starting VM with UTM...'
      status_end ''
      return 0
    }

    detect_vm_state() {
      if [ "$runtime_checks" -eq 0 ]; then
        REPLY='stopped'
        VM_RUNNING_STATE_CONFIDENCE='unknown'
      else
        REPLY='booting'
        VM_RUNNING_STATE_CONFIDENCE='exact'
      fi

      return 0
    }

    setup_vm_is_running() {
      runtime_checks=$((runtime_checks + 1))
      return 0
    }

    probe_vm_network_endpoint() {
      REPLY='ssh-refused'
      return 0
    }

    probe_vm_ssh_endpoint() {
      REPLY='ssh-auth-required'
      return 0
    }

    attempt_ssh_access_bootstrap() {
      status_begin 'Configuring SSH access...'
      status_tick 'Configuring SSH access...'
      status_end 'SSH access configured.'
      return 0
    }

    VM_MACHINE_NAME='RepairVM'
    VM_IP='192.168.64.2'
    VM_USER='repair-user'
    VM_USER_PATH='/Users/repair-user'
    VM_HOST='repair-user@192.168.64.2'

    ensure_vm_connectivity_or_repair || true
  } 2>&1)"
  rendered_output="$(render_terminal_output "$output")"

  assert_contains 'startup flow reports that it is starting the vm explicitly' "$output" 'Starting VM with UTM...'
  assert_not_contains 'startup flow no longer emits redundant vm startup completion line' "$output" 'VM startup initiated.'
  if [[ "$rendered_output" == *$'\n\n\nVM runtime detected.'* ]]; then
    fail 'startup flow does not leave two blank separators before runtime detected'
  else
    pass 'startup flow does not leave two blank separators before runtime detected'
  fi
  assert_contains 'startup flow reports waiting for vm runtime' "$output" 'Waiting for VM runtime...'
  assert_contains 'startup flow reports runtime completion' "$output" 'VM runtime detected.'
  assert_contains 'startup flow reports waiting for vm network' "$output" 'Waiting for VM network...'
  assert_contains 'startup flow reports network completion' "$output" 'VM network detected.'
  assert_contains 'startup flow reports waiting for ssh service' "$output" 'Waiting for SSH...'
  assert_contains 'startup flow reports ssh completion' "$output" 'SSH readiness detected.'
  assert_contains 'startup flow reports when it begins configuring ssh access' "$output" 'Configuring SSH access...'
  assert_contains 'startup flow reports ssh configuration completion' "$output" 'SSH access configured.'
}

test_vm_startup_network_recovery_flow() {
  local output
  local normalized_output
  local readiness_calls=0
  local runtime_checks=0

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'y' '2' 'y'

    start_vm_with_utm() {
      status_begin 'Starting VM with UTM...'
      status_tick 'Starting VM with UTM...'
      status_end ''
      return 0
    }

    detect_vm_state() {
      if [ "$runtime_checks" -eq 0 ]; then
        REPLY='stopped'
        VM_RUNNING_STATE_CONFIDENCE='unknown'
      else
        REPLY='booting'
        VM_RUNNING_STATE_CONFIDENCE='exact'
      fi

      return 0
    }

    setup_vm_is_running() {
      runtime_checks=$((runtime_checks + 1))
      return 0
    }

    wait_for_known_vm_ssh_readiness() {
      readiness_calls=$((readiness_calls + 1))

      if [ "$readiness_calls" -eq 1 ]; then
        REPLY='network-timeout'
        return 1
      fi

      REPLY='ssh-auth-required'
      return 1
    }

    wait_for_vm_network() {
      status_begin 'Waiting for VM network...'
      status_tick 'Waiting for VM network...'
      status_end 'VM network detected.'
      REPLY='ssh-auth-required'
      return 0
    }

    attempt_ssh_access_bootstrap() {
      status_begin 'Configuring SSH access...'
      status_tick 'Configuring SSH access...'
      status_end 'SSH access configured.'
      return 0
    }

    VM_MACHINE_NAME='RepairVM'
    VM_IP='192.168.64.2'
    VM_USER='repair-user'
    VM_USER_PATH='/Users/repair-user'
    VM_HOST='repair-user@192.168.64.2'

    ensure_vm_connectivity_or_repair || true
  } 2>&1)"

  normalized_output="$(printf '%s' "$output" | perl -0pe 's/\\033\[[0-9;?]*[A-Za-z]//g; s/\e\[[0-9;?]*[A-Za-z]//g; s/\r[^\n]*//g')"

  assert_not_contains 'startup recovery flow does not duplicate the bounded network timeout line' "$normalized_output" $'VM network was not detected within the expected time window.\nVM network was not detected within the expected time window.'
  assert_contains 'startup recovery flow offers retry network detection' "$normalized_output" '1) Retry VM network detection'
  assert_contains 'startup recovery flow offers manual ip replacement' "$normalized_output" '2) Enter a different IP address'
  assert_contains 'startup recovery flow offers vm ip discovery' "$normalized_output" '3) Attempt VM IP discovery'
  assert_contains 'startup recovery flow offers continue waiting' "$normalized_output" '4) Continue waiting'
  assert_contains 'startup recovery flow offers abort setup' "$normalized_output" '5) Abort setup'
}

test_vm_ip_discovery_recovery_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'y'

    VM_MACHINE_NAME='RepairVM'
    VM_IP='192.168.64.7'
    VM_USER='repair-user'
    VM_USER_PATH='/Users/repair-user'
    VM_HOST='repair-user@192.168.64.7'
    FIREWALL_SHARED_SUBNET='192.168.64.0/24'

    probe_vm_ssh_endpoint() {
      REPLY='unreachable'
      return 0
    }

    discover_vm_ip_candidates() {
      REPLY='192.168.64.6'
      return 0
    }

    write_env_from_template() { :; }
    source_env_file() { :; }

    offer_vm_ip_recovery || true
  } 2>&1)"

  assert_contains 'vm ip recovery flow reports unreachable current vm ip address' "$output" 'The current VM IP address (192.168.64.7) was unreachable.'
  assert_contains 'vm ip recovery flow reports discovery progress' "$output" 'Attempting VM IP discovery...'
  assert_contains 'vm ip recovery flow reports discovery completion' "$output" 'VM IP discovery completed.'
  assert_contains 'vm ip recovery flow reports the detected likely vm address' "$output" 'Detected likely VM address: 192.168.64.6'
}

test_detect_vm_state() {
  local state

  load_setup_functions

  ssh_check() {
    return 0
  }

  setup_vm_is_running() {
    return 1
  }

  VM_RECENTLY_STARTED=false
  detect_vm_state
  state="$REPLY"
  if [ "$state" = 'ready' ]; then
    pass 'vm state detects ready when ssh works'
  else
    fail 'vm state should detect ready when ssh works'
  fi

  ssh_check() {
    return 1
  }

  setup_vm_is_running() {
    return 1
  }

  VM_RECENTLY_STARTED=false
  detect_vm_state
  state="$REPLY"
  if [ "$state" = 'stopped' ]; then
    pass 'vm state detects stopped when vm is not running'
  else
    fail 'vm state should detect stopped when vm is not running'
  fi

  setup_vm_is_running() {
    return 0
  }

  VM_RECENTLY_STARTED=true
  detect_vm_state
  state="$REPLY"
  if [ "$state" = 'booting' ]; then
    pass 'vm state detects booting after a recent start'
  else
    fail 'vm state should detect booting after a recent start'
  fi

  VM_RECENTLY_STARTED=false
  detect_vm_state
  state="$REPLY"
  if [ "$state" = 'running-no-ssh' ]; then
    pass 'vm state detects running without ssh'
  else
    fail 'vm state should detect running without ssh'
  fi
}

test_provisioning_and_deployment_flow() {
  local output

  output="$({
    load_setup_functions

    user_has_sudo() {
      return 1
    }

    detect_existing_llama_install_mode() {
      REPLY=''
      return 1
    }

    select_requested_llama_install_mode() {
      REPLY='user'
      return 0
    }

    setup_user_llama_service() {
      step 'Configured llama-server for this user'
    }

    ensure_vm_connectivity_or_repair() {
      return 0
    }

    detect_openclaw_runtime_state() {
      NEEDS_PROVISIONING=false
      IS_RUNNING=false
    }

    generate_openclaw_config() {
      step 'Generating OpenClaw config...'
    }

    sync_openclaw_config() {
      out 'Uploading config...'
    }

    ensure_vm_provision_script() {
      out 'Finalizing...'
    }

    exit_if_openclaw_not_installed() {
      return 0
    }

    setup_launchagent() {
      out 'LaunchAgent installed.'
    }

    handle_openclaw_runtime_state() {
      warn 'OpenClaw is installed but not running.'
      out 'Start with: openclaw gateway'
    }

    MODEL_PATH='/tmp/model.gguf'
    LLAMA_PORT='11434'

    run_provisioning_and_deployment
  } 2>&1)"

  assert_contains 'provisioning flow shows host inference section' "$output" ' > Host Inference Service'
  assert_contains 'provisioning flow shows vm onboarding section' "$output" ' > VM Onboarding'
  assert_contains 'provisioning flow shows openclaw section' "$output" ' > OpenClaw Configuration'
  assert_contains 'provisioning flow shows deployment section' "$output" ' > Deployment'
  assert_contains 'provisioning flow shows runtime section' "$output" ' > Runtime'
  assert_contains 'provisioning flow shows config generation step' "$output" 'Generating OpenClaw config...'
  assert_contains 'provisioning flow shows runtime callout' "$output" 'OpenClaw is installed but not running.'
  assert_no_excessive_blank_lines 'provisioning flow avoids excessive blank lines' "$output"
}

test_provisioning_and_deployment_continues_after_vm_local_provisioning() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs
    # Confirm VM-local provisioning, then explicitly decline the optional
    # interactive onboarding action. This fixture must never contact a VM.
    queue_prompt_answers 'y' 'n'

    detect_calls=0
    vm_control_calls=0

    ssh() {
      vm_control_calls=$((vm_control_calls + 1))
      printf 'UNEXPECTED_VM_CONTROL:ssh\n'
      return 1
    }

    scp() {
      vm_control_calls=$((vm_control_calls + 1))
      printf 'UNEXPECTED_VM_CONTROL:scp\n'
      return 1
    }

    utmctl() {
      vm_control_calls=$((vm_control_calls + 1))
      printf 'UNEXPECTED_VM_CONTROL:utmctl\n'
      return 1
    }

    osascript() {
      vm_control_calls=$((vm_control_calls + 1))
      printf 'UNEXPECTED_VM_CONTROL:osascript\n'
      return 1
    }

    open() {
      vm_control_calls=$((vm_control_calls + 1))
      printf 'UNEXPECTED_VM_CONTROL:open\n'
      return 1
    }

    user_has_sudo() {
      return 1
    }

    detect_existing_llama_install_mode() {
      REPLY=''
      return 1
    }

    select_requested_llama_install_mode() {
      REPLY='user'
      return 0
    }

    setup_user_llama_service() {
      step 'Configured llama-server for this user'
    }

    ensure_vm_connectivity_or_repair() {
      return 0
    }

    detect_openclaw_runtime_state() {
      detect_calls=$((detect_calls + 1))
      if [ "$detect_calls" -eq 1 ]; then
        NEEDS_PROVISIONING=true
        IS_RUNNING=false
      else
        NEEDS_PROVISIONING=false
        IS_RUNNING=true
      fi
    }

    generate_openclaw_config() {
      step 'Generating OpenClaw config...'
    }

    sync_openclaw_config() {
      out 'Uploading config...'
    }

    ensure_vm_provision_script() {
      out 'Finalizing...'
    }

    setup_launchagent() {
      out 'LaunchAgent installed.'
    }

    handle_openclaw_runtime_state() {
      warn 'OpenClaw is installed but not running.'
      out 'Start with: openclaw gateway'
      OPENCLAW_RUNTIME_MANAGEMENT_STATE='managed by VM launchd'
    }

    resolve_vm_openclaw_bin_path() {
      REPLY='/opt/homebrew/bin/openclaw'
      return 0
    }

    VM_RUNTIME_PATH='/Users/tester/ClawBox'
    VM_HOST='tester@192.168.64.2'
    MODEL_PATH='/tmp/model.gguf'
    LLAMA_PORT='11434'

    if run_provisioning_and_deployment; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
    printf 'DETECT_CALLS:%s\n' "$detect_calls"
    printf 'VM_CONTROL_CALLS:%s\n' "$vm_control_calls"
  } 2>&1)"

  assert_contains 'provisioning fallback flow shows provisioning section' "$output" ' > VM Provisioning'
  assert_contains 'provisioning fallback flow explains openclaw is missing in vm' "$output" 'OpenClaw is not yet installed in the VM.'
  assert_contains 'provisioning fallback flow prints vm-local command banner' "$output" 'Run the following INSIDE the VM terminal:'
  assert_contains 'provisioning fallback flow prints copy-friendly one-line command' "$output" 'cd /Users/tester/ClawBox && ./vm-provision.sh'
  assert_not_contains 'provisioning fallback flow does not print the old indented cd command' "$output" '  cd /Users/tester/ClawBox'
  assert_not_contains 'provisioning fallback flow does not print the old indented provisioning command' "$output" '  ./vm-provision.sh'
  assert_not_contains 'provisioning fallback flow does not repeat a copy paste command label' "$output" 'Copy/paste command:'
  assert_contains 'provisioning handoff prompts for vm-local completion' "$output" 'Provisioning completed inside the VM? [Y/n]:'
  assert_contains 'provisioning handoff continues into runtime setup after confirmation' "$output" ' > Runtime'
  assert_contains 'provisioning handoff configures the host runtime service after confirmation' "$output" 'LaunchAgent installed.'
  assert_contains 'provisioning handoff prints final setup completion section' "$output" ' > Setup Complete'
  assert_contains 'provisioning handoff points the user at status' "$output" 'Check status with: ./clawbox status'
  assert_contains 'provisioning handoff confirms the running OpenClaw gateway' "$output" 'OpenClaw gateway is running in the VM.'
  assert_contains 'provisioning handoff provides the VM login-shell OpenClaw CLI command' "$output" "Get started with: ssh tester@192.168.64.2 'zsh -lc \"openclaw --help\"'"
  assert_contains 'provisioning handoff refreshes runtime state before continuing' "$output" 'DETECT_CALLS:2'
  assert_contains 'provisioning handoff completes without a second setup run' "$output" 'STATUS:0'
  assert_contains 'provisioning handoff does not invoke VM control commands' "$output" 'VM_CONTROL_CALLS:0'
  assert_not_contains 'provisioning handoff does not invoke a VM control command' "$output" 'UNEXPECTED_VM_CONTROL:'
  assert_not_contains 'provisioning fallback flow does not offer remote provisioning prompt' "$output" 'Proceed with VM provisioning? [Y/n]:'
  assert_not_contains 'provisioning fallback flow does not execute remote provisioning output' "$output" 'OpenClaw ready: /opt/homebrew/bin/openclaw'
  assert_not_contains 'provisioning handoff does not require a second setup run after confirmation' "$output" 'Then re-run ./clawbox setup on the host.'
}

test_provisioning_and_deployment_exits_when_vm_local_provisioning_is_incomplete() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs
    queue_prompt_answers 'n'

    setup_host_inference_service_phase() {
      return 0
    }

    ensure_vm_connectivity_or_repair() {
      return 0
    }

    detect_openclaw_runtime_state() {
      NEEDS_PROVISIONING=true
      IS_RUNNING=false
    }

    generate_openclaw_config() {
      return 0
    }

    sync_openclaw_config() {
      return 0
    }

    ensure_vm_provision_script() {
      return 0
    }

    setup_launchagent() {
      out 'UNEXPECTED RUNTIME SETUP'
    }

    handle_openclaw_runtime_state() {
      out 'UNEXPECTED RUNTIME HANDLER'
    }

    VM_RUNTIME_PATH='/Users/tester/ClawBox'

    if run_provisioning_and_deployment; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
  } 2>&1)"

  assert_contains 'incomplete provisioning prints the exact host resume command' "$output" '  ./clawbox setup'
  assert_contains 'incomplete provisioning exits gracefully' "$output" 'STATUS:42'
  assert_not_contains 'runtime setup is not attempted before provisioning confirmation' "$output" 'UNEXPECTED RUNTIME SETUP'
  assert_not_contains 'runtime handling is not attempted before provisioning confirmation' "$output" 'UNEXPECTED RUNTIME HANDLER'
  assert_not_contains 'incomplete provisioning does not enter the runtime phase' "$output" ' > Runtime'
}

test_runtime_service_existing_menu_wording() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    local temp_home="$TEMP_DIR/runtime-service-home"

    mkdir -p "$temp_home/Library/LaunchAgents"
    mkdir -p "$temp_home/Library/Application Support/ClawBox/bin"
    : > "$temp_home/Library/LaunchAgents/com.clawbox.startutmvm.plist"
    : > "$temp_home/Library/Application Support/ClawBox/bin/start-utm-vm.sh"
    chmod +x "$temp_home/Library/Application Support/ClawBox/bin/start-utm-vm.sh"

    HOME="$temp_home"
    VM_MACHINE_NAME='ClawVM'
    VM_HOST='tester@192.168.64.2'

    queue_prompt_answers '4'

    launchctl() {
      return 1
    }

    setup_launchagent
  } 2>&1)"

  assert_contains 'runtime service menu shows option one as keeping the managed service' "$output" '1) Keep and use the existing runtime service (recommended)'
  assert_contains 'runtime service menu shows option two as reinstalling service' "$output" '2) Reinstall/update runtime service'
  assert_contains 'runtime service menu shows option three as removing service' "$output" '3) Disable/remove runtime service'
  assert_contains 'runtime service menu shows option four as skipping management' "$output" '4) Skip runtime service management during setup'
}

test_host_llama_restart_uses_install_mode_without_hidden_health_wait() {
  local restart_output reuse_output failure_output

  restart_output="$({
    load_setup_functions
    LLAMA_USE_EXISTING_INSTANCE=false
    LLAMA_SERVICE_CHANGED=false
    MODEL_PATH='/tmp/model.gguf'
    LLAMA_PORT='11434'
    detect_existing_llama_install_mode() { REPLY='user'; return 0; }
    llama_api_responding() { return 1; }
    llama_verify_service_health() { printf 'UNEXPECTED_HIDDEN_HEALTH_WAIT\n'; return 1; }
    setup_user_llama_service() { LLAMA_SERVICE_CHANGED=true; printf 'USER_SERVICE_RESTARTED\n'; return 0; }
    setup_host_inference_service_phase
    printf 'STATUS:%s CHANGED:%s\n' "$?" "$LLAMA_SERVICE_CHANGED"
  } 2>&1)"
  assert_contains 'restart uses the detected user LaunchAgent mode' "$restart_output" 'USER_SERVICE_RESTARTED'
  assert_contains 'restart reports the host service changed state after setup succeeds' "$restart_output" 'STATUS:0 CHANGED:true'
  assert_not_contains 'restart does not enter a hidden health wait before restoring the service' "$restart_output" 'UNEXPECTED_HIDDEN_HEALTH_WAIT'

  reuse_output="$({
    load_setup_functions
    LLAMA_USE_EXISTING_INSTANCE=false
    LLAMA_SERVICE_CHANGED=false
    MODEL_PATH='/tmp/model.gguf'
    LLAMA_PORT='11434'
    detect_existing_llama_install_mode() { REPLY='user'; return 0; }
    llama_api_responding() { return 0; }
    prompt_yes_no() { REPLY='false'; }
    setup_user_llama_service() { printf 'UNEXPECTED_RECONFIGURE\n'; return 0; }
    setup_host_inference_service_phase
    printf 'STATUS:%s CHANGED:%s\n' "$?" "$LLAMA_SERVICE_CHANGED"
  } 2>&1)"
  assert_not_contains 'healthy existing service remains unchanged when reconfiguration is declined' "$reuse_output" 'UNEXPECTED_RECONFIGURE'
  assert_contains 'healthy existing service preserves the unchanged host state' "$reuse_output" 'STATUS:0 CHANGED:false'

  failure_output="$({
    load_setup_functions
    LLAMA_USE_EXISTING_INSTANCE=false
    LLAMA_SERVICE_CHANGED=false
    MODEL_PATH='/tmp/model.gguf'
    LLAMA_PORT='11434'
    detect_existing_llama_install_mode() { REPLY='user'; return 0; }
    llama_api_responding() { return 1; }
    setup_user_llama_service() { return 1; }
    llama_show_recent_error_log() { printf 'HOST_LOG_GUIDANCE:%s\n' "$1"; }
    ensure_vm_connectivity_or_repair() { printf 'UNEXPECTED_VM_FLOW\n'; return 0; }
    offer_openclaw_restart_after_llama_update() { printf 'UNEXPECTED_OPENCLAW_RECOVERY\n'; return 0; }
    if run_provisioning_and_deployment; then
      printf 'STATUS:0\n'
    else
      printf 'STATUS:%s\n' "$?"
    fi
  } 2>&1)"
  assert_contains 'failed host restart reports recovery guidance' "$failure_output" 'Host llama-server was not restored.'
  assert_contains 'failed host restart reports the selected service log' "$failure_output" 'HOST_LOG_GUIDANCE:user'
  assert_contains 'failed host restart returns failure instead of continuing' "$failure_output" 'STATUS:1'
  assert_not_contains 'failed host restart does not continue into VM setup' "$failure_output" 'UNEXPECTED_VM_FLOW'
  assert_not_contains 'failed host restart does not continue into OpenClaw recovery' "$failure_output" 'UNEXPECTED_OPENCLAW_RECOVERY'
}

test_optional_embeddings_setup_is_host_only() {
  local disabled_output enabled_output

  disabled_output="$({
    load_setup_functions
    EMBEDDINGS_ENABLED=''
    prompt_yes_no() { REPLY='false'; }
    write_env_from_template() { printf 'ENV_WRITTEN:%s\n' "$EMBEDDINGS_ENABLED"; }
    source_env_file() { return 0; }
    setup_embeddings_llama_service_for_mode() { printf 'UNEXPECTED_EMBEDDINGS_SERVICE\n'; }
    setup_embeddings_service_phase
  } 2>&1)"
  assert_contains 'declining embeddings persists disabled state' "$disabled_output" 'ENV_WRITTEN:false'
  assert_not_contains 'declining embeddings does not start a service' "$disabled_output" 'UNEXPECTED_EMBEDDINGS_SERVICE'

  enabled_output="$({
    load_setup_functions
    HOST_IP='192.168.64.1'
    LLAMA_BIN='/tmp/llama-server'
    LLAMA_PORT='11434'
    EMBEDDINGS_ENABLED=false
    prompt_yes_no() { REPLY='true'; }
    select_embeddings_model_path() { EMBEDDINGS_MODEL_PATH='/tmp/embeddings.gguf'; }
    configured_or_default() { REPLY="$3"; }
    prompt_with_default() { REPLY="$2"; }
    llama_port_in_use() { return 1; }
    write_env_from_template() { printf 'EMBEDDINGS_ENV:%s:%s:%s\n' "$EMBEDDINGS_ENABLED" "$EMBEDDINGS_MODEL_PATH" "$EMBEDDINGS_LLAMA_PORT"; }
    source_env_file() { return 0; }
    detect_existing_llama_install_mode() { REPLY='user'; }
    setup_embeddings_llama_service_for_mode() { printf 'EMBEDDINGS_SERVICE:%s\n' "$1"; }
    setup_embeddings_service_phase
  } 2>&1)"
  assert_contains 'accepting embeddings writes independent embeddings config' "$enabled_output" 'EMBEDDINGS_ENV:true:/tmp/embeddings.gguf:11435'
  assert_contains 'accepting embeddings starts the user service with a separate profile' "$enabled_output" 'EMBEDDINGS_SERVICE:user'
  assert_not_contains 'embeddings setup does not invoke VM deployment' "$enabled_output" 'Deploying to VM'
}

test_dev_forced_vm_inference_failure_is_limited_to_recovery_probe() {
  local normal_probe_output persisted_value_output forced_probe_output decline_output restart_output unchanged_output status_source

  normal_probe_output="$({
    unset CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE
    load_setup_functions
    LLAMA_BASE_URL='http://192.168.64.1:11434/v1'
    ssh_check_zsh() { printf 'REAL_VM_PROBE:%s\n' "$1"; return 0; }
    if vm_llama_inference_available; then
      printf 'STATUS:0\n'
    else
      printf 'STATUS:1\n'
    fi
  } 2>&1)"
  assert_contains 'unset dev override uses the normal VM inference probe' "$normal_probe_output" 'REAL_VM_PROBE:'
  assert_contains 'unset dev override preserves successful VM inference' "$normal_probe_output" 'STATUS:0'

  persisted_value_output="$({
    unset CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE
    load_setup_functions
    # Simulate an unsupported .env assignment after setup captured process env.
    CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE=true
    LLAMA_BASE_URL='http://192.168.64.1:11434/v1'
    ssh_check_zsh() { printf 'REAL_VM_PROBE:%s\n' "$1"; return 0; }
    if vm_llama_inference_available; then
      printf 'STATUS:0\n'
    else
      printf 'STATUS:1\n'
    fi
  } 2>&1)"
  assert_contains 'dev override ignores values introduced after process capture' "$persisted_value_output" 'REAL_VM_PROBE:'
  assert_contains 'dev override cannot be enabled by a persisted env assignment' "$persisted_value_output" 'STATUS:0'

  forced_probe_output="$({
    CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE=true
    load_setup_functions
    LLAMA_BASE_URL='http://192.168.64.1:11434/v1'
    ssh_check_zsh() { printf 'UNEXPECTED_VM_PROBE\n'; return 0; }
    if vm_llama_inference_available; then
      printf 'STATUS:0\n'
    else
      printf 'STATUS:1\n'
    fi
  } 2>&1)"
  assert_contains 'dev override forces only the recovery inference result to fail' "$forced_probe_output" 'STATUS:1'
  assert_not_contains 'dev override does not perform the VM inference request' "$forced_probe_output" 'UNEXPECTED_VM_PROBE'

  decline_output="$({
    CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE=true
    load_setup_functions
    LLAMA_SERVICE_CHANGED=true
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    VM_HOST='tester@vm.example'
    VM_RUNTIME_PATH='/Users/tester/ClawBox'
    openclaw_runtime_has_running_gateway_service() { return 0; }
    ssh_check_zsh() { printf 'UNEXPECTED_VM_PROBE\n'; return 0; }
    prompt_yes_no() { printf '%s\n' "$1"; REPLY='false'; }
    restart_clawbox_managed_openclaw_gateway() { printf 'UNEXPECTED_RESTART\n'; return 0; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_contains 'dev override offers the normal default-no recovery prompt' "$decline_output" 'Restart the VM OpenClaw gateway now?'
  assert_not_contains 'dev override default-no path does not restart OpenClaw' "$decline_output" 'UNEXPECTED_RESTART'
  assert_not_contains 'dev override recovery decision does not change VM SSH behavior' "$decline_output" 'UNEXPECTED_VM_PROBE'

  restart_output="$({
    CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE=true
    load_setup_functions
    LLAMA_SERVICE_CHANGED=true
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    openclaw_runtime_has_running_gateway_service() { return 0; }
    prompt_yes_no() { REPLY='true'; }
    restart_clawbox_managed_openclaw_gateway() { printf 'MANAGED_RESTART_VERIFIED\n'; return 0; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_contains 'dev override yes path uses the managed restart verification path' "$restart_output" 'MANAGED_RESTART_VERIFIED'
  assert_contains 'dev override yes path reports success only after managed verification' "$restart_output" 'VM OpenClaw gateway restarted and is running.'

  unchanged_output="$({
    CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE=true
    load_setup_functions
    LLAMA_SERVICE_CHANGED=false
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    openclaw_runtime_has_running_gateway_service() { printf 'UNEXPECTED_GATEWAY_CHECK\n'; return 0; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_not_contains 'dev override does not prompt when host llama was reused' "$unchanged_output" 'UNEXPECTED_GATEWAY_CHECK'
  assert_not_contains 'dev override does not prompt when host llama was reused' "$unchanged_output" 'Restart the VM OpenClaw gateway now?'

  status_source="$(cat "$ROOT_DIR/scripts/status.sh")"
  assert_not_contains 'dev override does not affect status checks' "$status_source" 'CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE'
}

test_openclaw_restart_recovery_is_limited_to_failed_post_update_inference() {
  local reused_output success_output unavailable_output ssh_unavailable_output

  reused_output="$({
    load_setup_functions
    LLAMA_SERVICE_CHANGED=false
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    openclaw_runtime_has_running_gateway_service() { printf 'UNEXPECTED_GATEWAY_CHECK\n'; return 0; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_not_contains 'reused llama does not check or prompt for gateway restart' "$reused_output" 'UNEXPECTED_GATEWAY_CHECK'
  assert_not_contains 'reused llama does not prompt for gateway restart' "$reused_output" 'Restart the VM OpenClaw gateway now?'

  success_output="$({
    load_setup_functions
    LLAMA_SERVICE_CHANGED=true
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    openclaw_runtime_has_running_gateway_service() { return 0; }
    vm_llama_inference_available() { return 0; }
    prompt_yes_no() { printf 'UNEXPECTED_PROMPT\n'; REPLY='false'; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_not_contains 'healthy VM inference does not prompt for gateway restart' "$success_output" 'UNEXPECTED_PROMPT'

  unavailable_output="$({
    load_setup_functions
    LLAMA_SERVICE_CHANGED=true
    NEEDS_PROVISIONING=true
    IS_RUNNING=false
    openclaw_runtime_has_running_gateway_service() { printf 'UNEXPECTED_GATEWAY_CHECK\n'; return 0; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_not_contains 'unprovisioned OpenClaw does not prompt for gateway restart' "$unavailable_output" 'UNEXPECTED_GATEWAY_CHECK'

  ssh_unavailable_output="$({
    load_setup_functions
    LLAMA_SERVICE_CHANGED=true
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    openclaw_runtime_has_running_gateway_service() { printf 'VM_SSH_UNAVAILABLE\n'; return 1; }
    prompt_yes_no() { printf 'UNEXPECTED_PROMPT\n'; REPLY='false'; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_contains 'unavailable VM SSH is detected before the recovery prompt' "$ssh_unavailable_output" 'VM_SSH_UNAVAILABLE'
  assert_not_contains 'unavailable VM SSH does not prompt for gateway restart' "$ssh_unavailable_output" 'UNEXPECTED_PROMPT'
}

test_openclaw_restart_recovery_prompts_only_after_failed_inference() {
  local decline_output success_output failure_output restart_helper_output

  decline_output="$({
    load_setup_functions
    LLAMA_SERVICE_CHANGED=true
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    VM_HOST='tester@vm.example'
    VM_RUNTIME_PATH='/Users/tester/ClawBox'
    openclaw_runtime_has_running_gateway_service() { return 0; }
    vm_llama_inference_available() { return 1; }
    prompt_yes_no() { printf '%s\n' "$1"; REPLY='false'; }
    restart_clawbox_managed_openclaw_gateway() { printf 'UNEXPECTED_RESTART\n'; return 0; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_contains 'failed post-update inference warns before recovery prompt' "$decline_output" 'Host llama-server was restarted, but VM → host inference is failing.'
  assert_contains 'failed post-update inference offers default-no restart prompt' "$decline_output" 'Restart the VM OpenClaw gateway now?'
  assert_contains 'declined recovery prints manual launchd guidance' "$decline_output" 'com.clawbox.openclaw'
  assert_not_contains 'declined recovery does not restart OpenClaw' "$decline_output" 'UNEXPECTED_RESTART'

  success_output="$({
    load_setup_functions
    LLAMA_SERVICE_CHANGED=true
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    openclaw_runtime_has_running_gateway_service() { return 0; }
    vm_llama_inference_available() { return 1; }
    prompt_yes_no() { REPLY='true'; }
    restart_clawbox_managed_openclaw_gateway() { printf 'RESTART_VERIFIED\n'; return 0; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_contains 'accepted recovery invokes the verified managed restart path' "$success_output" 'RESTART_VERIFIED'
  assert_contains 'accepted recovery reports success only after verification' "$success_output" 'VM OpenClaw gateway restarted and is running.'

  failure_output="$({
    load_setup_functions
    LLAMA_SERVICE_CHANGED=true
    NEEDS_PROVISIONING=false
    IS_RUNNING=true
    VM_HOST='tester@vm.example'
    VM_RUNTIME_PATH='/Users/tester/ClawBox'
    openclaw_runtime_has_running_gateway_service() { return 0; }
    vm_llama_inference_available() { return 1; }
    prompt_yes_no() { REPLY='true'; }
    restart_clawbox_managed_openclaw_gateway() { return 1; }
    offer_openclaw_restart_after_llama_update
  } 2>&1)"
  assert_contains 'unverified recovery warns clearly' "$failure_output" 'did not become healthy after restart'
  assert_contains 'unverified recovery prints manual diagnostics' "$failure_output" 'openclaw.err.log'
  assert_not_contains 'unverified recovery does not report success' "$failure_output" 'restarted and is running'

  restart_helper_output="$(
    {
      load_setup_functions
      ssh_exec_zsh() { printf 'KICKSTART=%s\n' "$1"; return 0; }
      openclaw_runtime_has_running_gateway_service() { printf 'MANAGED_SERVICE_VERIFIED\n'; return 0; }
      restart_clawbox_managed_openclaw_gateway
    } 2>&1
  )"
  assert_contains 'recovery restart uses the ClawBox launchd label' "$restart_helper_output" 'com.clawbox.openclaw'
  assert_contains 'recovery restart verifies the managed launchd service' "$restart_helper_output" 'MANAGED_SERVICE_VERIFIED'
}

printf 'Running output normalization tests\n'

TEMP_DIR="$(mktemp -d)"

run_test test_model_selection_flow
run_test test_model_selection_recovery_accepts_corrected_directory_after_empty_scan
run_test test_model_selection_requires_explicit_file_path_when_directory_is_empty
run_test test_model_selection_recovery_rescans_current_directory
run_test test_ensure_env_bootstrap_auto_selects_single_model_without_selection_prompt
run_test test_first_run_bootstrap_detects_cross_user_llama_before_binary_setup
run_test test_ensure_env_bootstrap_fast_path_rewrites_env_after_prestart_port_change
run_test test_setup_preserves_explicit_external_llama_base_url
run_test test_ensure_env_bootstrap_repair_mode_skips_model_llama_and_openclaw_sections
run_test test_ensure_env_bootstrap_requires_tty_when_setup_is_needed
run_test test_vm_platform_check_without_utm_flow
run_test test_vm_platform_check_without_vms_flow
run_test test_single_detected_utm_vm_flow
run_test test_multiple_detected_utm_vms_flow
run_test test_decline_existing_vm_flow
run_test test_vm_platform_ready_existing_flow
run_test test_vm_detection_permission_block_graceful_exit_flow
run_test test_vm_detection_permission_block_manual_fallback_flow
run_test test_llama_install_flows
run_test test_vm_connectivity_repair_flow
run_test test_vm_running_without_ssh_flow
run_test test_vm_connection_setup_reports_vm_settings_completion_without_progress_spinner
run_test test_vm_connection_setup_prefers_configured_vm_ip_default
run_test test_manual_ssh_setup_uses_section_heading
run_test test_status_helper_suppresses_duplicate_noninteractive_wait_lines
run_test test_status_helper_renders_trailing_spinner_frames
run_test test_status_helper_uses_fast_spinner_cadence
run_test test_status_helper_applies_semantic_result_styling
run_test test_status_helper_restores_cursor_after_completion
run_test test_status_helper_avoids_extra_blank_lines_after_prompt
run_test test_status_helper_keeps_one_separator_after_empty_spinner_completion
run_test test_prompt_spacing_surrounds_prompts_with_single_blank_lines
run_test test_status_helper_suspends_spinner_before_long_output
run_test test_status_helper_keeps_spinner_and_final_lines_separate
run_test test_vm_startup_progress_flow
run_test test_vm_startup_network_recovery_flow
run_test test_vm_ip_discovery_recovery_flow
run_test test_detect_vm_state
run_test test_provisioning_and_deployment_flow
run_test test_provisioning_and_deployment_continues_after_vm_local_provisioning
run_test test_provisioning_and_deployment_exits_when_vm_local_provisioning_is_incomplete
run_test test_runtime_service_existing_menu_wording
run_test test_host_llama_restart_uses_install_mode_without_hidden_health_wait
run_test test_optional_embeddings_setup_is_host_only
run_test test_dev_forced_vm_inference_failure_is_limited_to_recovery_probe
run_test test_openclaw_restart_recovery_is_limited_to_failed_post_update_inference
run_test test_openclaw_restart_recovery_prompts_only_after_failed_inference
run_test test_existing_llama_instance_flow
run_test test_external_llama_instance_cannot_be_managed_flow
run_test test_cross_user_hidden_llama_instance_flow
run_test test_owned_llama_instance_can_restart_flow

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
