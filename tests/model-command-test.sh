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
    openclaw_runtime_is_active() { return 0; }
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
    openclaw_runtime_is_active() { return 0; }
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
    openclaw_runtime_is_active() { return 1; }
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

run_test test_legacy_alias_migration_defaults_to_no
run_test test_legacy_alias_migration_updates_only_local_env_state
run_test test_legacy_alias_migration_can_target_vm_default_only
run_test test_local_alias_detects_vm_drift_and_requires_confirmation
run_test test_vm_openclaw_restart_decline_and_failure_are_recoverable
run_test test_vm_openclaw_restart_requires_runtime_verification
run_test test_vm_openclaw_restart_warns_for_external_gateway_owner

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi
printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
