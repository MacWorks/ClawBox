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
    openclaw_runtime_has_manual_process() { return 1; }
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
      sync_model_openclaw_config_scope() { printf 'TARGETED_SYNC:%s\n' "$1"; }
      ssh() { printf 'SSH_UNEXPECTED\n'; }
      main primary
      printf 'FINAL:%s:%s:%s\n' "$MODEL_PATH" "$EMBEDDINGS_MODEL_PATH" "$EMBEDDINGS_ENABLED"
    }
  2>&1)"
  assert_contains 'primary subcommand updates only primary model path' "$output" 'FINAL:/models/primary-new.gguf:/models/embeddings.gguf:true'
  assert_contains 'primary subcommand restarts primary service' "$output" 'PRIMARY_SERVICE:user'
  assert_contains 'primary subcommand invokes targeted primary OpenClaw sync' "$output" 'TARGETED_SYNC:primary'
  assert_not_contains 'primary subcommand does not restart embeddings service' "$output" 'EMBEDDINGS_SERVICE_UNEXPECTED'
  assert_not_contains 'primary subcommand does not directly overwrite OpenClaw config' "$output" 'openclaw.json'
}

test_primary_model_subcommand_tolerates_optional_openclaw_sync_failure() {
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
      LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
      source_env_file() { :; }
      offer_openclaw_alias_migration() { :; }
      offer_vm_openclaw_alias_sync_if_drift() { :; }
      prompt_yes_no() { REPLY=true; }
      setup_configure_model_selection() { MODEL_PATH='/models/primary-new.gguf'; }
      write_env_from_template() { printf 'WRITE_PRIMARY:%s\n' "$MODEL_PATH"; }
      detect_model_llama_mode() { REPLY=user; }
      setup_llama_service_for_mode() { printf 'PRIMARY_SERVICE:%s\n' "$1"; }
      sync_openclaw_config_targeted_only() {
        printf 'OPTIONAL_SYNC_ATTEMPT:%s\n' "$1"
        error 'OpenClaw config update failed for models.providers.clawbox.models.'
        out 'OpenClaw config was not replaced.'
        return 1
      }
      offer_targeted_openclaw_config_restart() { printf 'RESTART_PROMPT_UNEXPECTED\n'; }
      main primary
      printf 'FINAL:%s\n' "$MODEL_PATH"
    }
  2>&1)"
  assert_contains 'primary subcommand attempts optional targeted sync' "$output" 'OPTIONAL_SYNC_ATTEMPT:primary'
  assert_contains 'primary subcommand still reports switched host model' "$output" 'Host llama-server now uses primary-new.gguf.'
  assert_contains 'primary subcommand leaves host model switched after optional sync failure' "$output" 'FINAL:/models/primary-new.gguf'
  assert_contains 'primary subcommand confirms OpenClaw stable model remains configured' "$output" 'Advertised OpenClaw model: clawbox/local'
  assert_not_contains 'primary subcommand does not print raw escaped manual command' "$output" 'Run manually: openclaw config set'
  assert_not_contains 'primary subcommand does not prompt restart after failed sync' "$output" 'RESTART_PROMPT_UNEXPECTED'
}

test_primary_model_subcommand_reports_no_openclaw_changes_when_sync_has_no_drift() {
  local output
  output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary-old.gguf'
      OPENCLAW_DEFAULT_MODEL='local'
      OPENCLAW_PROVIDER_NAME='clawbox'
      LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
      source_env_file() { :; }
      offer_openclaw_alias_migration() { :; }
      offer_vm_openclaw_alias_sync_if_drift() { :; }
      prompt_yes_no() { REPLY=true; }
      setup_configure_model_selection() { MODEL_PATH='/models/primary-new.gguf'; }
      write_env_from_template() { :; }
      detect_model_llama_mode() { REPLY=user; }
      setup_llama_service_for_mode() { :; }
      sync_model_openclaw_config_scope() { CONFIG_TARGETED_NO_CHANGE=true; CONFIG_TARGETED_UPDATED=false; }
      main primary
    }
  2>&1)"
  assert_contains 'primary no-drift sync reports no OpenClaw changes' "$output" 'OpenClaw config already matched; no OpenClaw changes were made.'
  assert_not_contains 'primary no-drift sync does not imply possible changes' "$output" 'may have been synced'
  assert_not_contains 'primary no-drift sync does not claim targeted keys were synced' "$output" 'primary keys were synced'
}

