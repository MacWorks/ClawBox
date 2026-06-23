#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/helpers/setup-harness.sh"
TEMP_DIR="$(mktemp -d)"
trap cleanup_temp_dir EXIT

test_legacy_alias_migration_defaults_to_no() {
  local output
  output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    OPENCLAW_PROVIDER_NAME='clawbox'
    OPENCLAW_DEFAULT_MODEL='legacy-model'
    prompt_yes_no() { REPLY='false'; }
    write_env_from_template() { printf 'WRITE\n'; }
    source_env_file() { :; }
    offer_openclaw_alias_migration
    printf 'ALIAS:%s\n' "$OPENCLAW_DEFAULT_MODEL"
  } 2>&1)"
  assert_contains 'legacy alias migration shows the current alias' "$output" 'clawbox/legacy-model'
  assert_contains 'legacy alias migration shows the stable recommendation' "$output" 'clawbox/local'
  assert_contains 'legacy alias migration default no preserves the alias' "$output" 'ALIAS:legacy-model'
  assert_not_contains 'legacy alias migration default no does not write env' "$output" 'WRITE'
}

test_legacy_alias_migration_updates_only_local_env_state() {
  local output
  output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    OPENCLAW_PROVIDER_NAME='custom'
    OPENCLAW_DEFAULT_MODEL='legacy-model'
    VM_HOST='tester@vm.example'
    prompt_count=0
    prompt_yes_no() {
      prompt_count=$((prompt_count + 1))
      if [ "$prompt_count" -eq 1 ]; then REPLY='true'; else REPLY='false'; fi
    }
    write_env_from_template() { printf 'WRITE:%s\n' "$OPENCLAW_DEFAULT_MODEL"; }
    source_env_file() { :; }
    ssh() { printf 'SSH_UNEXPECTED\n'; return 1; }
    offer_openclaw_alias_migration
    printf 'ALIAS:%s\n' "$OPENCLAW_DEFAULT_MODEL"
  } 2>&1)"
  assert_contains 'legacy alias migration writes local alias' "$output" 'WRITE:local'
  assert_contains 'legacy alias migration preserves custom provider support' "$output" 'custom/local'
  assert_contains 'legacy alias migration updates alias in memory' "$output" 'ALIAS:local'
  assert_not_contains 'legacy alias migration does not contact VM' "$output" 'SSH_UNEXPECTED'
  assert_contains 'legacy alias migration warns when VM sync is declined' "$output" 'OpenClaw may continue using the old alias'
}

test_legacy_alias_migration_can_target_vm_default_only() {
  local output
  output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    OPENCLAW_PROVIDER_NAME='clawbox'
    OPENCLAW_DEFAULT_MODEL='legacy-model'
    VM_HOST='tester@vm.example'
    prompt_count=0
    prompt_yes_no() { prompt_count=$((prompt_count + 1)); printf '%s\n' "$1"; REPLY='true'; }
    write_env_from_template() { :; }
    source_env_file() { :; }
    openclaw_runtime_has_launchd_gateway() { return 0; }
    ssh() {
      printf 'SSH:%s\n' "$*" >&2
      if [[ "$*" == *get* ]]; then
        printf 'clawbox/local\n'
      fi
    }
    offer_openclaw_alias_migration
  } 2>&1)"
  assert_contains 'VM alias sync invokes the targeted config command' "$output" 'SSH:tester@vm.example'
  assert_contains 'VM alias sync validates the targeted config field' "$output" 'SSH:tester@vm.example'
  assert_not_contains 'VM alias sync does not use full config deployment' "$output" 'openclaw.json'
  assert_contains 'VM alias sync reports narrow field update' "$output" 'Only agents.defaults.model.primary was updated'
  assert_contains 'VM alias sync offers gateway restart' "$output" 'Restart the VM OpenClaw gateway now to apply this change?'
}

