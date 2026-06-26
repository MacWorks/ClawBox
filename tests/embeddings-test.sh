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
  local fake_bin='/bin/echo'
  local primary_env="$TEMP_DIR/primary.env"
  local primary_empty_env="$TEMP_DIR/primary-empty.env"
  local primary_absent_env="$TEMP_DIR/primary-absent.env"
  local embed_env="$TEMP_DIR/embed-wrapper.env"
  local embed_empty_env="$TEMP_DIR/embed-empty.env"
  local embed_absent_env="$TEMP_DIR/embed-absent.env"
  local primary_output='' primary_empty_output='' primary_absent_output=''
  local embed_output='' embed_empty_output='' embed_absent_output=''
  printf 'LLAMA_BIN="%s"\nMODEL_PATH="/tmp/primary.gguf"\nLLAMA_HOST="0.0.0.0"\nLLAMA_PORT="11434"\nLLAMA_CTX="16384"\nLLAMA_EXTRA_ARGS="-ngl 99"\n' "$fake_bin" > "$primary_env"
  printf 'LLAMA_BIN="%s"\nMODEL_PATH="/tmp/primary.gguf"\nLLAMA_HOST="0.0.0.0"\nLLAMA_PORT="11434"\nLLAMA_CTX="16384"\nLLAMA_EXTRA_ARGS=""\n' "$fake_bin" > "$primary_empty_env"
  printf 'LLAMA_BIN="%s"\nMODEL_PATH="/tmp/primary.gguf"\nLLAMA_HOST="0.0.0.0"\nLLAMA_PORT="11434"\nLLAMA_CTX="16384"\n' "$fake_bin" > "$primary_absent_env"
  printf 'CLAWBOX_LLAMA_INSTANCE="embeddings"\nEMBEDDINGS_LLAMA_BIN="%s"\nEMBEDDINGS_MODEL_PATH="/tmp/embed.gguf"\nEMBEDDINGS_LLAMA_HOST="0.0.0.0"\nEMBEDDINGS_LLAMA_PORT="11435"\nEMBEDDINGS_LLAMA_CTX="8192"\nEMBEDDINGS_LLAMA_EXTRA_ARGS="--embedding -fa on"\n' "$fake_bin" > "$embed_env"
  printf 'CLAWBOX_LLAMA_INSTANCE="embeddings"\nEMBEDDINGS_LLAMA_BIN="%s"\nEMBEDDINGS_MODEL_PATH="/tmp/embed.gguf"\nEMBEDDINGS_LLAMA_HOST="0.0.0.0"\nEMBEDDINGS_LLAMA_PORT="11435"\nEMBEDDINGS_LLAMA_CTX="8192"\nEMBEDDINGS_LLAMA_EXTRA_ARGS=""\n' "$fake_bin" > "$embed_empty_env"
  printf 'CLAWBOX_LLAMA_INSTANCE="embeddings"\nEMBEDDINGS_LLAMA_BIN="%s"\nEMBEDDINGS_MODEL_PATH="/tmp/embed.gguf"\nEMBEDDINGS_LLAMA_HOST="0.0.0.0"\nEMBEDDINGS_LLAMA_PORT="11435"\nEMBEDDINGS_LLAMA_CTX="8192"\n' "$fake_bin" > "$embed_absent_env"
  : > /tmp/primary.gguf
  : > /tmp/embed.gguf
  lsof() { return 1; }; export -f lsof
  primary_output="$(CLAWBOX_ENV_FILE="$primary_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  primary_empty_output="$(CLAWBOX_ENV_FILE="$primary_empty_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  primary_absent_output="$(CLAWBOX_ENV_FILE="$primary_absent_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  embed_output="$(CLAWBOX_ENV_FILE="$embed_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  embed_empty_output="$(CLAWBOX_ENV_FILE="$embed_empty_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  embed_absent_output="$(CLAWBOX_ENV_FILE="$embed_absent_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  assert_contains 'primary wrapper appends primary args after required args' "$primary_output" '-m /tmp/primary.gguf --host 0.0.0.0 --port 11434 --ctx-size 16384 -ngl 99'
  assert_not_contains 'primary wrapper excludes embeddings arg by default' "$primary_output" '--embedding'
  assert_contains 'primary wrapper accepts empty LLAMA_EXTRA_ARGS' "$primary_empty_output" '-m /tmp/primary.gguf --host 0.0.0.0 --port 11434 --ctx-size 16384'
  assert_not_contains 'primary wrapper empty LLAMA_EXTRA_ARGS appends nothing' "$primary_empty_output" '-ngl'
  assert_contains 'primary wrapper accepts absent LLAMA_EXTRA_ARGS under set -u' "$primary_absent_output" '-m /tmp/primary.gguf --host 0.0.0.0 --port 11434 --ctx-size 16384'
  assert_not_contains 'primary wrapper absent LLAMA_EXTRA_ARGS appends nothing' "$primary_absent_output" '-ngl'
  assert_contains 'embeddings wrapper uses embeddings model and args' "$embed_output" '-m /tmp/embed.gguf --host 0.0.0.0 --port 11435 --ctx-size 8192 --embedding -fa on'
  assert_contains 'embeddings wrapper accepts empty EMBEDDINGS_LLAMA_EXTRA_ARGS' "$embed_empty_output" '-m /tmp/embed.gguf --host 0.0.0.0 --port 11435 --ctx-size 8192'
  assert_not_contains 'embeddings wrapper empty extra args appends nothing' "$embed_empty_output" '--embedding'
  assert_contains 'embeddings wrapper accepts absent EMBEDDINGS_LLAMA_EXTRA_ARGS under set -u' "$embed_absent_output" '-m /tmp/embed.gguf --host 0.0.0.0 --port 11435 --ctx-size 8192'
  assert_not_contains 'embeddings wrapper absent extra args appends nothing' "$embed_absent_output" '--embedding'
}