test_primary_model_subcommand_reports_actual_openclaw_sync_when_updated() {
  local output
  output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary-old.gguf'
      OPENCLAW_DEFAULT_MODEL='local'
      OPENCLAW_PROVIDER_NAME='clawbox'
      LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
      source_env_file() { :; }
      offer_openclaw_alias_migration() { :; }
      offer_vm_openclaw_alias_sync_if_drift() { :; }
      prompt_yes_no() { REPLY=true; }
      setup_configure_model_selection() { MODEL_PATH='/models/primary-new.gguf'; }
      write_env_from_template() { :; }
      detect_model_llama_mode() { REPLY=user; }
      setup_llama_service_for_mode() { :; }
      sync_model_openclaw_config_scope() { CONFIG_TARGETED_UPDATED=true; CONFIG_TARGETED_NO_CHANGE=false; }
      main primary
    }
  2>&1)"
  assert_contains 'primary actual sync reports managed primary keys changed' "$output" 'OpenClaw config was not replaced; only ClawBox-managed primary keys were synced.'
  assert_not_contains 'primary actual sync does not report no-change message' "$output" 'no OpenClaw changes were made'
}

test_primary_model_switch_offers_qualification_after_successful_match() {
  local output
  output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary-old.gguf'
      LLAMA_PORT=11434
      OPENCLAW_DEFAULT_MODEL='local'
      OPENCLAW_PROVIDER_NAME='clawbox'
      prompt_count=0
      source_env_file() { :; }
      offer_openclaw_alias_migration() { :; }
      offer_vm_openclaw_alias_sync_if_drift() { :; }
      model_command_is_interactive() { return 0; }
      prompt_yes_no() {
        prompt_count=$((prompt_count + 1))
        printf 'PROMPT:%s\n' "$1"
        if [ "$prompt_count" -eq 1 ]; then REPLY=true; else REPLY=false; fi
      }
      prompt_with_suffix() {
        prompt_count=$((prompt_count + 1))
        printf 'PROMPT:%s %s\n' "$1" "$2"
        REPLY='3'
      }
      setup_configure_model_selection() { MODEL_PATH='/models/primary-new.gguf'; }
      write_env_from_template() { :; }
      detect_model_llama_mode() { REPLY=user; }
      setup_llama_service_for_mode() { printf 'PRIMARY_SERVICE:%s\n' "$1"; }
      sync_model_openclaw_config_scope() { :; }
      model_process_args_for_port() { printf '/opt/homebrew/bin/llama-server -m /models/primary-new.gguf --port %s\n' "$1"; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      main primary
      printf 'PROMPT_COUNT:%s\n' "$prompt_count"
    }
  2>&1)"
  assert_contains 'successful primary switch offers qualification menu' "$output" 'Choose qualification:'
  assert_contains 'qualification prompt is visually separated after switch output' "$output" $'Check status with: ./clawbox status\n\nChoose qualification:'
  assert_contains 'qualification menu offers fast profile' "$output" '1) Fast (reduced test set)'
  assert_contains 'qualification menu offers full profile' "$output" '2) Full (complete suite)'
  assert_contains 'qualification menu defaults to skip' "$output" 'PROMPT:Selection [1-3, default 3]'
  assert_contains 'declining qualification keeps model command successful' "$output" 'Qualification skipped. The selected model remains active.'
  assert_contains 'qualification prompt runs after switch prompt' "$output" 'PROMPT_COUNT:2'
  assert_not_contains 'declining qualification does not run suite' "$output" 'QUALIFY_UNEXPECTED'
}