test_vm_openclaw_restart_decline_and_failure_are_recoverable() {
  local decline_output failure_output
  decline_output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    VM_HOST='jimmy@192.168.64.8'
    prompt_yes_no() { REPLY='false'; }
    offer_vm_openclaw_gateway_restart
  } 2>&1)"
  assert_contains 'VM restart decline prints manual target command' "$decline_output" 'ssh jimmy@192.168.64.8'
  assert_contains 'VM restart decline prints launchd kickstart command' "$decline_output" 'com.clawbox.openclaw'

  failure_output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    VM_HOST='jimmy@192.168.64.8'
    prompt_yes_no() { REPLY='true'; }
    ssh() { return 1; }
    offer_vm_openclaw_gateway_restart
  } 2>&1)"
  assert_contains 'VM restart failure prints recovery warning' "$failure_output" 'VM OpenClaw gateway restart failed.'
  assert_contains 'VM restart failure prints manual command' "$failure_output" 'ssh jimmy@192.168.64.8'
}

test_vm_openclaw_restart_requires_runtime_verification() {
  local healthy_output unhealthy_output
  healthy_output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    VM_HOST='jimmy@192.168.64.8'
    VM_RUNTIME_PATH='/Users/jimmy/ClawBox'
    prompt_yes_no() { REPLY='true'; }
    ssh() { return 0; }
    openclaw_runtime_has_launchd_gateway() { return 0; }
    offer_vm_openclaw_gateway_restart
  } 2>&1)"
  assert_contains 'verified VM restart reports success' "$healthy_output" 'VM OpenClaw gateway restarted and is running.'

  unhealthy_output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    VM_HOST='jimmy@192.168.64.8'
    VM_RUNTIME_PATH='/Users/jimmy/ClawBox'
    prompt_yes_no() { REPLY='true'; }
    ssh() { return 0; }
    sleep() { :; }
    openclaw_runtime_has_launchd_gateway() { return 1; }
    offer_vm_openclaw_gateway_restart
  } 2>&1)"
  assert_contains 'unverified VM restart warns clearly' "$unhealthy_output" 'did not become healthy after restart'
  assert_contains 'unverified VM restart shows diagnostics' "$unhealthy_output" 'openclaw.err.log'
  assert_not_contains 'unverified VM restart does not report success' "$unhealthy_output" 'restarted and is running'
}

test_vm_openclaw_restart_warns_for_external_gateway_owner() {
  local output
  output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    VM_HOST='jimmy@192.168.64.8'
    prompt_yes_no() { REPLY='true'; }
    openclaw_runtime_has_manual_process() { return 0; }
    ssh() { printf 'SSH_UNEXPECTED\n'; return 1; }
    offer_vm_openclaw_gateway_restart
  } 2>&1)"
  assert_contains 'external gateway owner warning is explicit' "$output" 'outside the ClawBox launchd service'
  assert_contains 'external gateway owner shows native stop command' "$output" 'openclaw gateway stop'
  assert_contains 'external gateway owner shows native launchd bootout command' "$output" 'ai.openclaw.gateway'
  assert_not_contains 'external gateway owner is not restarted automatically' "$output" 'SSH_UNEXPECTED'
  assert_not_contains 'external gateway owner does not report success' "$output" 'restarted and is running'
}

test_local_alias_detects_vm_drift_and_requires_confirmation() {
  local output
  output="$({
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    OPENCLAW_PROVIDER_NAME='clawbox'
    OPENCLAW_DEFAULT_MODEL='local'
    VM_HOST='tester@vm.example'
    prompt_yes_no() { REPLY='false'; }
    ssh() { printf 'clawbox/legacy-model\n'; }
    offer_vm_openclaw_alias_sync_if_drift
  } 2>&1)"
  assert_contains 'local alias drift shows VM primary' "$output" 'clawbox/legacy-model'
  assert_contains 'local alias drift shows intended primary' "$output" 'clawbox/local'
  assert_contains 'local alias drift decline preserves VM config' "$output" 'OpenClaw may continue using the old alias'
}

test_model_help_lists_instance_subcommands() {
  local output
  output="$(bash "$ROOT_DIR/clawbox" help 2>&1)"
  assert_contains 'model help lists primary subcommand' "$output" './clawbox model primary'
  assert_contains 'model help lists embedding alias' "$output" './clawbox model embedding'
  assert_contains 'model help lists embeddings subcommand' "$output" './clawbox model embeddings'
}

