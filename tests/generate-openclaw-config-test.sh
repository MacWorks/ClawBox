#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=/dev/null
. "$ROOT_DIR/tests/helpers/setup-harness.sh"

trap cleanup_temp_dir EXIT

TEMP_DIR="$(mktemp -d)"
GENERATOR_LAST_OUTPUT=''
GENERATOR_LAST_STATUS=0

setup_generator_fixture() {
  local fixture_root="$TEMP_DIR/generator-fixture"

  rm -rf "$fixture_root"
  mkdir -p "$fixture_root/host/scripts" "$fixture_root/vm/runtime"

  cp "$ROOT_DIR/host/scripts/generate-openclaw-config.sh" "$fixture_root/host/scripts/generate-openclaw-config.sh"
  chmod +x "$fixture_root/host/scripts/generate-openclaw-config.sh"

  REPLY="$fixture_root"
}

write_fixture_env() {
  local fixture_root="$1"
  local llama_base_url="$2"
  local llama_ctx="$3"
  local provider_name="$4"
  local default_model="$5"
  local gateway_mode="${6:-}"
  local embeddings_enabled="${7:-false}"
  local embeddings_model_path="${8:-}"
  local embeddings_base_url="${9:-}"
  local openclaw_max_tokens="${10:-8192}"

  cat > "$fixture_root/.env" <<EOF
LLAMA_BASE_URL="$llama_base_url"
LLAMA_CTX="$llama_ctx"
OPENCLAW_PROVIDER_NAME="$provider_name"
OPENCLAW_DEFAULT_MODEL="$default_model"
OPENCLAW_GATEWAY_MODE="$gateway_mode"
OPENCLAW_MAX_TOKENS="$openclaw_max_tokens"
EMBEDDINGS_ENABLED="$embeddings_enabled"
EMBEDDINGS_MODEL_PATH="$embeddings_model_path"
EMBEDDINGS_LLAMA_BASE_URL="$embeddings_base_url"
EOF
}

run_generator() {
  local fixture_root="$1"

  set +e
  GENERATOR_LAST_OUTPUT="$(/bin/bash "$fixture_root/host/scripts/generate-openclaw-config.sh" 2>&1)"
  GENERATOR_LAST_STATUS=$?
  set -e
}

json_query() {
  local fixture_root="$1"
  local dotted_path="$2"

  REPLY="$(python3 - "$fixture_root/vm/runtime/openclaw.json" "$dotted_path" <<'PY'
import json
import sys

with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    value = json.load(handle)

for key in sys.argv[2].split('.'):
    value = value[int(key)] if key.isdigit() else value[key]

if isinstance(value, bool):
    print(str(value).lower())
else:
    print(value)
PY
)"
}

test_generate_openclaw_config_writes_expected_config() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '20000' 'clawbox' 'sample-model' 'remote'

  run_generator "$fixture_root"

  assert_equals 'generator succeeds with a complete env file' "$GENERATOR_LAST_STATUS" '0'
  assert_contains 'generator reports the output path' "$GENERATOR_LAST_OUTPUT" 'Generated minimal OpenClaw config:'

  json_query "$fixture_root" 'gateway.mode'
  assert_equals 'generator writes the configured gateway mode' "$REPLY" 'remote'

  json_query "$fixture_root" 'gateway.auth.token'
  if [ -n "$REPLY" ] && [ "$REPLY" != 'null' ]; then
    pass 'generator writes persistent gateway authentication token'
  else
    fail 'generator should write persistent gateway authentication token'
  fi

  json_query "$fixture_root" 'agents.defaults.model.primary'
  assert_equals 'generator writes the provider-qualified primary model' "$REPLY" 'clawbox/sample-model'

  json_query "$fixture_root" 'models.providers.clawbox.baseUrl'
  assert_equals 'generator writes the configured llama base url' "$REPLY" 'http://127.0.0.1:11434'

  json_query "$fixture_root" 'models.providers.clawbox.models.0.id'
  assert_equals 'generator writes the configured model id' "$REPLY" 'sample-model'

  json_query "$fixture_root" 'models.providers.clawbox.models.0.contextWindow'
  assert_equals 'generator preserves a valid configured context window' "$REPLY" '20000'

  json_query "$fixture_root" 'models.providers.clawbox.models.0.maxTokens'
  assert_equals 'generator writes the default managed OpenClaw maxTokens' "$REPLY" '8192'

  json_query "$fixture_root" 'models.providers.clawbox.api'
  assert_equals 'generator uses the OpenAI completions provider API' "$REPLY" 'openai-completions'

  json_query "$fixture_root" 'models.providers.clawbox.models.0.api'
  assert_equals 'generator includes completions API compatibility on the local model' "$REPLY" 'openai-completions'

  json_query "$fixture_root" 'tools.deny.0'
  assert_equals 'generator denies incompatible cron tool for local llama.cpp model' "$REPLY" 'cron'

  json_query "$fixture_root" 'models.providers.clawbox.models.0.compat.supportsDeveloperRole'
  assert_equals 'generator keeps developer-role compatibility disabled for local llama.cpp model' "$REPLY" 'false'

  REPLY="$(python3 - "$fixture_root/vm/runtime/openclaw.json" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)
