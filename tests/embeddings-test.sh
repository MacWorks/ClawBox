#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/helpers/setup-harness.sh"
TEMP_DIR="$(mktemp -d)"
trap cleanup_temp_dir EXIT

test_runtime_artifacts_are_distinct() {
  local fake_bin="$TEMP_DIR/bin/llama-server"
  local embed_model="$TEMP_DIR/models/embed.gguf"
  local output
  mkdir -p "$(dirname "$fake_bin")" "$(dirname "$embed_model")"
  : > "$fake_bin"
  : > "$embed_model"
  chmod +x "$fake_bin"
  output="$({
    BASE_DIR="$ROOT_DIR" HOME="$TEMP_DIR/home" CLAWBOX_LLAMA_USER_UID=501
    LLAMA_BIN="$fake_bin" EMBEDDINGS_MODEL_PATH="$embed_model" EMBEDDINGS_LLAMA_HOST='0.0.0.0' EMBEDDINGS_LLAMA_PORT=11435 EMBEDDINGS_LLAMA_CTX=8192 EMBEDDINGS_LLAMA_EXTRA_ARGS='--embedding -ngl 99'
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
  assert_contains 'embeddings runtime env stores model path' "$output" "EMBEDDINGS_MODEL_PATH=\"$embed_model\""
  assert_contains 'embeddings runtime env stores port' "$output" 'EMBEDDINGS_LLAMA_PORT="11435"'
  assert_contains 'embeddings runtime env stores context and extra args' "$output" 'EMBEDDINGS_LLAMA_EXTRA_ARGS="--embedding -ngl 99"'
  if grep -Eq '^MODEL_PATH=' "$TEMP_DIR/embed.env"; then fail 'embeddings runtime env does not overwrite primary model key'; else pass 'embeddings runtime env does not overwrite primary model key'; fi
}