test_primary_model_subcommand_preserves_embeddings_state() {
  local output
  output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary-old.gguf'
      EMBEDDINGS_ENABLED=true
      EMBEDDINGS_MODEL_PATH='/models/embeddings.gguf'
      OPENCLAW_DEFAULT_MODEL='local'
      OPENCLAW_PROVIDER_NAME='clawbox'
      source_env_file() { :; }
      offer_openclaw_alias_migration() { :; }
      offer_vm_openclaw_alias_sync_if_drift() { :; }
      prompt_yes_no() { REPLY=true; }
      setup_configure_model_selection() { MODEL_PATH='/models/primary-new.gguf'; }
      write_env_from_template() { printf 'WRITE_PRIMARY:%s:%s:%s\n' "$MODEL_PATH" "$EMBEDDINGS_MODEL_PATH" "$EMBEDDINGS_ENABLED"; }
      detect_model_llama_mode() { REPLY=user; }
      setup_llama_service_for_mode() { printf 'PRIMARY_SERVICE:%s\n' "$1"; }
      setup_embeddings_llama_service_for_mode() { printf 'EMBEDDINGS_SERVICE_UNEXPECTED\n'; }
      ssh() { printf 'SSH_UNEXPECTED\n'; }
      main primary
      printf 'FINAL:%s:%s:%s\n' "$MODEL_PATH" "$EMBEDDINGS_MODEL_PATH" "$EMBEDDINGS_ENABLED"
    }
  2>&1)"
  assert_contains 'primary subcommand updates only primary model path' "$output" 'FINAL:/models/primary-new.gguf:/models/embeddings.gguf:true'
  assert_contains 'primary subcommand restarts primary service' "$output" 'PRIMARY_SERVICE:user'
  assert_not_contains 'primary subcommand does not restart embeddings service' "$output" 'EMBEDDINGS_SERVICE_UNEXPECTED'
  assert_not_contains 'primary subcommand does not contact VM' "$output" 'SSH_UNEXPECTED'
}

test_embeddings_model_subcommands_are_isolated() {
  local embeddings_output alias_output
  embeddings_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary.gguf'
      EMBEDDINGS_ENABLED=true
      EMBEDDINGS_MODEL_PATH='/models/embeddings-old.gguf'
      EMBEDDINGS_LLAMA_BASE_URL='http://127.0.0.1:11435/v1'
      OPENCLAW_DEFAULT_MODEL='local'
      source_env_file() { :; }
      prompt_yes_no() { REPLY=true; }
      select_embeddings_model_path() { EMBEDDINGS_MODEL_PATH='/models/embeddings-new.gguf'; }
      write_env_from_template() { printf 'WRITE_EMBEDDINGS:%s:%s:%s\n' "$MODEL_PATH" "$EMBEDDINGS_MODEL_PATH" "$OPENCLAW_DEFAULT_MODEL"; }
      detect_existing_llama_install_mode() { REPLY=user; }
      setup_embeddings_llama_service_for_mode() { printf 'EMBEDDINGS_SERVICE:%s\n' "$1"; }
      setup_llama_service_for_mode() { printf 'PRIMARY_SERVICE_UNEXPECTED\n'; }
      ssh() { printf 'SSH_UNEXPECTED\n'; }
      main embeddings
      printf 'FINAL:%s:%s:%s:%s:%s\n' "$MODEL_PATH" "$EMBEDDINGS_MODEL_PATH" "$EMBEDDINGS_ENABLED" "$EMBEDDINGS_LLAMA_BASE_URL" "$OPENCLAW_DEFAULT_MODEL"
    }
  2>&1)"
  assert_contains 'embeddings subcommand updates only embeddings model path and endpoint' "$embeddings_output" 'FINAL:/models/primary.gguf:/models/embeddings-new.gguf:true:http://127.0.0.1:11435/v1:local'
  assert_contains 'embeddings subcommand restarts embeddings service' "$embeddings_output" 'EMBEDDINGS_SERVICE:user'
  assert_not_contains 'embeddings subcommand does not restart primary service' "$embeddings_output" 'PRIMARY_SERVICE_UNEXPECTED'
  assert_not_contains 'embeddings subcommand does not contact VM' "$embeddings_output" 'SSH_UNEXPECTED'
  assert_contains 'embeddings subcommand reports its existing endpoint' "$embeddings_output" 'Embeddings llama-server API: http://127.0.0.1:11435/v1'

  alias_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      source_env_file() { :; }
      switch_embeddings_model() { printf 'EMBEDDINGS_ALIAS_DISPATCH\n'; }
      switch_primary_model() { printf 'PRIMARY_UNEXPECTED\n'; }
      main embedding
    }
  2>&1)"
  assert_contains 'embedding alias dispatches to embeddings model flow' "$alias_output" 'EMBEDDINGS_ALIAS_DISPATCH'
  assert_not_contains 'embedding alias does not dispatch primary flow' "$alias_output" 'PRIMARY_UNEXPECTED'
}

