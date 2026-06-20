#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$BASE_DIR/.env"
ENV_EXAMPLE_FILE="$BASE_DIR/.env.example"
ENV_BACKUP_DECISION_MADE=false
ENV_BACKUP_ENABLED=false

source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/prompt.sh"
source "$BASE_DIR/lib/setup-env.sh"
source "$BASE_DIR/lib/setup-derive.sh"
source "$BASE_DIR/lib/setup-models.sh"
source "$BASE_DIR/lib/llama.sh"

is_yes() {
  case "$1" in
    [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) return 0 ;;
    *) return 1 ;;
  esac
}

detect_model_llama_mode() {
  if [ -f "$(llama_system_plist_dest)" ] || [ -f "$(llama_system_env_dest)" ]; then
    REPLY='system'
  elif [ -f "$(llama_user_plist_dest)" ] || [ -f "$(llama_user_env_dest)" ]; then
    REPLY='user'
  else
    error 'No managed ClawBox llama-server service was found. Re-run ./clawbox setup.'
    return 1
  fi
}

main() {
  [ -f "$ENV_FILE" ] || { error 'Missing .env. Run ./clawbox setup first.'; return 1; }
  source_env_file || return $?

  section 'Host Model'
  out "Current model: ${MODEL_PATH:-not configured}"
  out "Model file: $(basename "${MODEL_PATH:-not configured}")"
  out "llama-server port: ${LLAMA_PORT:-not configured}"
  out "llama-server API: ${LLAMA_BASE_URL:-not configured}"
  out "OpenClaw provider: ${OPENCLAW_PROVIDER_NAME:-clawbox}"
  out "OpenClaw model alias: ${OPENCLAW_DEFAULT_MODEL:-local}"
  out "OpenClaw model reference: ${OPENCLAW_PROVIDER_NAME:-clawbox}/${OPENCLAW_DEFAULT_MODEL:-local}"
  blank_line
  prompt_yes_no 'Switch models?' 'n'
  is_yes "$REPLY" || { out 'Model switch cancelled.'; return 0; }

  setup_configure_model_selection || return $?
  OPENCLAW_DEFAULT_MODEL="${OPENCLAW_DEFAULT_MODEL:-local}"
  write_env_from_template || return $?
  source_env_file || return $?

  detect_model_llama_mode || return $?
  if ! setup_llama_service_for_mode "$REPLY"; then
    error 'The model path was saved, but llama-server did not restart successfully.'
    out 'Review the llama-server logs, correct the host service, then run ./clawbox model again.'
    return 1
  fi
  success "Host llama-server now uses ${MODEL_PATH##*/}."
  out "Selected GGUF: $MODEL_PATH"
  out "Advertised OpenClaw model: ${OPENCLAW_PROVIDER_NAME:-clawbox}/${OPENCLAW_DEFAULT_MODEL:-local}"
  out "llama-server API: ${LLAMA_BASE_URL:-not configured}"
  out 'OpenClaw configuration and VM runtime were not changed.'
  out 'Check status with: ./clawbox status'
}

main "$@"