test_primary_model_qualification_prompt_enter_or_no_declines() {
  local enter_output no_output
  enter_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      MODEL_PATH='/models/primary-new.gguf'
      LLAMA_PORT=11434
      model_command_is_interactive() { return 0; }
      primary_model_matches_running_model() { return 0; }
      prompt_with_suffix() { printf 'PROMPT:%s %s\n' "$1" "$2"; REPLY=''; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      offer_qualification_after_primary_model_switch
    }
  2>&1)"
  assert_contains 'qualification prompt uses default-skip suffix' "$enter_output" 'PROMPT:Selection [1-3, default 3]'
  assert_contains 'enter declines qualification' "$enter_output" 'Qualification skipped. The selected model remains active.'
  assert_not_contains 'enter decline does not run qualification' "$enter_output" 'QUALIFY_UNEXPECTED'

  no_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      MODEL_PATH='/models/primary-new.gguf'
      LLAMA_PORT=11434
      model_command_is_interactive() { return 0; }
      primary_model_matches_running_model() { return 0; }
      prompt_with_suffix() { printf 'PROMPT:%s %s\n' "$1" "$2"; REPLY='3'; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      offer_qualification_after_primary_model_switch
    }
  2>&1)"
  assert_contains 'explicit skip declines qualification' "$no_output" 'Qualification skipped. The selected model remains active.'
  assert_not_contains 'explicit skip does not run qualification' "$no_output" 'QUALIFY_UNEXPECTED'

  no_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      MODEL_PATH='/models/primary-new.gguf'
      LLAMA_PORT=11434
      model_command_is_interactive() { return 0; }
      primary_model_matches_running_model() { return 0; }
      prompt_count=0
      prompt_with_suffix() {
        prompt_count=$((prompt_count + 1))
        if [ "$prompt_count" -eq 1 ]; then REPLY='bogus'; else REPLY='3'; fi
      }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      offer_qualification_after_primary_model_switch
      printf 'PROMPT_COUNT:%s\n' "$prompt_count"
    }
  2>&1)"
  assert_contains 'invalid qualification menu input reprompts' "$no_output" 'PROMPT_COUNT:2'
  assert_not_contains 'invalid then skip does not run qualification' "$no_output" 'QUALIFY_UNEXPECTED'
}

test_primary_model_qualification_menu_invokes_selected_profile_once() {
  local output
  output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      MODEL_PATH='/models/primary-new.gguf'
      LLAMA_PORT=11434
      qualify_count=0
      model_command_is_interactive() { return 0; }
      primary_model_matches_running_model() { return 0; }
      prompt_with_suffix() { printf 'PROMPT:%s %s\n' "$1" "$2"; REPLY='1'; }
      run_qualification_suite_after_model_switch() {
        qualify_count=$((qualify_count + 1))
        printf 'QUALIFY_PROFILE:%s\n' "$1"
        return 0
      }
      offer_qualification_after_primary_model_switch
      printf 'QUALIFY_COUNT:%s\n' "$qualify_count"
    }
  2>&1)"
  assert_contains 'option 1 invokes fast qualification profile' "$output" 'QUALIFY_PROFILE:fast'
  assert_contains 'option 1 invokes qualification exactly once' "$output" 'QUALIFY_COUNT:1'

  output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      MODEL_PATH='/models/primary-new.gguf'
      LLAMA_PORT=11434
      qualify_count=0
      model_command_is_interactive() { return 0; }
      primary_model_matches_running_model() { return 0; }
      prompt_with_suffix() { printf 'PROMPT:%s %s\n' "$1" "$2"; REPLY='2'; }
      run_qualification_suite_after_model_switch() {
        qualify_count=$((qualify_count + 1))
        printf 'QUALIFY_PROFILE:%s\n' "$1"
        return 0
      }
      offer_qualification_after_primary_model_switch
      printf 'QUALIFY_COUNT:%s\n' "$qualify_count"
    }
  2>&1)"
  assert_contains 'option 2 invokes full qualification profile' "$output" 'QUALIFY_PROFILE:full'
  assert_contains 'option 2 invokes qualification exactly once' "$output" 'QUALIFY_COUNT:1'
}