test_wrapper_arguments_are_profile_specific() {
  local fake_bin='/bin/echo'
  local primary_model="$TEMP_DIR/models/primary.gguf"
  local primary_mmproj="$TEMP_DIR/models/primary projector.gguf"
  local embed_model="$TEMP_DIR/models/embed.gguf"
  local primary_env="$TEMP_DIR/primary.env"
  local primary_conflict_env="$TEMP_DIR/primary-conflict.env"
  local primary_empty_env="$TEMP_DIR/primary-empty.env"
  local primary_absent_env="$TEMP_DIR/primary-absent.env"
  local embed_env="$TEMP_DIR/embed-wrapper.env"
  local embed_empty_env="$TEMP_DIR/embed-empty.env"
  local embed_absent_env="$TEMP_DIR/embed-absent.env"
  local primary_output='' primary_empty_output='' primary_absent_output=''
  local primary_conflict_output='' primary_conflict_status=0
  local embed_output='' embed_empty_output='' embed_absent_output=''
  mkdir -p "$(dirname "$primary_model")" "$(dirname "$embed_model")"
  : > "$primary_model"
  : > "$primary_mmproj"
  : > "$embed_model"
  printf 'LLAMA_BIN="%s"\nMODEL_PATH="%s"\nMMPROJ_PATH="%s"\nLLAMA_HOST="0.0.0.0"\nLLAMA_PORT="11434"\nLLAMA_CTX="16384"\nLLAMA_FLASH_ATTENTION="true"\nLLAMA_JINJA="true"\nLLAMA_MLOCK="true"\nLLAMA_EXTRA_ARGS="--threads 8"\n' "$fake_bin" "$primary_model" "$primary_mmproj" > "$primary_env"
  printf 'LLAMA_BIN="%s"\nMODEL_PATH="%s"\nLLAMA_HOST="0.0.0.0"\nLLAMA_PORT="11434"\nLLAMA_CTX="16384"\nLLAMA_EXTRA_ARGS="--jinja -ngl 99"\n' "$fake_bin" "$primary_model" > "$primary_conflict_env"
  printf 'LLAMA_BIN="%s"\nMODEL_PATH="%s"\nLLAMA_HOST="0.0.0.0"\nLLAMA_PORT="11434"\nLLAMA_CTX="16384"\nLLAMA_FLASH_ATTENTION="false"\nLLAMA_JINJA="false"\nLLAMA_MLOCK="true"\nLLAMA_EXTRA_ARGS=""\n' "$fake_bin" "$primary_model" > "$primary_empty_env"
  printf 'LLAMA_BIN="%s"\nMODEL_PATH="%s"\nLLAMA_HOST="0.0.0.0"\nLLAMA_PORT="11434"\nLLAMA_CTX="16384"\n' "$fake_bin" "$primary_model" > "$primary_absent_env"
  printf 'CLAWBOX_LLAMA_INSTANCE="embeddings"\nEMBEDDINGS_LLAMA_BIN="%s"\nEMBEDDINGS_MODEL_PATH="%s"\nEMBEDDINGS_LLAMA_HOST="0.0.0.0"\nEMBEDDINGS_LLAMA_PORT="11435"\nEMBEDDINGS_LLAMA_CTX="8192"\nEMBEDDINGS_LLAMA_EXTRA_ARGS="--embedding --jinja -fa on"\n' "$fake_bin" "$embed_model" > "$embed_env"
  printf 'CLAWBOX_LLAMA_INSTANCE="embeddings"\nEMBEDDINGS_LLAMA_BIN="%s"\nEMBEDDINGS_MODEL_PATH="%s"\nEMBEDDINGS_LLAMA_HOST="0.0.0.0"\nEMBEDDINGS_LLAMA_PORT="11435"\nEMBEDDINGS_LLAMA_CTX="8192"\nEMBEDDINGS_LLAMA_EXTRA_ARGS=""\n' "$fake_bin" "$embed_model" > "$embed_empty_env"
  printf 'CLAWBOX_LLAMA_INSTANCE="embeddings"\nEMBEDDINGS_LLAMA_BIN="%s"\nEMBEDDINGS_MODEL_PATH="%s"\nEMBEDDINGS_LLAMA_HOST="0.0.0.0"\nEMBEDDINGS_LLAMA_PORT="11435"\nEMBEDDINGS_LLAMA_CTX="8192"\n' "$fake_bin" "$embed_model" > "$embed_absent_env"
  lsof() { return 1; }; export -f lsof
  primary_output="$(CLAWBOX_ENV_FILE="$primary_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  set +e
  primary_conflict_output="$(CLAWBOX_ENV_FILE="$primary_conflict_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh" 2>&1)"
  primary_conflict_status=$?
  set -e
  primary_empty_output="$(CLAWBOX_ENV_FILE="$primary_empty_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  primary_absent_output="$(CLAWBOX_ENV_FILE="$primary_absent_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  embed_output="$(CLAWBOX_ENV_FILE="$embed_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  embed_empty_output="$(CLAWBOX_ENV_FILE="$embed_empty_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  embed_absent_output="$(CLAWBOX_ENV_FILE="$embed_absent_env" bash "$ROOT_DIR/host/scripts/llama-wrapper.sh")"
  assert_contains 'primary wrapper renders flash attention Jinja mmproj and mlock' "$primary_output" "-m $primary_model --host 0.0.0.0 --port 11434 --ctx-size 16384 --parallel 1 --flash-attn on --jinja --mmproj $primary_mmproj --mlock --threads 8"
  assert_equals 'primary wrapper rejects managed flags in LLAMA_EXTRA_ARGS' "$primary_conflict_status" '1'
  assert_contains 'primary wrapper reports managed flag conflicts' "$primary_conflict_output" 'LLAMA_EXTRA_ARGS conflicts with ClawBox-managed llama-server settings: --jinja -ngl'
  assert_not_contains 'primary wrapper excludes embeddings arg by default' "$primary_output" '--embedding'
  assert_contains 'primary wrapper renders flash attention false with explicit value before mlock' "$primary_empty_output" "-m $primary_model --host 0.0.0.0 --port 11434 --ctx-size 16384 --parallel 1 --flash-attn off --mlock"
  assert_not_contains 'primary wrapper omits Jinja when disabled' "$primary_empty_output" '--jinja'
  assert_not_contains 'primary wrapper empty LLAMA_EXTRA_ARGS appends nothing' "$primary_empty_output" '-ngl'
  assert_contains 'primary wrapper accepts absent LLAMA_EXTRA_ARGS under set -u' "$primary_absent_output" "-m $primary_model --host 0.0.0.0 --port 11434 --ctx-size 16384 --parallel 1 --flash-attn off"
  assert_not_contains 'primary wrapper absent LLAMA_JINJA omits Jinja under set -u' "$primary_absent_output" '--jinja'
  assert_not_contains 'primary wrapper absent LLAMA_EXTRA_ARGS appends nothing' "$primary_absent_output" '-ngl'
  assert_contains 'embeddings wrapper uses embeddings model and args' "$embed_output" "-m $embed_model --host 0.0.0.0 --port 11435 --ctx-size 8192 --parallel 1 --embedding --jinja -fa on"
  assert_not_contains 'embeddings wrapper does not inherit primary flash attention management' "$embed_output" '--flash-attn'
  assert_not_contains 'embeddings wrapper does not inherit primary mmproj management' "$embed_output" '--mmproj'
  assert_contains 'embeddings wrapper keeps explicit embeddings Jinja passthrough' "$embed_output" '--jinja'
  assert_contains 'embeddings wrapper accepts empty EMBEDDINGS_LLAMA_EXTRA_ARGS' "$embed_empty_output" "-m $embed_model --host 0.0.0.0 --port 11435 --ctx-size 8192 --parallel 1"
  assert_not_contains 'embeddings wrapper empty extra args appends nothing' "$embed_empty_output" '--embedding'
  assert_contains 'embeddings wrapper accepts absent EMBEDDINGS_LLAMA_EXTRA_ARGS under set -u' "$embed_absent_output" "-m $embed_model --host 0.0.0.0 --port 11435 --ctx-size 8192 --parallel 1"
  assert_not_contains 'embeddings wrapper absent extra args appends nothing' "$embed_absent_output" '--embedding'
}

