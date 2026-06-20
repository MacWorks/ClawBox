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

LLAMA_EXTRA_ARGS_ARRAY=()
if [ -n "${LLAMA_EXTRA_ARGS:-}" ]; then
  read -r -a LLAMA_EXTRA_ARGS_ARRAY <<< "$LLAMA_EXTRA_ARGS"
fi

exec "$LLAMA_BIN" \
  -m "$MODEL_PATH" \
  --host "$LLAMA_HOST" \
  --port "$LLAMA_PORT" \
  --ctx-size "$LLAMA_CTX" \
  "${LLAMA_EXTRA_ARGS_ARRAY[@]}"
