#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/helpers/setup-harness.sh"
TEMP_DIR="$(mktemp -d)"
trap cleanup_temp_dir EXIT

test_runtime_artifacts_are_distinct() {
  local output
  output="$({
    BASE_DIR="$ROOT_DIR" HOME="$TEMP_DIR/home" CLAWBOX_LLAMA_USER_UID=501
    LLAMA_BIN='/tmp/llama-server' EMBEDDINGS_MODEL_PATH='/tmp/embed.gguf' EMBEDDINGS_LLAMA_HOST='0.0.0.0' EMBEDDINGS_LLAMA_PORT=11435 EMBEDDINGS_LLAMA_CTX=8192 EMBEDDINGS_LLAMA_EXTRA_ARGS='--embedding -ngl 99'
    . "$ROOT_DIR/lib/llama.sh"
    printf 'LABEL=%s\n' "$(embeddings_llama_label)"
    printf 'PLIST=%s\nPRIMARY=%s\n' "$(embeddings_llama_user_plist_dest)" "$(llama_user_plist_dest)"
    printf 'ENV=%s\nPRIMARY_ENV=%s\n' "$(embeddings_llama_user_env_dest)" "$(llama_user_env_dest)"
    printf 'WRAPPER=%s\nPRIMARY_WRAPPER=%s\n' "$(embeddings_llama_user_wrapper_dest)" "$(llama_user_wrapper_dest)"
    printf 'OUT=%s\nERR=%s\n' "$(embeddings_llama_mode_stdout_log user)" "$(embeddings_llama_mode_stderr_log user)"
    write_embeddings_llama_runtime_env "$TEMP_DIR/embed.env"
    cat "$TEMP_DIR/embed.env"
  } 2>&1)"
  assert_contains 'embeddings uses distinct launchd label' "$output" 'LABEL=com.clawbox.llama.embeddings'
  assert_not_contains 'embeddings plist differs from primary' "$output" 'PLIST=/tmp'
  assert_contains 'embeddings runtime env stores model path' "$output" 'EMBEDDINGS_MODEL_PATH="/tmp/embed.gguf"'
  assert_contains 'embeddings runtime env stores port' "$output" 'EMBEDDINGS_LLAMA_PORT="11435"'
  assert_contains 'embeddings runtime env stores context and extra args' "$output" 'EMBEDDINGS_LLAMA_EXTRA_ARGS="--embedding -ngl 99"'
  if grep -Eq '^MODEL_PATH=' "$TEMP_DIR/embed.env"; then fail 'embeddings runtime env does not overwrite primary model key'; else pass 'embeddings runtime env does not overwrite primary model key'; fi
}

test_wrapper_arguments_are_profile_specific() {
  local fake_bin='/bin/echo' primary_env="$TEMP_DIR/primary.env" embed_env="$TEMP_DIR/embed-wrapper.env" primary_output='' embed_output=''
  printf 'LLAMA_BIN="%s"\nMODEL_PATH="/tmp/primary.gguf"\nLLAMA_HOST="0.0.0.0"\nLLAMA_PORT="11434"\nLLAMA_CTX="16384"\nLLAMA_EXTRA_ARGS="-ngl 99"\n' "$fake_bin" > "$primary_env"
  printf 'CLAWBOX_LLAMA_INSTANCE="embeddings"\nEMBEDDINGS_LLAMA_BIN="%s"\nEMBEDDINGS_MODEL_PATH="/tmp/embed.gguf"\nEMBEDDINGS_LLAMA_HOST="0.0.0.0"\nEMBEDDINGS_LLAMA_PORT="11435"\nEMBEDDINGS_LLAMA_CTX="8192"\nEMBEDDINGS_LLAMA_EXTRA_ARGS="--embedding -fa on"\n' "$fake_bin" > "$embed_env"
  : > /tmp/primary.gguf
  : > /tmp/embed.gguf
  lsof() { return 1; }; export -f lsof
  primary_output="$(CLAWBOX_ENV_FILE="$primary_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  embed_output="$(CLAWBOX_ENV_FILE="$embed_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  assert_contains 'primary wrapper appends primary args after required args' "$primary_output" '-m /tmp/primary.gguf --host 0.0.0.0 --port 11434 --ctx-size 16384 -ngl 99'
  assert_not_contains 'primary wrapper excludes embeddings arg by default' "$primary_output" '--embedding'
  assert_contains 'embeddings wrapper uses embeddings model and args' "$embed_output" '-m /tmp/embed.gguf --host 0.0.0.0 --port 11435 --ctx-size 8192 --embedding -fa on'
}

test_disabled_status_and_model_preservation_contract() {
  local status_source model_source
  status_source="$(cat "$ROOT_DIR/scripts/status.sh")"; model_source="$(cat "$ROOT_DIR/scripts/model.sh")"
  assert_contains 'status gates embeddings checks on enabled true only' "$status_source" '[ "${EMBEDDINGS_ENABLED:-false}" = true ]'
  assert_not_contains 'model command does not reference embeddings model path' "$model_source" 'EMBEDDINGS_MODEL_PATH'
  assert_not_contains 'model command does not manage embeddings service' "$model_source" 'setup_embeddings_llama_service_for_mode'
}

test_port_selection_contract() {
  local output
  output="$({
    export TEMP_DIR ROOT_DIR
    . "$ROOT_DIR/tests/helpers/setup-harness.sh"
    load_setup_functions
    HOST_IP=127.0.0.1 LLAMA_PORT=11434 EMBEDDINGS_ENABLED=false
    prompt_yes_no() { REPLY=true; }; select_embeddings_model_path() { EMBEDDINGS_MODEL_PATH=/tmp/embed.gguf; }
    configured_or_default() { REPLY="$3"; }; prompt_with_default() { REPLY="$2"; }
    llama_port_in_use() { [ "$1" = 11435 ]; }; llama_suggest_available_port() { REPLY=11436; }
    write_env_from_template() { printf 'PORT=%s URL=%s\n' "$EMBEDDINGS_LLAMA_PORT" "$EMBEDDINGS_LLAMA_BASE_URL"; }; source_env_file(){ :; }; detect_existing_llama_install_mode(){ REPLY=user; }; setup_embeddings_llama_service_for_mode(){ :; }
    setup_embeddings_service_phase
  } 2>&1)"
  assert_contains 'busy embeddings default port selects alternate port and URL' "$output" 'PORT=11436 URL=http://127.0.0.1:11436/v1'
}

run_test test_runtime_artifacts_are_distinct
run_test test_wrapper_arguments_are_profile_specific
run_test test_disabled_status_and_model_preservation_contract
run_test test_port_selection_contract
[ "$FAILURES" -eq 0 ] && { echo 'PASS: embeddings test suite succeeded'; exit 0; }
echo "FAIL: embeddings test suite failed with $FAILURES issues"; exit 1