test_runtime_env_writes_empty_extra_args_for_fresh_users() {
  local fake_bin="$TEMP_DIR/bin/llama-server"
  local primary_model="$TEMP_DIR/models/primary.gguf"
  local embed_model="$TEMP_DIR/models/embed.gguf"
  local primary_env="$TEMP_DIR/runtime-primary.env" embeddings_env="$TEMP_DIR/runtime-embeddings.env" output
  mkdir -p "$(dirname "$fake_bin")" "$(dirname "$primary_model")" "$(dirname "$embed_model")"
  : > "$fake_bin"
  : > "$primary_model"
  : > "$embed_model"
  chmod +x "$fake_bin"
  output="$({
    BASE_DIR="$ROOT_DIR" HOME="$TEMP_DIR/home"
    LLAMA_BIN="$fake_bin"
    MODEL_PATH="$primary_model"
    MMPROJ_PATH=''
    LLAMA_HOST='0.0.0.0'
    LLAMA_PORT='11436'
    LLAMA_CTX='16384'
    unset LLAMA_EXTRA_ARGS
    EMBEDDINGS_MODEL_PATH="$embed_model"
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
  assert_contains 'fresh primary runtime env includes empty MMPROJ_PATH' "$output" 'MMPROJ_PATH=""'
  assert_contains 'fresh primary runtime env tolerates absent LLAMA_JINJA' "$output" 'LLAMA_JINJA=""'
  assert_contains 'fresh embeddings runtime env includes empty EMBEDDINGS_LLAMA_EXTRA_ARGS' "$output" 'EMBEDDINGS_LLAMA_EXTRA_ARGS=""'
}

test_configured_endpoint_failure_with_available_interface_requires_repair() {
  local output=''
  local status=0
  local curl_log="$TEMP_DIR/embeddings-curl.log"
  local curl_output=''

  output="$({
    export BASE_DIR="$ROOT_DIR"
    export CLAWBOX_EMBEDDINGS_CURL_LOG="$curl_log"
    export HOST_IP='192.168.64.1'
    export EMBEDDINGS_LLAMA_HOST='0.0.0.0'
    export EMBEDDINGS_LLAMA_PORT=11435
    export EMBEDDINGS_LLAMA_BASE_URL='http://192.168.64.1:11435/v1'
    curl() {
      printf '%s\n' "$*" >> "$CLAWBOX_EMBEDDINGS_CURL_LOG"
      if [[ "$*" == *'http://192.168.64.1:11435/v1/models'* ]]; then
        return 1
      fi
      if [[ "$*" == *'http://127.0.0.1:11435/v1/models'* ]]; then
        return 0
      fi
      printf 'UNEXPECTED_CURL:%s\n' "$*"
      return 2
    }
    ifconfig() {
      printf '%s\n' 'bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST>'
      printf '%s\n' 'inet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255'
    }
    . "$ROOT_DIR/lib/llama.sh"
    set +e
    embeddings_llama_verify_configured_endpoint
    status=$?
    set -e
    printf 'STATUS=%s\n' "$status"
  } 2>&1)"

  assert_contains 'embeddings setup fails when interface exists but only loopback responds' "$output" 'STATUS=1'
  assert_contains 'embeddings setup reports configured VM-facing endpoint failure' "$output" 'Embeddings llama-server responds locally but not at the configured VM-facing endpoint: http://192.168.64.1:11435/v1'
  curl_output="$([ -f "$curl_log" ] && cat "$curl_log" || true)"
  assert_contains 'embeddings setup probes the configured /v1/models endpoint' "$curl_output" 'http://192.168.64.1:11435/v1/models'
  assert_contains 'embeddings setup probes loopback only as diagnostic' "$curl_output" 'http://127.0.0.1:11435/v1/models'
  assert_not_contains 'embeddings setup does not probe legacy root models path' "$curl_output" 'http://192.168.64.1:11435/models'
}