keywords = data["models"]["providers"]["clawbox"]["models"][0]["compat"]["unsupportedToolSchemaKeywords"]
print("pattern" in keywords and "additionalProperties" in keywords)
PY
)"
  assert_equals 'generator marks required JSON Schema keywords unsupported for local llama.cpp model' "$REPLY" 'True'
}

test_generate_openclaw_config_supports_custom_max_tokens() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '20000' 'clawbox' 'sample-model' 'local' \
    'false' '' '' '12288'

  run_generator "$fixture_root"

  assert_equals 'generator succeeds with a custom OPENCLAW_MAX_TOKENS value' "$GENERATOR_LAST_STATUS" '0'
  json_query "$fixture_root" 'models.providers.clawbox.models.0.maxTokens'
  assert_equals 'generator writes configured OpenClaw maxTokens numerically' "$REPLY" '12288'
}

test_generate_openclaw_config_uses_effective_context_window_when_known() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '65536' 'clawbox' 'sample-model' 'local'

  OPENCLAW_EFFECTIVE_CONTEXT_WINDOW='32768' run_generator "$fixture_root"

  assert_equals 'generator succeeds with an effective llama-server context window' "$GENERATOR_LAST_STATUS" '0'
  json_query "$fixture_root" 'models.providers.clawbox.models.0.contextWindow'
  assert_equals 'generator caps OpenClaw contextWindow to effective llama-server context' "$REPLY" '32768'
}

test_generate_openclaw_config_rejects_max_tokens_at_effective_context_window() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '65536' 'clawbox' 'sample-model' 'local' \
    'false' '' '' '32768'

  OPENCLAW_EFFECTIVE_CONTEXT_WINDOW='32768' run_generator "$fixture_root"

  assert_equals 'generator rejects maxTokens equal to effective context window' "$GENERATOR_LAST_STATUS" '1'
  assert_contains 'generator reports maxTokens and effective context conflict' "$GENERATOR_LAST_OUTPUT" 'OPENCLAW_MAX_TOKENS=32768 must be less than effective contextWindow=32768'
}

test_generate_openclaw_config_defaults_missing_max_tokens() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '20000' 'clawbox' 'sample-model' 'local'
  python3 - "$fixture_root/.env" <<'PY'
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    lines = [line for line in handle if not line.startswith("OPENCLAW_MAX_TOKENS=")]
with open(path, "w", encoding="utf-8") as handle:
    handle.writelines(lines)
PY

  run_generator "$fixture_root"

  assert_equals 'generator remains backward compatible when OPENCLAW_MAX_TOKENS is missing' "$GENERATOR_LAST_STATUS" '0'
  json_query "$fixture_root" 'models.providers.clawbox.models.0.maxTokens'
  assert_equals 'generator defaults missing OpenClaw maxTokens to 8192' "$REPLY" '8192'
}