test_embeddings_model_subcommand_can_enable_disabled_embeddings() {
  local output
  output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary.gguf'
      EMBEDDINGS_ENABLED=false
      EMBEDDINGS_MODEL_PATH=''
      OPENCLAW_DEFAULT_MODEL='local'
      HOST_IP='127.0.0.1'
      LLAMA_PORT=11434
      source_env_file() { :; }
      prompt_yes_no() { REPLY=true; }
      select_embeddings_model_path() { EMBEDDINGS_MODEL_PATH='/models/embeddings.gguf'; }
      configured_or_default() { REPLY="$3"; }
      prompt_with_default() { REPLY="$2"; }
      llama_port_in_use() { return 1; }
      write_env_from_template() { printf 'WRITE_ENABLED:%s:%s:%s\n' "$EMBEDDINGS_ENABLED" "$MODEL_PATH" "$EMBEDDINGS_MODEL_PATH"; }
      detect_existing_llama_install_mode() { REPLY=user; }
      setup_embeddings_llama_service_for_mode() { printf 'EMBEDDINGS_SERVICE:%s\n' "$1"; }
      setup_llama_service_for_mode() { printf 'PRIMARY_SERVICE_UNEXPECTED\n'; }
      ssh() { printf 'SSH_UNEXPECTED\n'; }
      main embeddings
    }
  2>&1)"
  assert_contains 'disabled embeddings subcommand enables embeddings only' "$output" 'WRITE_ENABLED:true:/models/primary.gguf:/models/embeddings.gguf'
  assert_contains 'disabled embeddings subcommand starts embeddings service' "$output" 'EMBEDDINGS_SERVICE:user'
  assert_not_contains 'disabled embeddings subcommand does not restart primary service' "$output" 'PRIMARY_SERVICE_UNEXPECTED'
  assert_not_contains 'disabled embeddings subcommand does not contact VM' "$output" 'SSH_UNEXPECTED'
}

test_default_model_flow_explicitly_selects_one_instance() {
  local output
  output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      source_env_file() { :; }
      prompt_with_suffix() { REPLY=2; }
      switch_primary_model() { printf 'PRIMARY_UNEXPECTED\n'; }
      switch_embeddings_model() { printf 'EMBEDDINGS_SELECTED\n'; }
      main
    }
  2>&1)"
  assert_contains 'default model flow shows separate primary option' "$output" 'Switch primary chat/inference model'
  assert_contains 'default model flow shows separate embeddings option' "$output" 'Configure or switch embeddings model'
  assert_contains 'default model flow dispatches only selected embeddings instance' "$output" 'EMBEDDINGS_SELECTED'
  assert_not_contains 'default model flow does not switch primary implicitly' "$output" 'PRIMARY_UNEXPECTED'
}

run_test test_legacy_alias_migration_defaults_to_no
run_test test_legacy_alias_migration_updates_only_local_env_state
run_test test_legacy_alias_migration_can_target_vm_default_only
run_test test_local_alias_detects_vm_drift_and_requires_confirmation
run_test test_vm_openclaw_restart_decline_and_failure_are_recoverable
run_test test_vm_openclaw_restart_requires_runtime_verification
run_test test_vm_openclaw_restart_warns_for_external_gateway_owner
run_test test_model_help_lists_instance_subcommands
run_test test_primary_model_subcommand_preserves_embeddings_state
run_test test_embeddings_model_subcommands_are_isolated
run_test test_embeddings_model_subcommand_can_enable_disabled_embeddings
run_test test_default_model_flow_explicitly_selects_one_instance

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi
printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