test_runtime_env_writes_empty_extra_args_for_fresh_users() {
  local primary_env="$TEMP_DIR/runtime-primary.env" embeddings_env="$TEMP_DIR/runtime-embeddings.env" output
  output="$({
    BASE_DIR="$ROOT_DIR" HOME="$TEMP_DIR/home"
    LLAMA_BIN='/tmp/llama-server'
    MODEL_PATH='/tmp/primary.gguf'
    LLAMA_HOST='0.0.0.0'
    LLAMA_PORT='11436'
    LLAMA_CTX='16384'
    unset LLAMA_EXTRA_ARGS
    EMBEDDINGS_MODEL_PATH='/tmp/embed.gguf'
    EMBEDDINGS_LLAMA_HOST='0.0.0.0'
    EMBEDDINGS_LLAMA_PORT='11435'
    EMBEDDINGS_LLAMA_CTX='8192'
    unset EMBEDDINGS_LLAMA_EXTRA_ARGS
    . "$ROOT_DIR/lib/llama.sh"
    write_llama_runtime_env "$primary_env"
    write_embeddings_llama_runtime_env "$embeddings_env"
    cat "$primary_env"
    cat "$embeddings_env"
  } 2>&1)"
  assert_contains 'fresh primary runtime env includes empty LLAMA_EXTRA_ARGS' "$output" 'LLAMA_EXTRA_ARGS=""'
  assert_contains 'fresh embeddings runtime env includes empty EMBEDDINGS_LLAMA_EXTRA_ARGS' "$output" 'EMBEDDINGS_LLAMA_EXTRA_ARGS=""'
}

test_disabled_status_and_model_preservation_contract() {
  local status_source model_source embeddings_source
  status_source="$(cat "$ROOT_DIR/scripts/status.sh")"; model_source="$(cat "$ROOT_DIR/scripts/model.sh")"; embeddings_source="$(cat "$ROOT_DIR/lib/setup-embeddings.sh")"
  assert_contains 'status gates embeddings checks on enabled true only' "$status_source" '[ "${EMBEDDINGS_ENABLED:-false}" = true ]'
  assert_contains 'model command exposes an embeddings-only dispatch path' "$model_source" 'embedding|embeddings) switch_embeddings_model'
  assert_contains 'embeddings model flow uses only embeddings service helper' "$embeddings_source" 'setup_embeddings_llama_service_for_mode'
  assert_not_contains 'embeddings helper does not use primary service helper' "$(sed -n '/^switch_embeddings_model()/,/^}/p' "$ROOT_DIR/lib/setup-embeddings.sh")" 'setup_llama_service_for_mode'
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
run_test test_runtime_env_writes_empty_extra_args_for_fresh_users
run_test test_disabled_status_and_model_preservation_contract
run_test test_port_selection_contract
[ "$FAILURES" -eq 0 ] && { echo 'PASS: embeddings test suite succeeded'; exit 0; }
echo "FAIL: embeddings test suite failed with $FAILURES issues"; exit 1
