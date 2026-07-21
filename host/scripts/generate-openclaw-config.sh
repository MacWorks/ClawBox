#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="$BASE_DIR/.env"
RUNTIME_DIR="$BASE_DIR/vm/runtime"
CONFIG_PATH="$RUNTIME_DIR/openclaw.json"

require_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "Missing required file: $path"
    exit 1
  fi
}

require_value() {
  local name="$1"
  local value="${!name:-}"
  if [ -z "$value" ]; then
    echo "Missing required value in .env: $name"
    exit 1
  fi
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Required command not found: $name"
    exit 1
  fi
}

json_escape() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

validate_json_file() {
  local path="$1"
  python3 -c 'import json, sys; json.load(open(sys.argv[1], "r", encoding="utf-8"))' "$path"
}

require_file "$ENV_FILE"
require_command "python3"

set -a
. "$ENV_FILE"
set +a

require_value "LLAMA_BASE_URL"
require_value "LLAMA_CTX"
require_value "OPENCLAW_PROVIDER_NAME"
require_value "OPENCLAW_DEFAULT_MODEL"

OPENCLAW_GATEWAY_MODE_VALUE="${OPENCLAW_GATEWAY_MODE:-local}"
LLAMA_CONTEXT_WINDOW_VALUE="$LLAMA_CTX"
LLAMA_CONTEXT_WINDOW_RAW_VALUE="$LLAMA_CTX"
OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE="${OPENCLAW_EFFECTIVE_CONTEXT_WINDOW:-}"
OPENCLAW_MAX_TOKENS_VALUE="${OPENCLAW_MAX_TOKENS:-8192}"
OPENCLAW_GATEWAY_AUTH_TOKEN_VALUE="${OPENCLAW_GATEWAY_AUTH_TOKEN:-}"

case "$OPENCLAW_GATEWAY_MODE_VALUE" in
  local|remote)
    ;;
  "")
    OPENCLAW_GATEWAY_MODE_VALUE="local"
    ;;
  *)
    echo "Invalid OPENCLAW_GATEWAY_MODE, defaulting to 'local'"
    OPENCLAW_GATEWAY_MODE_VALUE="local"
    ;;
esac

case "$LLAMA_CONTEXT_WINDOW_VALUE" in
  *[!0-9]*)
    echo "Invalid LLAMA_CTX value in .env: $LLAMA_CTX"
    exit 1
    ;;
  *)
    if [ "$LLAMA_CONTEXT_WINDOW_VALUE" -lt 16000 ]; then
      echo "LLAMA_CTX below minimum, defaulting contextWindow to 16384"
      LLAMA_CONTEXT_WINDOW_VALUE="16384"
    fi
    ;;
esac

case "$OPENCLAW_MAX_TOKENS_VALUE" in
  ''|*[!0-9]*)
    echo "Invalid OPENCLAW_MAX_TOKENS value in .env: ${OPENCLAW_MAX_TOKENS:-}"
    exit 1
    ;;
  *)
    if [ "$OPENCLAW_MAX_TOKENS_VALUE" -lt 1 ]; then
      echo "Invalid OPENCLAW_MAX_TOKENS value in .env: $OPENCLAW_MAX_TOKENS_VALUE"
      exit 1
    fi
    ;;
esac

if [ -n "$OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE" ]; then
  case "$OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE" in
    *[!0-9]*)
      echo "Invalid OPENCLAW_EFFECTIVE_CONTEXT_WINDOW value: $OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE"
      exit 1
      ;;
    *)
      if [ "$OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE" -lt 1 ]; then
        echo "Invalid OPENCLAW_EFFECTIVE_CONTEXT_WINDOW value: $OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE"
        exit 1
      fi
      if [ "$OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE" -lt "$LLAMA_CONTEXT_WINDOW_VALUE" ]; then
        LLAMA_CONTEXT_WINDOW_VALUE="$OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE"
      fi
      ;;
  esac