test_configured_endpoint_absent_interface_allows_loopback_reuse() {
  local output=''
  local status=0
  local curl_log="$TEMP_DIR/embeddings-absent-interface-curl.log"
  local curl_output=''

  output="$({
    export BASE_DIR="$ROOT_DIR"
    export CLAWBOX_EMBEDDINGS_CURL_LOG="$curl_log"
    export HOST_IP='192.168.64.1'
    export EMBEDDINGS_LLAMA_HOST='0.0.0.0'
    export EMBEDDINGS_LLAMA_PORT=11435
    export EMBEDDINGS_LLAMA_BASE_URL='http://192.168.64.1:11435/v1'
    curl() {
      printf '%s\n' "$*" >> "$CLAWBOX_EMBEDDINGS_CURL_LOG"
      if [[ "$*" == *'http://192.168.64.1:11435/v1/models'* ]]; then
        return 1
      fi
      if [[ "$*" == *'http://127.0.0.1:11435/v1/models'* ]]; then
        return 0
      fi
      printf 'UNEXPECTED_CURL:%s\n' "$*"
      return 2
    }
    ifconfig() {
      printf '%s\n' 'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST>'
      printf '%s\n' 'inet 127.0.0.1 netmask 0xff000000'
    }
    . "$ROOT_DIR/lib/llama.sh"
    set +e
    embeddings_llama_verify_configured_endpoint
    status=$?
    set -e
    printf 'STATUS=%s\n' "$status"
  } 2>&1)"

  assert_contains 'embeddings setup accepts local health when VM-facing interface is absent' "$output" 'STATUS=0'
  assert_contains 'embeddings setup reports missing VM-facing interface' "$output" 'Embeddings llama-server is healthy locally, but the configured VM-facing endpoint is not reachable yet.'
  assert_contains 'embeddings setup reports local readiness endpoint' "$output" 'Local readiness: http://127.0.0.1:11435/v1'
  assert_contains 'embeddings setup reports configured VM-facing endpoint' "$output" 'VM-facing endpoint: http://192.168.64.1:11435/v1'
  assert_not_contains 'embeddings setup local readiness line has no leading whitespace' "$output" $'\n  Local readiness:'
  assert_not_contains 'embeddings setup vm-facing line has no leading whitespace' "$output" $'\n  VM-facing endpoint:'
  assert_not_contains 'embeddings setup vm-interface explanation has no leading whitespace' "$output" $'\n  The UTM/VM host network interface'
  assert_not_contains 'embeddings setup absent interface does not recommend rebind' "$output" 'Restart/update embeddings setup'
  curl_output="$([ -f "$curl_log" ] && cat "$curl_log" || true)"
  assert_contains 'embeddings setup absent interface probes configured endpoint' "$curl_output" 'http://192.168.64.1:11435/v1/models'
  assert_contains 'embeddings setup absent interface probes local readiness' "$curl_output" 'http://127.0.0.1:11435/v1/models'
}