test_primary_model_qualification_exit_status_composition() {
  local pass_status fail_status error_status interrupt_status

  (
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    MODEL_PATH='/models/primary-new.gguf'
    LLAMA_PORT=11434
    model_command_is_interactive() { return 0; }
    primary_model_matches_running_model() { return 0; }
    prompt_with_suffix() { REPLY=1; }
    run_qualification_suite_after_model_switch() { [ "$1" = fast ]; return 0; }
    offer_qualification_after_primary_model_switch
  ) >/dev/null 2>&1
  pass_status=$?

  (
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    MODEL_PATH='/models/primary-new.gguf'
    LLAMA_PORT=11434
    model_command_is_interactive() { return 0; }
    primary_model_matches_running_model() { return 0; }
    prompt_with_suffix() { REPLY=2; }
    run_qualification_suite_after_model_switch() { [ "$1" = full ]; return 1; }
    offer_qualification_after_primary_model_switch
  ) >/dev/null 2>&1
  fail_status=$?

  (
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    MODEL_PATH='/models/primary-new.gguf'
    LLAMA_PORT=11434
    model_command_is_interactive() { return 0; }
    primary_model_matches_running_model() { return 0; }
    prompt_with_suffix() { REPLY=1; }
    run_qualification_suite_after_model_switch() { [ "$1" = fast ]; return 2; }
    offer_qualification_after_primary_model_switch
  ) >/dev/null 2>&1
  error_status=$?

  (
    CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
    MODEL_PATH='/models/primary-new.gguf'
    LLAMA_PORT=11434
    model_command_is_interactive() { return 0; }
    primary_model_matches_running_model() { return 0; }
    prompt_with_suffix() { return 130; }
    run_qualification_suite_after_model_switch() { return 0; }
    offer_qualification_after_primary_model_switch
  ) >/dev/null 2>&1
  interrupt_status=$?

  assert_equals 'qualification PASS or WARNING preserves success' "$pass_status" '0'
  assert_equals 'qualification FAIL propagates model-failure exit status' "$fail_status" '1'
  assert_equals 'qualification ERROR propagates infrastructure exit status' "$error_status" '2'
  assert_equals 'interrupted qualification prompt returns interruption status' "$interrupt_status" '130'
}

test_primary_model_qualification_offer_is_suppressed_when_unsafe_or_unavailable() {
  local mismatch_output noninteractive_output unavailable_output

  mismatch_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      MODEL_PATH='/models/primary-new.gguf'
      LLAMA_PORT=11434
      model_command_is_interactive() { return 0; }
      primary_model_matches_running_model() { return 1; }
      prompt_yes_no() { printf 'PROMPT_UNEXPECTED\n'; REPLY=true; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      offer_qualification_after_primary_model_switch
    }
  2>&1)"
  assert_contains 'model mismatch suppresses qualification with guidance' "$mismatch_output" 'Run ./clawbox status and resolve the model inconsistency before qualifying this model.'
  assert_not_contains 'model mismatch does not prompt qualification' "$mismatch_output" 'PROMPT_UNEXPECTED'
  assert_not_contains 'model mismatch does not run qualification' "$mismatch_output" 'QUALIFY_UNEXPECTED'

  noninteractive_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      MODEL_PATH='/models/primary-new.gguf'
      LLAMA_PORT=11434
      model_command_is_interactive() { return 1; }
      primary_model_matches_running_model() { printf 'MATCH_UNEXPECTED\n'; return 0; }
      prompt_yes_no() { printf 'PROMPT_UNEXPECTED\n'; REPLY=true; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      offer_qualification_after_primary_model_switch
    }
  2>&1)"
  assert_not_contains 'noninteractive model switch does not check match solely for prompt' "$noninteractive_output" 'MATCH_UNEXPECTED'
  assert_not_contains 'noninteractive model switch does not prompt qualification' "$noninteractive_output" 'PROMPT_UNEXPECTED'
  assert_not_contains 'noninteractive model switch does not run qualification' "$noninteractive_output" 'QUALIFY_UNEXPECTED'

  unavailable_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      MODEL_PATH='/models/primary-new.gguf'
      LLAMA_PORT=11434
      model_command_is_interactive() { return 0; }
      model_qualification_available() { return 1; }
      primary_model_matches_running_model() { printf 'MATCH_UNEXPECTED\n'; return 0; }
      prompt_yes_no() { printf 'PROMPT_UNEXPECTED\n'; REPLY=true; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      offer_qualification_after_primary_model_switch
    }
  2>&1)"
  assert_not_contains 'unavailable qualification does not check match solely for prompt' "$unavailable_output" 'MATCH_UNEXPECTED'
  assert_not_contains 'unavailable qualification does not prompt' "$unavailable_output" 'PROMPT_UNEXPECTED'
  assert_not_contains 'unavailable qualification does not run' "$unavailable_output" 'QUALIFY_UNEXPECTED'
}