test_generate_openclaw_config_rejects_invalid_max_tokens() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '20000' 'clawbox' 'sample-model' 'local' \
    'false' '' '' 'wide'

  run_generator "$fixture_root"

  assert_equals 'generator rejects non-numeric OPENCLAW_MAX_TOKENS' "$GENERATOR_LAST_STATUS" '1'
  assert_contains 'generator reports invalid OPENCLAW_MAX_TOKENS' "$GENERATOR_LAST_OUTPUT" 'Invalid OPENCLAW_MAX_TOKENS value in .env: wide'

  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '20000' 'clawbox' 'sample-model' 'local' \
    'false' '' '' '0'
  run_generator "$fixture_root"

  assert_equals 'generator rejects zero OPENCLAW_MAX_TOKENS' "$GENERATOR_LAST_STATUS" '1'
  assert_contains 'generator reports non-positive OPENCLAW_MAX_TOKENS' "$GENERATOR_LAST_OUTPUT" 'Invalid OPENCLAW_MAX_TOKENS value in .env: 0'

  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '8192' 'clawbox' 'sample-model' 'local' \
    'false' '' '' '8192'
  run_generator "$fixture_root"

  assert_equals 'generator rejects OPENCLAW_MAX_TOKENS equal to LLAMA_CTX' "$GENERATOR_LAST_STATUS" '1'
  assert_contains 'generator reports max token and context values' "$GENERATOR_LAST_OUTPUT" 'OPENCLAW_MAX_TOKENS=8192 must be less than LLAMA_CTX=8192'
}

test_generate_openclaw_config_defaults_invalid_gateway_mode_to_local() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '20000' 'clawbox' 'sample-model' 'sideways'

  run_generator "$fixture_root"

  assert_equals 'generator succeeds when gateway mode needs normalization' "$GENERATOR_LAST_STATUS" '0'
  assert_contains 'generator explains invalid gateway mode fallback' "$GENERATOR_LAST_OUTPUT" "Invalid OPENCLAW_GATEWAY_MODE, defaulting to 'local'"

  json_query "$fixture_root" 'gateway.mode'
  assert_equals 'generator falls back invalid gateway mode to local' "$REPLY" 'local'
}

test_generate_openclaw_config_enforces_minimum_context_window() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '8000' 'clawbox' 'sample-model' 'local' \
    'false' '' '' '4096'

  run_generator "$fixture_root"

  assert_equals 'generator succeeds when LLAMA_CTX needs minimum clamping' "$GENERATOR_LAST_STATUS" '0'
  assert_contains 'generator explains LLAMA_CTX minimum fallback' "$GENERATOR_LAST_OUTPUT" 'LLAMA_CTX below minimum, defaulting contextWindow to 16384'

  json_query "$fixture_root" 'models.providers.clawbox.models.0.contextWindow'
  assert_equals 'generator clamps undersized LLAMA_CTX to 16384' "$REPLY" '16384'
}

test_generate_openclaw_config_rejects_non_numeric_context_window() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' 'fast' 'clawbox' 'sample-model' 'local'

  run_generator "$fixture_root"

  assert_equals 'generator rejects non-numeric LLAMA_CTX' "$GENERATOR_LAST_STATUS" '1'
  assert_contains 'generator reports invalid LLAMA_CTX' "$GENERATOR_LAST_OUTPUT" 'Invalid LLAMA_CTX value in .env: fast'
}

test_generate_openclaw_config_requires_llama_base_url() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" '' '20000' 'clawbox' 'sample-model' 'local'

  run_generator "$fixture_root"

  assert_equals 'generator requires LLAMA_BASE_URL' "$GENERATOR_LAST_STATUS" '1'
  assert_contains 'generator reports missing LLAMA_BASE_URL' "$GENERATOR_LAST_OUTPUT" 'Missing required value in .env: LLAMA_BASE_URL'
}

test_generate_openclaw_config_supports_custom_provider_name() {
  local fixture_root
  local provider_name='custom-provider'

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '20000' "$provider_name" 'sample-model' 'remote'

  run_generator "$fixture_root"

  assert_equals 'generator supports custom provider names' "$GENERATOR_LAST_STATUS" '0'

  json_query "$fixture_root" 'agents.defaults.model.primary'
  assert_equals 'generator writes the custom provider-qualified primary model' "$REPLY" "$provider_name/sample-model"

  json_query "$fixture_root" 'models.providers.custom-provider.baseUrl'
  assert_equals 'generator writes the configured llama base url under the custom provider key' "$REPLY" 'http://127.0.0.1:11434'

  json_query "$fixture_root" 'models.providers.custom-provider.models.0.id'
  assert_equals 'generator writes the configured model id under the custom provider key' "$REPLY" 'sample-model'
}