test_embeddings_service_start_uses_loopback_readiness_before_vm_endpoint() {
  local output=''
  local status=0
  local curl_log="$TEMP_DIR/embeddings-start-curl.log"
  local model_path="$TEMP_DIR/models/embed-start.gguf"
  local fake_bin='/bin/echo'

  mkdir -p "$(dirname "$model_path")"
  : > "$model_path"

  output="$({
    export HOME="$TEMP_DIR/embeddings-start-home"
    export BASE_DIR="$ROOT_DIR"
    export CLAWBOX_EMBEDDINGS_CURL_LOG="$curl_log"
    export LLAMA_BIN="$fake_bin"
    export EMBEDDINGS_MODEL_PATH="$model_path"
    export EMBEDDINGS_LLAMA_HOST='0.0.0.0'
    export EMBEDDINGS_LLAMA_PORT=11435
    export EMBEDDINGS_LLAMA_CTX=8192
    export EMBEDDINGS_LLAMA_EXTRA_ARGS='--embedding'
    export EMBEDDINGS_LLAMA_BASE_URL='http://192.168.64.1:11435/v1'
    curl() {
      printf '%s\n' "$*" >> "$CLAWBOX_EMBEDDINGS_CURL_LOG"
      if [[ "$*" == *'http://127.0.0.1:11435/v1/models'* ]]; then
        return 0
      fi
      if [[ "$*" == *'http://192.168.64.1:11435/v1/models'* ]]; then
        return 1
      fi
      printf 'UNEXPECTED_CURL:%s\n' "$*"
      return 2
    }
    ifconfig() {
      printf '%s\n' 'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST>'
      printf '%s\n' 'inet 127.0.0.1 netmask 0xff000000'
    }
    launchctl() { return 0; }
    sleep() { :; }
    . "$ROOT_DIR/lib/llama.sh"
    set +e
    setup_embeddings_llama_service_for_mode user
    status=$?
    set -e
    printf 'STATUS=%s\n' "$status"
  } 2>&1)"

  assert_contains 'embeddings service start succeeds from local readiness' "$output" 'STATUS=0'
  curl_output="$([ -f "$curl_log" ] && cat "$curl_log" || true)"
  assert_contains 'embeddings service start probes local readiness' "$curl_output" 'http://127.0.0.1:11435/v1/models'
  assert_contains 'embeddings service start separately probes VM-facing endpoint' "$curl_output" 'http://192.168.64.1:11435/v1/models'
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
  local embed_model="$TEMP_DIR/models/embed.gguf"
  local port_calls="$TEMP_DIR/port-calls.txt"
  local output
  mkdir -p "$(dirname "$embed_model")"
  : > "$embed_model"
  output="$({
    export TEMP_DIR ROOT_DIR
    export TEST_EMBED_MODEL="$embed_model" TEST_PORT_CALLS="$port_calls"
    . "$ROOT_DIR/tests/helpers/setup-harness.sh"
    load_setup_functions
    HOST_IP=127.0.0.1
    LLAMA_PORT=11434
    EMBEDDINGS_ENABLED=false
    unset EMBEDDINGS_MODEL_PATH
    unset EMBEDDINGS_LLAMA_HOST
    unset EMBEDDINGS_LLAMA_PORT
    unset EMBEDDINGS_LLAMA_BASE_URL
    unset EMBEDDINGS_LLAMA_CTX
    unset EMBEDDINGS_LLAMA_EXTRA_ARGS
    embeddings_service_configured() { return 1; }
    setup_existing_embeddings_service_phase() { printf 'UNEXPECTED_EXISTING_EMBEDDINGS_MENU\n'; return 64; }
    prompt_yes_no() { REPLY=true; }; select_embeddings_model_path() { EMBEDDINGS_MODEL_PATH="$TEST_EMBED_MODEL"; }
    configured_or_default() { REPLY="$3"; }; prompt_with_default() { REPLY="$2"; }
    llama_port_in_use() {
      local port="${1:-}"
      printf '%s\n' "$port" >> "$TEST_PORT_CALLS"
      if [ "$port" = 11435 ]; then
        return 0
      fi
      if [ "$port" = 11436 ]; then
        return 1
      fi
      printf 'UNEXPECTED_PORT_CHECK:%s\n' "$port"
      return 2
    }
    llama_suggest_available_port() {
      local current_port="${2:-}"
      printf 'SUGGEST_FROM:%s\n' "$current_port" >> "$TEST_PORT_CALLS"
      [ "$current_port" = 11435 ] || { printf 'UNEXPECTED_SUGGEST_FROM:%s\n' "$current_port"; return 2; }
      REPLY=11436
    }
    lsof() { printf 'UNEXPECTED_LSOF\n'; return 2; }
    nc() { printf 'UNEXPECTED_NC\n'; return 2; }
    curl() { printf 'UNEXPECTED_CURL\n'; return 2; }
    write_env_from_template() {
      printf 'PORT=%s URL=%s\n' "$EMBEDDINGS_LLAMA_PORT" "$EMBEDDINGS_LLAMA_BASE_URL"
      printf 'MODEL=%s\n' "$EMBEDDINGS_MODEL_PATH"
    }
    source_env_file(){ :; }; detect_existing_llama_install_mode(){ REPLY=user; }; setup_embeddings_llama_service_for_mode(){ :; }
    status=0
    setup_embeddings_service_phase || status=$?
    printf 'SETUP_STATUS=%s\n' "$status"
    printf 'EXPECTED_PORT=11436\n'
    printf 'ACTUAL_PORT=%s\n' "${EMBEDDINGS_LLAMA_PORT:-}"
    printf 'EXPECTED_URL=http://127.0.0.1:11436/v1\n'
    printf 'ACTUAL_URL=%s\n' "${EMBEDDINGS_LLAMA_BASE_URL:-}"
    printf 'SELECTED_MODEL=%s\n' "${EMBEDDINGS_MODEL_PATH:-}"
    printf 'PORT_CALLS=%s\n' "$(tr '\n' ',' < "$TEST_PORT_CALLS" 2>/dev/null || true)"
    printf 'FIXTURE_ENV_FILE=%s\n' "${ENV_FILE:-}"
    return "$status"
  } 2>&1)"
  if [[ "$output" == *'PORT=11436 URL=http://127.0.0.1:11436/v1'* ]]; then
    pass 'busy embeddings default port selects alternate port and URL'
  else
    fail "busy embeddings default port selects alternate port and URL; diagnostics: $(printf '%s' "$output" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
  fi
  assert_contains 'busy embeddings default port reports default as occupied' "$output" 'PORT_CALLS=11435,SUGGEST_FROM:11435,11436,'
  assert_not_contains 'busy embeddings fixture does not enter existing service menu' "$output" 'UNEXPECTED_EXISTING_EMBEDDINGS_MENU'
  assert_not_contains 'busy embeddings fixture does not call lsof' "$output" 'UNEXPECTED_LSOF'
  assert_not_contains 'busy embeddings fixture does not call nc' "$output" 'UNEXPECTED_NC'
  assert_not_contains 'busy embeddings fixture does not call curl' "$output" 'UNEXPECTED_CURL'
}

