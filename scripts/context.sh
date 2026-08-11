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
source "$BASE_DIR/lib/llama.sh"
source "$BASE_DIR/lib/ssh.sh"
source "$BASE_DIR/lib/runtime.sh"
source "$BASE_DIR/lib/deploy.sh"

RUNTIME_DIR="$BASE_DIR/vm/runtime"
CONFIG_PATH="$RUNTIME_DIR/openclaw.json"
REMOTE_CONFIG_DIR='~/.openclaw'
REMOTE_CONFIG_PATH='~/.openclaw/openclaw.json'
GENERATE_SCRIPT="$BASE_DIR/host/scripts/generate-openclaw-config.sh"

show_context_help() {
  cat <<EOF
Usage:
  ./clawbox context
  ./clawbox context <context-size>

Show or change the primary llama-server context size.

Examples:
  ./clawbox context
  ./clawbox context 131072
EOF
}

context_command_is_interactive() {
  [ -t 0 ]
}

detect_context_llama_mode() {
  if [ -f "$(llama_system_plist_dest)" ] || [ -f "$(llama_system_env_dest)" ]; then
    REPLY='system'
  elif [ -f "$(llama_user_plist_dest)" ] || [ -f "$(llama_user_env_dest)" ]; then
    REPLY='user'
  else
    error 'No managed ClawBox llama-server service was found. Re-run ./clawbox setup.'
    return 1
  fi
}

context_native_window() {
  REPLY=''
  [ -n "${MODEL_PATH:-}" ] || return 1
  REPLY="$(gguf_native_context_from_file "$MODEL_PATH" 2>/dev/null || true)"
  [ -n "$REPLY" ]
}

context_openclaw_context_window_from_models() {
  local models="$1"
  local model_id="${2:-${OPENCLAW_DEFAULT_MODEL:-local}}"

  python3 - "$models" "$model_id" <<'PY'
import json, sys
try:
    models = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
for model in models if isinstance(models, list) else []:
    if isinstance(model, dict) and model.get("id") == sys.argv[2]:
        value = model.get("contextWindow")
        try:
            print(int(value))
            raise SystemExit(0)
        except Exception:
            raise SystemExit(1)
raise SystemExit(1)
PY
}

context_current_openclaw_window() {
  local provider="${OPENCLAW_PROVIDER_NAME:-clawbox}"
  local models=''

  REPLY=''
  [ -n "${VM_HOST:-}" ] || return 1
  models="$(openclaw_config_remote_get "models.providers.$provider.models" 2>/dev/null || true)"
  [ -n "$models" ] || return 1
  REPLY="$(context_openclaw_context_window_from_models "$models" "${OPENCLAW_DEFAULT_MODEL:-local}" 2>/dev/null || true)"
  [ -n "$REPLY" ]
}

context_print_state() {
  local native='' runtime='' openclaw=''

  context_native_window >/dev/null 2>&1 || true
  native="$REPLY"
  if llama_detect_effective_context_window >/dev/null 2>&1; then
    runtime="$REPLY"
  fi
  context_current_openclaw_window >/dev/null 2>&1 || true
  openclaw="$REPLY"

  section 'Primary Context'
  out "Model: ${MODEL_PATH:-not configured}"
  out "Model native context: ${native:-unknown}"
  out "Configured LLAMA_CTX: ${LLAMA_CTX:-unknown}"
  out "Runtime context: ${runtime:-unknown}"
  out "OpenClaw contextWindow: ${openclaw:-unknown}"
}

context_apply_value() {
  local requested="$1"
  local native_context="${2:-}"
  local previous="${LLAMA_CTX:-}"
  local mode=''

  llama_context_validate_value "$requested" "$native_context" "${OPENCLAW_MAX_TOKENS:-8192}" './clawbox context' || return $?

  if [ "$requested" = "$previous" ]; then
    out "LLAMA_CTX is already $requested."
    return 0
  fi

  detect_context_llama_mode || return $?
  mode="$REPLY"

  LLAMA_CTX="$requested"
  write_env_from_template || return $?
  source_env_file || return $?

  if ! setup_llama_service_for_mode "$mode"; then
    error 'LLAMA_CTX was saved, but llama-server did not restart successfully.'
    out 'Review the llama-server logs, correct the host service, then rerun ./clawbox context.'
    return 1
  fi

  llama_refresh_openclaw_effective_context_window || return $?
  if ! sync_openclaw_config_targeted_only primary; then
    error 'LLAMA_CTX was saved and llama-server restarted, but OpenClaw contextWindow sync failed.'
    return 1
  fi
  offer_targeted_openclaw_config_restart || return $?

  success "Primary llama-server context is now $LLAMA_CTX."
  out "Check status with: ./clawbox status"
}

context_interactive() {
  local native_context=''

  context_print_state
  if ! context_command_is_interactive; then
    return 0
  fi

  blank_line
  prompt_yes_no 'Change primary context size?' 'n'
  is_yes "$REPLY" || { out 'Context unchanged.'; return 0; }

  context_native_window >/dev/null 2>&1 || true
  native_context="$REPLY"
  llama_context_prompt_value "${LLAMA_CTX:-}" "$native_context" "${OPENCLAW_MAX_TOKENS:-8192}" './clawbox context' || return $?
  context_apply_value "$REPLY" "$native_context"
}

main() {
  local requested="${1:-}" native_context=''

  case "$requested" in
    -h|--help|help)
      show_context_help
      return 0
      ;;
    --*)
      error "Unknown context option: $requested"
      show_context_help
      return 1
      ;;
  esac

  [ -f "$ENV_FILE" ] || { error 'Missing .env. Run ./clawbox setup first.'; return 1; }
  source_env_file || return $?

  if [ -z "$requested" ]; then
    context_interactive
    return $?
  fi

  context_native_window >/dev/null 2>&1 || true
  native_context="$REPLY"
  context_apply_value "$requested" "$native_context"
}

if [ "${CLAWBOX_CONTEXT_LIB_ONLY:-false}" != true ]; then
  main "$@"
fi