test_generate_openclaw_config_supports_stable_local_alias() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434' '20000' 'clawbox' 'local' 'local'
  run_generator "$fixture_root"
  json_query "$fixture_root" 'agents.defaults.model.primary'
  assert_equals 'generator advertises the stable default model alias' "$REPLY" 'clawbox/local'

  run_generator "$fixture_root"
  assert_equals 'generator rerun remains idempotent' "$GENERATOR_LAST_STATUS" '0'
  REPLY="$(python3 - "$fixture_root/vm/runtime/openclaw.json" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    data = json.load(handle)
keywords = data["models"]["providers"]["clawbox"]["models"][0]["compat"]["unsupportedToolSchemaKeywords"]
denied = data["tools"]["deny"]
print(keywords.count("pattern"), keywords.count("additionalProperties"), denied.count("cron"))
PY
)"
  assert_equals 'generator rerun does not duplicate unsupported schema keywords or cron deny' "$REPLY" '1 1 1'
}

test_generate_openclaw_config_includes_embeddings_memory_search_when_enabled() {
  local fixture_root

  setup_generator_fixture
  fixture_root="$REPLY"
  write_fixture_env "$fixture_root" 'http://127.0.0.1:11434/v1' '32768' 'clawbox' 'local' 'local' \
    'true' '/models/bge-large-en-v1.5-f16.gguf' 'http://127.0.0.1:11435/v1'
  run_generator "$fixture_root"

  assert_equals 'generator succeeds with embeddings memory search enabled' "$GENERATOR_LAST_STATUS" '0'
  json_query "$fixture_root" 'agents.defaults.model.primary'
  assert_equals 'reset/minimal config keeps stable primary alias with embeddings enabled' "$REPLY" 'clawbox/local'
  json_query "$fixture_root" 'agents.defaults.memorySearch.enabled'
  assert_equals 'generator enables OpenClaw memorySearch for embeddings' "$REPLY" 'true'
  json_query "$fixture_root" 'agents.defaults.memorySearch.provider'
  assert_equals 'generator uses openai-compatible memorySearch provider' "$REPLY" 'openai-compatible'
  json_query "$fixture_root" 'agents.defaults.memorySearch.model'
  assert_equals 'generator uses embeddings model basename for memorySearch model' "$REPLY" 'bge-large-en-v1.5-f16.gguf'
  json_query "$fixture_root" 'agents.defaults.memorySearch.remote.baseUrl'
  assert_equals 'generator points memorySearch at embeddings base URL' "$REPLY" 'http://127.0.0.1:11435/v1'
  json_query "$fixture_root" 'agents.defaults.memorySearch.remote.apiKey'
  assert_equals 'generator uses local/LAN memorySearch API-key marker' "$REPLY" 'ollama-local'
}

printf 'Running generate-openclaw-config tests\n'

run_test test_generate_openclaw_config_writes_expected_config
run_test test_generate_openclaw_config_supports_custom_max_tokens
run_test test_generate_openclaw_config_uses_effective_context_window_when_known
run_test test_generate_openclaw_config_rejects_max_tokens_at_effective_context_window
run_test test_generate_openclaw_config_defaults_missing_max_tokens
run_test test_generate_openclaw_config_rejects_invalid_max_tokens
run_test test_generate_openclaw_config_defaults_invalid_gateway_mode_to_local
run_test test_generate_openclaw_config_enforces_minimum_context_window
run_test test_generate_openclaw_config_rejects_non_numeric_context_window
run_test test_generate_openclaw_config_requires_llama_base_url
run_test test_generate_openclaw_config_supports_custom_provider_name
run_test test_generate_openclaw_config_supports_stable_local_alias
run_test test_generate_openclaw_config_includes_embeddings_memory_search_when_enabled

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
