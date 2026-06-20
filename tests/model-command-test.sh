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
    prompt_yes_no() { REPLY='true'; }
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
}

run_test test_legacy_alias_migration_defaults_to_no
run_test test_legacy_alias_migration_updates_only_local_env_state

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi
printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