fi

if [ -n "$OPENCLAW_EFFECTIVE_CONTEXT_WINDOW_VALUE" ]; then
  if [ "$OPENCLAW_MAX_TOKENS_VALUE" -ge "$LLAMA_CONTEXT_WINDOW_VALUE" ]; then
    echo "Invalid OpenClaw token configuration: OPENCLAW_MAX_TOKENS=$OPENCLAW_MAX_TOKENS_VALUE must be less than effective contextWindow=$LLAMA_CONTEXT_WINDOW_VALUE"
    echo "Increase LLAMA_CTX or lower OPENCLAW_MAX_TOKENS, then rerun ./clawbox setup."
    exit 1
  fi
else
  if [ "$OPENCLAW_MAX_TOKENS_VALUE" -ge "$LLAMA_CONTEXT_WINDOW_RAW_VALUE" ]; then
    echo "Invalid OpenClaw token configuration in .env: OPENCLAW_MAX_TOKENS=$OPENCLAW_MAX_TOKENS_VALUE must be less than LLAMA_CTX=$LLAMA_CONTEXT_WINDOW_RAW_VALUE"
    echo "Increase LLAMA_CTX or lower OPENCLAW_MAX_TOKENS, then rerun ./clawbox setup."
    exit 1
  fi
fi

mkdir -p "$RUNTIME_DIR"

if [ -z "$OPENCLAW_GATEWAY_AUTH_TOKEN_VALUE" ]; then
  OPENCLAW_GATEWAY_AUTH_TOKEN_VALUE="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
fi

export OPENCLAW_GATEWAY_MODE_VALUE LLAMA_CONTEXT_WINDOW_VALUE OPENCLAW_MAX_TOKENS_VALUE OPENCLAW_GATEWAY_AUTH_TOKEN_VALUE

python3 - "$CONFIG_PATH" <<'PY'
import json
import os
import sys

provider = os.environ["OPENCLAW_PROVIDER_NAME"]
model = os.environ["OPENCLAW_DEFAULT_MODEL"]
config = {
    "gateway": {
        "mode": os.environ["OPENCLAW_GATEWAY_MODE_VALUE"],
        "auth": {"token": os.environ["OPENCLAW_GATEWAY_AUTH_TOKEN_VALUE"]},
    },
    "agents": {"defaults": {"model": {"primary": f"{provider}/{model}"}}},
    "tools": {"deny": ["cron"]},
    "models": {"providers": {provider: {
        "baseUrl": os.environ["LLAMA_BASE_URL"],
        "api": "openai-completions",
        "models": [{
            "id": model,
            "name": model,
            "contextWindow": int(os.environ["LLAMA_CONTEXT_WINDOW_VALUE"]),
            "maxTokens": int(os.environ["OPENCLAW_MAX_TOKENS_VALUE"]),
            "compat": {
                "supportsDeveloperRole": False,
                "unsupportedToolSchemaKeywords": [
                    "pattern",
                    "additionalProperties",
                ],
            },
            "api": "openai-completions",
        }],
    }}},
}

if os.environ.get("EMBEDDINGS_ENABLED", "false") == "true" and os.environ.get("EMBEDDINGS_MODEL_PATH"):
    config["agents"]["defaults"]["memorySearch"] = {
        "enabled": True,
        "provider": "openai-compatible",
        "model": os.path.basename(os.environ["EMBEDDINGS_MODEL_PATH"]),
        "remote": {
            "baseUrl": os.environ.get("EMBEDDINGS_LLAMA_BASE_URL", ""),
            "apiKey": "ollama-local",
        },
    }

with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(config, output, indent=2)
    output.write("\n")
PY

validate_json_file "$CONFIG_PATH"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Failed to write OpenClaw config: $CONFIG_PATH"
  exit 1
fi

echo ""
echo " Generated minimal OpenClaw config: $CONFIG_PATH"