test_primary_model_noop_or_failed_switch_does_not_offer_qualification() {
  local cancel_output failure_output
  cancel_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary-old.gguf'
      LLAMA_PORT=11434
      source_env_file() { :; }
      offer_openclaw_alias_migration() { :; }
      offer_vm_openclaw_alias_sync_if_drift() { :; }
      model_command_is_interactive() { return 0; }
      prompt_yes_no() { REPLY=false; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      main primary
    }
  2>&1)"
  assert_contains 'canceled primary switch remains no-op' "$cancel_output" 'Model switch cancelled; host model is unchanged.'
  assert_not_contains 'canceled primary switch does not offer qualification' "$cancel_output" 'Choose qualification:'
  assert_not_contains 'canceled primary switch does not run qualification' "$cancel_output" 'QUALIFY_UNEXPECTED'

  failure_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary-old.gguf'
      LLAMA_PORT=11434
      source_env_file() { :; }
      offer_openclaw_alias_migration() { :; }
      offer_vm_openclaw_alias_sync_if_drift() { :; }
      model_command_is_interactive() { return 0; }
      prompt_yes_no() { REPLY=true; }
      setup_configure_model_selection() { MODEL_PATH='/models/primary-new.gguf'; }
      write_env_from_template() { :; }
      detect_model_llama_mode() { REPLY=user; }
      setup_llama_service_for_mode() { return 1; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      main primary
    }
  2>&1 || true)"
  assert_contains 'failed service restart reports recovery guidance' "$failure_output" 'Review the llama-server logs, correct the host service, then run ./clawbox model again.'
  assert_not_contains 'failed service restart does not offer qualification' "$failure_output" 'Choose qualification:'
  assert_not_contains 'failed service restart does not run qualification' "$failure_output" 'QUALIFY_UNEXPECTED'
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
      sync_model_openclaw_config_scope() { printf 'TARGETED_SYNC:%s:%s\n' "$1" "$(basename "$EMBEDDINGS_MODEL_PATH")"; }
      run_qualification_suite_after_model_switch() { printf 'QUALIFY_UNEXPECTED\n'; }
      ssh() { printf 'SSH_UNEXPECTED\n'; }
      main embeddings
      printf 'FINAL:%s:%s:%s:%s:%s\n' "$MODEL_PATH" "$EMBEDDINGS_MODEL_PATH" "$EMBEDDINGS_ENABLED" "$EMBEDDINGS_LLAMA_BASE_URL" "$OPENCLAW_DEFAULT_MODEL"
    }
  2>&1)"
  assert_contains 'embeddings subcommand updates only embeddings model path and endpoint' "$embeddings_output" 'FINAL:/models/primary.gguf:/models/embeddings-new.gguf:true:http://127.0.0.1:11435/v1:local'
  assert_contains 'embeddings subcommand restarts embeddings service' "$embeddings_output" 'EMBEDDINGS_SERVICE:user'
  assert_contains 'embeddings subcommand invokes targeted memorySearch sync with basename' "$embeddings_output" 'TARGETED_SYNC:memorySearch:embeddings-new.gguf'
  assert_not_contains 'embeddings subcommand does not restart primary service' "$embeddings_output" 'PRIMARY_SERVICE_UNEXPECTED'
  assert_not_contains 'embeddings subcommand does not directly overwrite OpenClaw config' "$embeddings_output" 'openclaw.json'
  assert_not_contains 'embeddings subcommand does not offer primary qualification' "$embeddings_output" 'Choose qualification:'
  assert_not_contains 'embeddings subcommand does not run qualification' "$embeddings_output" 'QUALIFY_UNEXPECTED'
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