test_setup_rerun_preserves_existing_embeddings_service() {
  local embed_model="$TEMP_DIR/models/existing-embed.gguf"
  local output
  mkdir -p "$(dirname "$embed_model")"
  : > "$embed_model"
  output="$({
    export TEMP_DIR ROOT_DIR
    export TEST_EMBED_MODEL="$embed_model"
    . "$ROOT_DIR/tests/helpers/setup-harness.sh"
    load_setup_functions
    install_prompt_stubs
    queue_prompt_answers '1'
    HOST_IP=127.0.0.1
    LLAMA_BIN=/opt/homebrew/bin/llama-server
    LLAMA_PORT=11434
    EMBEDDINGS_ENABLED=true
    EMBEDDINGS_MODEL_PATH="$TEST_EMBED_MODEL"
    EMBEDDINGS_LLAMA_PORT=11435
    EMBEDDINGS_LLAMA_BASE_URL=http://127.0.0.1:11435/v1
    embeddings_llama_service_loaded() { [ "${1:-}" = user ]; }
    embeddings_llama_endpoint_responding() { return 0; }
    embeddings_llama_verify_configured_endpoint() { return 0; }
    llama_port_in_use() { return 0; }
    write_env_from_template() { printf 'WRITE_ENV_UNEXPECTED\n'; }
    source_env_file() { :; }
    setup_embeddings_llama_service_for_mode() { printf 'RESTART_UNEXPECTED\n'; }
    setup_embeddings_service_phase
    printf 'FINAL:%s:%s:%s:%s\n' "$EMBEDDINGS_ENABLED" "$EMBEDDINGS_MODEL_PATH" "$EMBEDDINGS_LLAMA_PORT" "$EMBEDDINGS_LLAMA_BASE_URL"
  } 2>&1)"
  assert_contains 'existing embeddings rerun detects configured endpoint' "$output" 'embeddings llama-server detected at http://127.0.0.1:11435/v1'
  assert_contains 'existing embeddings rerun offers reuse path' "$output" 'Use the existing running embeddings llama-server on port 11435 (recommended)'
  assert_contains 'existing embeddings rerun preserves enabled config on reuse' "$output" "FINAL:true:$embed_model:11435:http://127.0.0.1:11435/v1"
  assert_not_contains 'existing embeddings rerun does not show fresh configure prompt' "$output" 'Configure a separate host llama-server for embeddings?'
  assert_not_contains 'existing embeddings rerun does not claim embeddings are unconfigured' "$output" 'Embeddings server is not configured.'
  assert_not_contains 'existing embeddings reuse does not restart service' "$output" 'RESTART_UNEXPECTED'
  assert_not_contains 'existing embeddings reuse does not rewrite env' "$output" 'WRITE_ENV_UNEXPECTED'
}

