#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/helpers/setup-harness.sh"
TEMP_DIR="$(mktemp -d)"
trap cleanup_temp_dir EXIT

test_root_help_lists_context_command() {
  local output
  output="$(bash "$ROOT_DIR/clawbox" help 2>&1)"
  assert_contains 'root help lists context command' "$output" 'context     Show or change primary model context size'
  assert_contains 'root help shows interactive context example' "$output" './clawbox context'
  assert_contains 'root help shows direct context example' "$output" './clawbox context 131072'
}

test_context_shared_default_and_validation_policy() {
  local output
  output="$({
    . "$ROOT_DIR/lib/output.sh"
    . "$ROOT_DIR/lib/context-runtime.sh"
    llama_context_safe_default '' '' 32768; printf 'DEFAULT_FRESH:%s\n' "$REPLY"
    llama_context_safe_default 131072 32768 32768; printf 'DEFAULT_CLAMP:%s\n' "$REPLY"
    llama_context_safe_default 32768 262144 32768; printf 'DEFAULT_PRESERVE_SMALL:%s\n' "$REPLY"
    if llama_context_validate_value 32768 65536 8192 test; then printf 'VALID_OK\n'; fi
    if ! llama_context_validate_value 0 65536 8192 test; then printf 'ZERO_REJECTED\n'; fi
    if ! llama_context_validate_value nope 65536 8192 test; then printf 'TEXT_REJECTED\n'; fi
    if ! llama_context_validate_value 131072 32768 8192 test; then printf 'ABOVE_NATIVE_REJECTED\n'; fi
    if llama_context_validate_value 131072 '' 8192 test; then printf 'UNKNOWN_NATIVE_ACCEPTED\n'; fi
    if ! llama_context_validate_value 8192 65536 8192 test; then printf 'MAX_TOKEN_REJECTED\n'; fi
  } 2>&1)"

  assert_contains 'fresh context default is 32768' "$output" 'DEFAULT_FRESH:32768'
  assert_contains 'oversized current default clamps to native' "$output" 'DEFAULT_CLAMP:32768'
  assert_contains 'smaller existing context remains default for larger model' "$output" 'DEFAULT_PRESERVE_SMALL:32768'
  assert_contains 'positive context below native validates' "$output" 'VALID_OK'
  assert_contains 'zero context is rejected' "$output" 'ZERO_REJECTED'
  assert_contains 'nonnumeric context is rejected' "$output" 'TEXT_REJECTED'
  assert_contains 'above-native context is rejected' "$output" 'ABOVE_NATIVE_REJECTED'
  assert_contains 'unknown native allows positive integer context' "$output" 'UNKNOWN_NATIVE_ACCEPTED'
  assert_contains 'maxTokens must be lower than context' "$output" 'MAX_TOKEN_REJECTED'
}

test_context_direct_update_applies_env_runtime_and_openclaw() {
  local output
  output="$({
    CLAWBOX_CONTEXT_LIB_ONLY=true source "$ROOT_DIR/scripts/context.sh"
    ENV_FILE="$TEMP_DIR/context.env"; : > "$ENV_FILE"
    MODEL_PATH='/models/Bonsai.gguf'
    LLAMA_CTX='32768'
    OPENCLAW_MAX_TOKENS='8192'
    OPENCLAW_PROVIDER_NAME='clawbox'
    OPENCLAW_DEFAULT_MODEL='local'
    VM_HOST='tester@vm.example'
    write_env_from_template() { printf 'WRITE_CTX:%s\n' "$LLAMA_CTX"; }
    source_env_file() { :; }
    detect_context_llama_mode() { REPLY=user; }
    setup_llama_service_for_mode() { printf 'SERVICE:%s:%s\n' "$1" "$LLAMA_CTX"; }
    llama_refresh_openclaw_effective_context_window() { printf 'REFRESH:%s\n' "$LLAMA_CTX"; }
    sync_openclaw_config_targeted_only() { printf 'SYNC:%s:%s\n' "$1" "$LLAMA_CTX"; CONFIG_TARGETED_UPDATED=true; }
    offer_targeted_openclaw_config_restart() { printf 'RESTART_PROMPT:%s\n' "${CONFIG_TARGETED_UPDATED:-false}"; }
    context_apply_value 131072 262144
  } 2>&1)"

  assert_contains 'direct context writes env with requested value' "$output" 'WRITE_CTX:131072'
  assert_contains 'direct context restarts managed primary runtime' "$output" 'SERVICE:user:131072'
  assert_contains 'direct context refreshes effective OpenClaw context' "$output" 'REFRESH:131072'
  assert_contains 'direct context syncs only primary OpenClaw scope' "$output" 'SYNC:primary:131072'
  assert_contains 'direct context preserves targeted restart policy' "$output" 'RESTART_PROMPT:true'
  assert_contains 'direct context reports success' "$output" 'Primary llama-server context is now 131072'
}

test_context_direct_noop_does_not_restart() {
  local output
  output="$({
    CLAWBOX_CONTEXT_LIB_ONLY=true source "$ROOT_DIR/scripts/context.sh"
    LLAMA_CTX='32768'
    OPENCLAW_MAX_TOKENS='8192'
    detect_context_llama_mode() { printf 'MODE_UNEXPECTED\n'; }
    setup_llama_service_for_mode() { printf 'SERVICE_UNEXPECTED\n'; }
    context_apply_value 32768 65536
  } 2>&1)"

  assert_contains 'context no-op reports unchanged state' "$output" 'LLAMA_CTX is already 32768.'
  assert_not_contains 'context no-op does not detect runtime mode' "$output" 'MODE_UNEXPECTED'
  assert_not_contains 'context no-op does not restart service' "$output" 'SERVICE_UNEXPECTED'
}

test_context_direct_invalid_value_fails_before_mutation() {
  local output status
  set +e
  output="$({
    CLAWBOX_CONTEXT_LIB_ONLY=true source "$ROOT_DIR/scripts/context.sh"
    LLAMA_CTX='32768'
    OPENCLAW_MAX_TOKENS='8192'
    write_env_from_template() { printf 'WRITE_UNEXPECTED\n'; }
    setup_llama_service_for_mode() { printf 'SERVICE_UNEXPECTED\n'; }
    context_apply_value 65536 32768
  } 2>&1)"
  status=$?
  set -e

  assert_equals 'invalid context returns nonzero' "$status" '1'
  assert_contains 'invalid direct context reports native bound' "$output" 'exceeds model native context 32768'
  assert_not_contains 'invalid direct context does not write env' "$output" 'WRITE_UNEXPECTED'
  assert_not_contains 'invalid direct context does not restart runtime' "$output" 'SERVICE_UNEXPECTED'
}

run_test test_root_help_lists_context_command
run_test test_context_shared_default_and_validation_policy
run_test test_context_direct_update_applies_env_runtime_and_openclaw
run_test test_context_direct_noop_does_not_restart
run_test test_context_direct_invalid_value_fails_before_mutation

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi
printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
