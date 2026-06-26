#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

ENV_FILE="${CLAWBOX_ENV_FILE:-/usr/local/etc/clawbox.env}"

########################################
# Load Environment
########################################

if [ -f "$ENV_FILE" ]; then
  set -a
  . "$ENV_FILE"
  set +a
else
  echo "Missing env file: $ENV_FILE"
  exit 1
fi

if [ "${CLAWBOX_LLAMA_INSTANCE:-primary}" = 'embeddings' ]; then
  LLAMA_BIN="${EMBEDDINGS_LLAMA_BIN:-}"
  MODEL_PATH="${EMBEDDINGS_MODEL_PATH:-}"
  LLAMA_HOST="${EMBEDDINGS_LLAMA_HOST:-}"
  LLAMA_PORT="${EMBEDDINGS_LLAMA_PORT:-}"
  LLAMA_CTX="${EMBEDDINGS_LLAMA_CTX:-}"
  LLAMA_EXTRA_ARGS="${EMBEDDINGS_LLAMA_EXTRA_ARGS:-}"
fi

########################################
# Prevent Duplicate Instances
########################################

if lsof -i :"$LLAMA_PORT" >/dev/null 2>&1; then
  echo "llama-server already running on port $LLAMA_PORT, exiting wrapper"
  exit 0
fi

########################################
# Validate Paths
########################################

if [ ! -x "$LLAMA_BIN" ]; then
  echo "llama binary not found or not executable: $LLAMA_BIN"
  exit 1
fi

if [ ! -f "$MODEL_PATH" ]; then
  echo "model not found: $MODEL_PATH"
  exit 1
fi

########################################
# Start Server
########################################

LLAMA_ARGS=(
  -m "$MODEL_PATH"
  --host "$LLAMA_HOST"
  --port "$LLAMA_PORT"
  --ctx-size "$LLAMA_CTX"
)

if [[ "${LLAMA_EXTRA_ARGS:-}" == *[![:space:]]* ]]; then
  LLAMA_EXTRA_ARGS_ARRAY=()
  read -r -a LLAMA_EXTRA_ARGS_ARRAY <<< "$LLAMA_EXTRA_ARGS"
  exec "$LLAMA_BIN" "${LLAMA_ARGS[@]}" "${LLAMA_EXTRA_ARGS_ARRAY[@]}"
fi

exec "$LLAMA_BIN" "${LLAMA_ARGS[@]}"