test_setup_rerun_reuses_embeddings_when_loopback_healthy_and_vm_interface_absent() {
  local embed_model="$TEMP_DIR/models/existing-loopback-embed.gguf"
  local output
  local curl_log="$TEMP_DIR/existing-embeddings-loopback-curl.log"
  mkdir -p "$(dirname "$embed_model")"
  : > "$embed_model"
  output="$({
    export TEMP_DIR ROOT_DIR
    export TEST_EMBED_MODEL="$embed_model"
    export CLAWBOX_EMBEDDINGS_CURL_LOG="$curl_log"
    . "$ROOT_DIR/tests/helpers/setup-harness.sh"
    load_setup_functions
    install_prompt_stubs
    queue_prompt_answers '1'
    HOST_IP=192.168.64.1
    LLAMA_BIN=/opt/homebrew/bin/llama-server
    LLAMA_PORT=11434
    EMBEDDINGS_ENABLED=true
    EMBEDDINGS_MODEL_PATH="$TEST_EMBED_MODEL"
    EMBEDDINGS_LLAMA_HOST=0.0.0.0
    EMBEDDINGS_LLAMA_PORT=11435
    EMBEDDINGS_LLAMA_BASE_URL=http://192.168.64.1:11435/v1
    embeddings_llama_service_loaded() { [ "${1:-}" = user ]; }
    llama_port_in_use() { return 0; }
    curl() {
      printf '%s\n' "$*" >> "$CLAWBOX_EMBEDDINGS_CURL_LOG"
      if [[ "$*" == *'http://192.168.64.1:11435/v1/models'* ]]; then
        return 1
      fi
      if [[ "$*" == *'http://127.0.0.1:11435/v1/models'* ]]; then
        return 0
      fi
      printf 'UNEXPECTED_CURL:%s\n' "$*"
      return 2
    }
    ifconfig() {
      printf '%s\n' 'lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST>'
      printf '%s\n' 'inet 127.0.0.1 netmask 0xff000000'
    }
    write_env_from_template() { printf 'WRITE_ENV_UNEXPECTED\n'; }
    source_env_file() { :; }
    setup_embeddings_llama_service_for_mode() { printf 'RESTART_UNEXPECTED\n'; }
    setup_embeddings_service_phase
    printf 'FINAL:%s:%s:%s:%s\n' "$EMBEDDINGS_ENABLED" "$EMBEDDINGS_MODEL_PATH" "$EMBEDDINGS_LLAMA_PORT" "$EMBEDDINGS_LLAMA_BASE_URL"
  } 2>&1)"
  assert_contains 'existing embeddings loopback reuse reports local health' "$output" 'Embeddings llama-server is healthy locally, but the configured VM-facing endpoint is not reachable yet.'
  assert_contains 'existing embeddings loopback reuse accepts existing service' "$output" 'Using existing embeddings llama-server.'
  assert_contains 'existing embeddings loopback reuse reports local endpoint' "$output" 'Local endpoint: http://127.0.0.1:11435/v1'
  assert_contains 'existing embeddings loopback reuse reports configured VM endpoint' "$output" 'Configured VM endpoint: http://192.168.64.1:11435/v1'
  assert_contains 'existing embeddings loopback reuse preserves enabled config' "$output" "FINAL:true:$embed_model:11435:http://192.168.64.1:11435/v1"
  assert_not_contains 'existing embeddings loopback local readiness line has no leading whitespace' "$output" $'\n  Local readiness:'
  assert_not_contains 'existing embeddings loopback vm-facing line has no leading whitespace' "$output" $'\n  VM-facing endpoint:'
  assert_not_contains 'existing embeddings loopback vm-interface explanation has no leading whitespace' "$output" $'\n  The UTM/VM host network interface'
  assert_not_contains 'existing embeddings loopback reuse does not recommend restart' "$output" 'Choose restart/update'
  assert_not_contains 'existing embeddings loopback reuse does not restart service' "$output" 'RESTART_UNEXPECTED'
  assert_not_contains 'existing embeddings loopback reuse does not rewrite env' "$output" 'WRITE_ENV_UNEXPECTED'
}

