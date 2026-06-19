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

mkdir -p "$RUNTIME_DIR"

MODEL_REF="${OPENCLAW_PROVIDER_NAME}/${OPENCLAW_DEFAULT_MODEL}"

cat > "$CONFIG_PATH" <<EOF
{
  "gateway": {
    "mode": $(json_escape "$OPENCLAW_GATEWAY_MODE_VALUE")
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": $(json_escape "$MODEL_REF")
      }
    }
  },
  "models": {
    "providers": {
      $(json_escape "$OPENCLAW_PROVIDER_NAME"): {
        "baseUrl": $(json_escape "$LLAMA_BASE_URL"),
        "api": "openai-responses",
        "models": [
          {
            "id": $(json_escape "$OPENCLAW_DEFAULT_MODEL"),
            "name": $(json_escape "$OPENCLAW_DEFAULT_MODEL"),
            "contextWindow": $LLAMA_CONTEXT_WINDOW_VALUE,
            "maxTokens": 2048,
            "compat": {
              "supportsDeveloperRole": false
            }
          }
        ]
      }
    }
  }
}
EOF

validate_json_file "$CONFIG_PATH"

if [ ! -f "$CONFIG_PATH" ]; then
  echo "Failed to write OpenClaw config: $CONFIG_PATH"
  exit 1
fi

echo ""
echo " Generated minimal OpenClaw config: $CONFIG_PATH"