test_embeddings_model_subcommand_reports_openclaw_no_change_or_sync_precisely() {
  local no_change_output updated_output
  no_change_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary.gguf'
      EMBEDDINGS_ENABLED=true
      EMBEDDINGS_MODEL_PATH='/models/embeddings-old.gguf'
      EMBEDDINGS_LLAMA_BASE_URL='http://127.0.0.1:11435/v1'
      source_env_file() { :; }
      prompt_yes_no() { REPLY=true; }
      select_embeddings_model_path() { EMBEDDINGS_MODEL_PATH='/models/embeddings-new.gguf'; }
      write_env_from_template() { :; }
      detect_existing_llama_install_mode() { REPLY=user; }
      setup_embeddings_llama_service_for_mode() { :; }
      sync_model_openclaw_config_scope() { CONFIG_TARGETED_NO_CHANGE=true; CONFIG_TARGETED_UPDATED=false; }
      main embeddings
    }
  2>&1)"
  assert_contains 'embeddings no-drift sync reports no OpenClaw changes' "$no_change_output" 'OpenClaw config already matched; no OpenClaw changes were made.'
  assert_not_contains 'embeddings no-drift sync does not imply possible changes' "$no_change_output" 'may have been synced'

  updated_output="$(
    {
      CLAWBOX_MODEL_LIB_ONLY=true source "$ROOT_DIR/scripts/model.sh"
      ENV_FILE="$TEMP_DIR/model.env"; : > "$ENV_FILE"
      MODEL_PATH='/models/primary.gguf'
      EMBEDDINGS_ENABLED=true
      EMBEDDINGS_MODEL_PATH='/models/embeddings-old.gguf'
      EMBEDDINGS_LLAMA_BASE_URL='http://127.0.0.1:11435/v1'
      source_env_file() { :; }
      prompt_yes_no() { REPLY=true; }
      select_embeddings_model_path() { EMBEDDINGS_MODEL_PATH='/models/embeddings-new.gguf'; }
      write_env_from_template() { :; }
      detect_existing_llama_install_mode() { REPLY=user; }
      setup_embeddings_llama_service_for_mode() { :; }
      sync_model_openclaw_config_scope() { CONFIG_TARGETED_UPDATED=true; CONFIG_TARGETED_NO_CHANGE=false; }
      main embedding
    }
  2>&1)"
  assert_contains 'embeddings actual sync reports memorySearch keys changed' "$updated_output" 'OpenClaw config was not replaced; only ClawBox-managed memorySearch keys were synced.'
  assert_not_contains 'embeddings actual sync does not report no-change message' "$updated_output" 'no OpenClaw changes were made'
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
      prompt_with_suffix() { printf 'UNEXPECTED_EXISTING_EMBEDDINGS_MENU:%s %s\n' "$1" "$2"; return 1; }
      select_embeddings_model_path() { EMBEDDINGS_MODEL_PATH='/models/embeddings.gguf'; }
      configured_or_default() { REPLY="$3"; }
      prompt_with_default() { REPLY="$2"; }
      embeddings_llama_service_loaded() { return 1; }
      llama_port_in_use() { return 1; }
      write_env_from_template() { printf 'WRITE_ENABLED:%s:%s:%s\n' "$EMBEDDINGS_ENABLED" "$MODEL_PATH" "$EMBEDDINGS_MODEL_PATH"; }
      detect_existing_llama_install_mode() { REPLY=user; }
      setup_embeddings_llama_service_for_mode() { printf 'EMBEDDINGS_SERVICE:%s\n' "$1"; }
      setup_llama_service_for_mode() { printf 'PRIMARY_SERVICE_UNEXPECTED\n'; }
      sync_model_openclaw_config_scope() { printf 'TARGETED_SYNC:%s:%s\n' "$1" "$(basename "$EMBEDDINGS_MODEL_PATH")"; }
      ssh() { printf 'SSH_UNEXPECTED\n'; }
      main embeddings
    }
  2>&1)"
  assert_contains 'disabled embeddings subcommand enables embeddings only' "$output" 'WRITE_ENABLED:true:/models/primary.gguf:/models/embeddings.gguf'
  assert_contains 'disabled embeddings subcommand starts embeddings service' "$output" 'EMBEDDINGS_SERVICE:user'
  assert_contains 'disabled embeddings subcommand syncs memorySearch after enabling' "$output" 'TARGETED_SYNC:memorySearch:embeddings.gguf'
  assert_not_contains 'disabled embeddings subcommand does not restart primary service' "$output" 'PRIMARY_SERVICE_UNEXPECTED'
  assert_not_contains 'disabled embeddings subcommand does not directly overwrite OpenClaw config' "$output" 'openclaw.json'
}

