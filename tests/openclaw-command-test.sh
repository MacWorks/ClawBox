#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/helpers/setup-harness.sh"

TEMP_DIR="$(mktemp -d)"
trap cleanup_temp_dir EXIT

load_openclaw_command() {
  CLAWBOX_OPENCLAW_LIB_ONLY=true source "$ROOT_DIR/scripts/openclaw.sh"
}

write_openclaw_env() {
  cat > "$TEMP_DIR/.env" <<'EOF'
VM_HOST="tester@vm.example"
LLAMA_BASE_URL="http://127.0.0.1:11434/v1"
LLAMA_CTX="32768"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
OPENCLAW_GATEWAY_MODE="local"
EMBEDDINGS_ENABLED="true"
EMBEDDINGS_MODEL_PATH="/models/bge-large-en-v1.5-f16.gguf"
EMBEDDINGS_LLAMA_BASE_URL="http://127.0.0.1:11435/v1"
EOF
}

test_openclaw_help_and_unknown_subcommand() {
  local help_output unknown_output
  help_output="$({
    load_openclaw_command
    main
  } 2>&1)"
  assert_contains 'openclaw no-subcommand shows reset help' "$help_output" 'Usage: ./clawbox openclaw reset'

  set +e
  unknown_output="$({
    load_openclaw_command
    main sideways
  } 2>&1)"
  status=$?
  set -e
  assert_equals 'unknown openclaw subcommand exits non-zero' "$status" '1'
  assert_contains 'unknown openclaw subcommand fails clearly' "$unknown_output" 'Unknown OpenClaw command: sideways'
}

test_openclaw_reset_defaults_no_without_replacement() {
  local output
  write_openclaw_env
  output="$({
    load_openclaw_command
    ENV_FILE="$TEMP_DIR/.env"
    prompt_yes_no() { printf 'PROMPT:%s\n' "$1"; REPLY=false; }
    ssh_check() { return 0; }
    ssh_exec() { printf 'SSH_EXEC_UNEXPECTED:%s\n' "$*"; return 0; }
    ssh_run_quiet() { printf 'SSH_RUN_UNEXPECTED:%s\n' "$*"; return 0; }
    scp() { printf 'SCP_UNEXPECTED\n'; }
    GENERATE_SCRIPT="$TEMP_DIR/generate.sh"
    reset_openclaw_config
  } 2>&1)"
  assert_contains 'reset warns loudly before replacement' "$output" 'This operation replaces the VM OpenClaw config'
  assert_contains 'reset prompts before replacing config' "$output" 'PROMPT:Replace the VM OpenClaw config now?'
  assert_contains 'reset default no cancels cleanly' "$output" 'OpenClaw config reset cancelled.'
  assert_not_contains 'reset default no does not generate config' "$output" 'Generated minimal OpenClaw config'
  assert_not_contains 'reset default no does not upload config' "$output" 'SCP_UNEXPECTED'
}

test_openclaw_reset_yes_backs_up_and_replaces_config() {
  local output scp_log="$TEMP_DIR/scp.log" generated="$TEMP_DIR/openclaw.json"
  write_openclaw_env
  cat > "$TEMP_DIR/generate.sh" <<EOF
#!/bin/bash
set -e
printf '{"agents":{"defaults":{"model":{"primary":"clawbox/local"},"memorySearch":{"enabled":true,"provider":"openai-compatible","model":"bge-large-en-v1.5-f16.gguf","remote":{"baseUrl":"http://127.0.0.1:11435/v1","apiKey":"ollama-local"}}}}}\\n' > "$generated"
echo "Generated minimal OpenClaw config: $generated"
EOF
  chmod +x "$TEMP_DIR/generate.sh"

  output="$({
    load_openclaw_command
    ENV_FILE="$TEMP_DIR/.env"
    CONFIG_PATH="$generated"
    GENERATE_SCRIPT="$TEMP_DIR/generate.sh"
    prompt_yes_no() { REPLY=true; }
    ssh_check() { return 0; }
    ssh_run_quiet() { printf 'SSH_RUN:%s\n' "$*"; return 0; }
    ssh_exec() {
      if [[ "$*" == *"test -f ~/.openclaw/openclaw.json"* ]]; then
        return 0
      fi
      if [[ "$*" == *"clawbox-backup-"* ]]; then
        printf '~/.openclaw/openclaw.json.clawbox-backup-20260624-120000\n'
        return 0
      fi
      printf 'SSH_EXEC:%s\n' "$*"
      return 0
    }
    scp() { printf '%s\n' "$*" > "$scp_log"; }
    reset_openclaw_config
  } 2>&1)"
  assert_contains 'reset yes creates timestamped VM backup' "$output" 'openclaw.json.clawbox-backup-20260624-120000'
  assert_contains 'reset yes generates minimal config' "$output" 'Generated minimal OpenClaw config'
  assert_contains 'reset yes reports replacement success' "$output" 'VM OpenClaw config was replaced from the minimal ClawBox config.'
  assert_contains 'reset yes creates remote config directory' "$output" 'SSH_RUN:mkdir -p ~/.openclaw'
  assert_contains 'reset yes uploads generated config to VM path' "$(cat "$scp_log")" "$generated"
  assert_contains 'reset yes uploads to authoritative VM config path' "$(cat "$scp_log")" 'tester@vm.example:~/.openclaw/openclaw.json'
}

test_openclaw_reset_is_not_part_of_normal_setup() {
  local setup_source
  setup_source="$(cat "$ROOT_DIR/scripts/setup.sh" "$ROOT_DIR/lib/setup-deployment-flow.sh")"
  assert_not_contains 'normal setup does not invoke openclaw reset command' "$setup_source" 'openclaw reset'
  assert_contains 'normal setup uses targeted config sync' "$setup_source" 'sync_openclaw_config'
}

run_test test_openclaw_help_and_unknown_subcommand
run_test test_openclaw_reset_defaults_no_without_replacement
run_test test_openclaw_reset_yes_backs_up_and_replaces_config
run_test test_openclaw_reset_is_not_part_of_normal_setup

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: openclaw command test suite succeeded\n'
  exit 0
fi

printf 'FAIL: openclaw command test suite failed with %s issues\n' "$FAILURES"
exit 1