test_setup_rerun_stopped_embeddings_offers_repair_not_fresh_enable() {
  local embed_model="$TEMP_DIR/models/stopped-embed.gguf"
  local output
  mkdir -p "$(dirname "$embed_model")"
  : > "$embed_model"
  output="$({
    export TEMP_DIR ROOT_DIR
    export TEST_EMBED_MODEL="$embed_model"
    . "$ROOT_DIR/tests/helpers/setup-harness.sh"
    load_setup_functions
    install_prompt_stubs
    queue_prompt_answers '5'
    HOST_IP=127.0.0.1
    LLAMA_BIN=/opt/homebrew/bin/llama-server
    LLAMA_PORT=11434
    EMBEDDINGS_ENABLED=true
    EMBEDDINGS_MODEL_PATH="$TEST_EMBED_MODEL"
    EMBEDDINGS_LLAMA_PORT=11435
    EMBEDDINGS_LLAMA_BASE_URL=http://127.0.0.1:11435/v1
    embeddings_llama_service_loaded() { return 1; }
    embeddings_llama_endpoint_responding() { return 1; }
    embeddings_llama_verify_configured_endpoint() { return 1; }
    llama_port_in_use() { return 1; }
    setup_embeddings_service_phase
  } 2>&1)"
  assert_contains 'stopped configured embeddings rerun still detects embeddings config' "$output" 'embeddings llama-server configured at http://127.0.0.1:11435/v1'
  assert_contains 'stopped configured embeddings rerun offers restart repair path' "$output" 'Restart/update the existing embeddings llama-server on port 11435'
  assert_contains 'stopped configured embeddings rerun offers skip path' "$output" 'Skip embeddings management during setup'
  assert_not_contains 'stopped configured embeddings rerun avoids fresh enable prompt' "$output" 'Configure a separate host llama-server for embeddings?'
  assert_not_contains 'stopped configured embeddings rerun avoids unconfigured message' "$output" 'Embeddings server is not configured.'
}

test_disabled_embeddings_keeps_fresh_enable_prompt() {
  local output
  output="$({
    export TEMP_DIR ROOT_DIR
    . "$ROOT_DIR/tests/helpers/setup-harness.sh"
    load_setup_functions
    install_prompt_stubs
    queue_prompt_answers 'n'
    HOST_IP=127.0.0.1
    LLAMA_PORT=11434
    EMBEDDINGS_ENABLED=false
    unset EMBEDDINGS_MODEL_PATH
    unset EMBEDDINGS_LLAMA_PORT
    unset EMBEDDINGS_LLAMA_BASE_URL
    embeddings_llama_service_loaded() { return 1; }
    llama_port_in_use() { return 1; }
    write_env_from_template() { printf 'WRITE_ENV_UNEXPECTED\n'; }
    source_env_file() { :; }
    setup_embeddings_service_phase
  } 2>&1)"
  assert_contains 'disabled embeddings still uses fresh opt-in prompt' "$output" 'Configure a separate host llama-server for embeddings?'
  assert_contains 'disabled embeddings decline reports unconfigured' "$output" 'Embeddings server is not configured.'
  assert_not_contains 'disabled embeddings does not show existing service menu' "$output" 'Use the existing running embeddings llama-server'
  assert_not_contains 'disabled embeddings decline does not rewrite env when already false' "$output" 'WRITE_ENV_UNEXPECTED'
}

run_test test_runtime_artifacts_are_distinct
run_test test_wrapper_arguments_are_profile_specific
run_test test_runtime_env_writes_empty_extra_args_for_fresh_users
run_test test_configured_endpoint_failure_with_available_interface_requires_repair
run_test test_configured_endpoint_absent_interface_allows_loopback_reuse
run_test test_embeddings_service_start_uses_loopback_readiness_before_vm_endpoint
run_test test_disabled_status_and_model_preservation_contract
run_test test_port_selection_contract
run_test test_setup_rerun_preserves_existing_embeddings_service
run_test test_setup_rerun_reuses_embeddings_when_loopback_healthy_and_vm_interface_absent
run_test test_setup_rerun_stopped_embeddings_offers_repair_not_fresh_enable
run_test test_disabled_embeddings_keeps_fresh_enable_prompt
[ "$FAILURES" -eq 0 ] && { echo 'PASS: embeddings test suite succeeded'; exit 0; }
echo "FAIL: embeddings test suite failed with $FAILURES issues"; exit 1