test_model_targeted_sync_scopes_are_narrow() {
  local primary_entries memory_entries
  primary_entries="$({
    . "$ROOT_DIR/lib/deploy.sh"
    OPENCLAW_PROVIDER_NAME='clawbox'
    OPENCLAW_DEFAULT_MODEL='local'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    LLAMA_CTX=32768
    EMBEDDINGS_ENABLED=true
    EMBEDDINGS_MODEL_PATH='/models/embed.gguf'
    EMBEDDINGS_LLAMA_BASE_URL='http://127.0.0.1:11435/v1'
    openclaw_config_desired_entries_for_scope primary
  })"
  memory_entries="$({
    . "$ROOT_DIR/lib/deploy.sh"
    OPENCLAW_PROVIDER_NAME='clawbox'
    OPENCLAW_DEFAULT_MODEL='local'
    LLAMA_BASE_URL='http://127.0.0.1:11434/v1'
    EMBEDDINGS_ENABLED=true
    EMBEDDINGS_MODEL_PATH='/models/embed.gguf'
    EMBEDDINGS_LLAMA_BASE_URL='http://127.0.0.1:11435/v1'
    openclaw_config_desired_entries_for_scope memorySearch
  })"
  assert_contains 'primary targeted sync includes default model primary key' "$primary_entries" 'agents.defaults.model.primary'
  assert_contains 'primary targeted sync includes provider models' "$primary_entries" 'models.providers.clawbox.models'
  assert_not_contains 'primary targeted sync excludes memorySearch keys' "$primary_entries" 'memorySearch'
  assert_contains 'embeddings targeted sync includes memorySearch model basename' "$memory_entries" $'agents.defaults.memorySearch.model\tembed.gguf'
  assert_contains 'embeddings targeted sync uses ollama-local memory API marker' "$memory_entries" $'agents.defaults.memorySearch.remote.apiKey\tollama-local'
  assert_not_contains 'embeddings targeted sync excludes primary model key' "$memory_entries" 'agents.defaults.model.primary'
  assert_not_contains 'embeddings targeted sync excludes primary provider keys' "$memory_entries" 'models.providers.clawbox'
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
run_test test_primary_model_subcommand_tolerates_optional_openclaw_sync_failure
run_test test_primary_model_subcommand_reports_no_openclaw_changes_when_sync_has_no_drift
run_test test_primary_model_subcommand_reports_actual_openclaw_sync_when_updated
run_test test_primary_model_switch_offers_qualification_after_successful_match
run_test test_primary_model_qualification_prompt_enter_or_no_declines
run_test test_primary_model_qualification_menu_invokes_selected_profile_once
run_test test_primary_model_qualification_exit_status_composition
run_test test_primary_model_qualification_offer_is_suppressed_when_unsafe_or_unavailable
run_test test_primary_model_noop_or_failed_switch_does_not_offer_qualification
run_test test_embeddings_model_subcommands_are_isolated
run_test test_embeddings_model_subcommand_reports_openclaw_no_change_or_sync_precisely
run_test test_embeddings_model_subcommand_can_enable_disabled_embeddings
run_test test_model_targeted_sync_scopes_are_narrow
run_test test_default_model_flow_explicitly_selects_one_instance

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi
printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
