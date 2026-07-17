#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$BASE_DIR/.env"
ENV_EXAMPLE_FILE="$BASE_DIR/.env.example"
ENV_BACKUP_DECISION_MADE=false
ENV_BACKUP_ENABLED=false
VM_ALIAS_SYNC_HANDLED=false

source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/prompt.sh"
source "$BASE_DIR/lib/setup-env.sh"
source "$BASE_DIR/lib/setup-derive.sh"
source "$BASE_DIR/lib/setup-models.sh"
source "$BASE_DIR/lib/setup-embeddings.sh"
source "$BASE_DIR/lib/llama.sh"
source "$BASE_DIR/lib/ssh.sh"
source "$BASE_DIR/lib/runtime.sh"
source "$BASE_DIR/lib/deploy.sh"
source "$BASE_DIR/lib/qualify/history.sh"

RUNTIME_DIR="$BASE_DIR/vm/runtime"
CONFIG_PATH="$RUNTIME_DIR/openclaw.json"
REMOTE_CONFIG_DIR='~/.openclaw'
REMOTE_CONFIG_PATH='~/.openclaw/openclaw.json'
GENERATE_SCRIPT="$BASE_DIR/host/scripts/generate-openclaw-config.sh"

is_yes() {
  case "$1" in
    [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) return 0 ;;
    *) return 1 ;;
  esac
}

model_command_is_interactive() {
  [ -t 0 ]
}

model_qualification_available() {
  [ -x "$BASE_DIR/clawbox" ] && [ -x "$BASE_DIR/scripts/qualify.sh" ]
}

model_process_args_for_port() {
  local port="$1"
  local line=''

  if [ -n "${CLAWBOX_MODEL_PROCESS_ARGS_CMD:-}" ]; then
    "$CLAWBOX_MODEL_PROCESS_ARGS_CMD" "$port"
    return $?
  fi

  while IFS= read -r line; do
    case " $line " in
      *" --port $port "*|*" --port=$port "*)
        printf '%s\n' "$line"
        return 0
        ;;
    esac
  done <<EOF
$(pgrep -fl llama-server 2>/dev/null || true)
EOF

  return 1
}

model_path_from_process_args() {
  local args="$1"
  local previous=''
  local word=''

  for word in $args; do
    if [ "$previous" = '-m' ] || [ "$previous" = '--model' ]; then
      printf '%s\n' "$word"
      return 0
    fi
    case "$word" in
      -m*)
        [ "$word" = '-m' ] || {
          printf '%s\n' "${word#-m}"
          return 0
        }
        ;;
      --model=*)
        printf '%s\n' "${word#--model=}"
        return 0
        ;;
    esac
    previous="$word"
  done

  return 1
}

primary_model_matches_running_model() {
  local args=''
  local running_path=''

  [ -n "${MODEL_PATH:-}" ] || return 1
  [ -n "${LLAMA_PORT:-}" ] || return 1

  args="$(model_process_args_for_port "$LLAMA_PORT")" || return 1
  running_path="$(model_path_from_process_args "$args")" || return 1
  [ "$(basename "$running_path")" = "$(basename "$MODEL_PATH")" ]
}

run_qualification_suite_after_model_switch() {
  local profile="${1:-full}"
  "$BASE_DIR/clawbox" qualify --profile "$profile"
}

model_metadata_command() {
  local model="${1:-}" json=false args=()
  [ -n "$model" ] || { error 'Usage: ./clawbox model metadata <model> [--set-display-name <name>] [--add-role <role>] [--set-note <note>] [--preferred] [--json]'; return 1; }
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json)
        json=true
        shift
        ;;
      --set-display-name|--add-role|--set-note)
        [ "$#" -ge 2 ] || { error "Missing value for $1."; return 1; }
        args+=("$1" "$2")
        shift 2
        ;;
      --preferred)
        args+=("$1")
        shift
        ;;
      -h|--help)
        out 'Usage: ./clawbox model metadata <model> [--set-display-name <name>] [--add-role <role>] [--set-note <note>] [--preferred] [--json]'
        return 0
        ;;
      *)
        error "Unknown metadata option: $1"
        return 1
        ;;
    esac
  done
  qualify_history_require_python || return 2
  qualify_history_init || return 1
  qualify_history_python metadata "$(qualify_history_models_file)" "$model" "$json" "${args[@]}"
}

offer_qualification_after_primary_model_switch() {
  if ! model_command_is_interactive; then
    return 0
  fi

  if ! model_qualification_available; then
    return 0
  fi

  if ! primary_model_matches_running_model; then
    warn 'Qualification was not offered because the configured model does not match the running llama-server model.'
    out 'Run ./clawbox status and resolve the model inconsistency before qualifying this model.'
    return 0
  fi

  while true; do
    blank_line
    out 'Choose qualification:'
    out '  1) Fast (reduced test set)'
    out '  2) Full (complete suite)'
    out '  3) Skip'
    prompt_with_suffix 'Selection' '[1-3, default 3]' || return $?
    case "${REPLY:-}" in
      1)
        run_qualification_suite_after_model_switch fast
        return $?
        ;;
      2)
        run_qualification_suite_after_model_switch full
        return $?
        ;;
      ''|3|[Ss][Kk][Ii][Pp])
        out 'Qualification skipped. The selected model remains active.'
        return 0
        ;;
      *)
        error 'Invalid selection. Enter 1, 2, or 3.'
        ;;
    esac
  done
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

offer_openclaw_alias_migration() {
  local provider_name="${OPENCLAW_PROVIDER_NAME:-clawbox}"
  local model_alias="${OPENCLAW_DEFAULT_MODEL:-local}"
  local old_reference="$provider_name/$model_alias"
  local new_reference="$provider_name/local"

  [ "$model_alias" != 'local' ] || return 0

  blank_line
  out 'OpenClaw is using a model-specific alias:'
  out "$old_reference"
  blank_line
  out 'Recommended stable alias:'
  out "$new_reference"
  blank_line
  prompt_yes_no 'Migrate ClawBox to the stable OpenClaw alias now?' 'n'
  is_yes "$REPLY" || return 0

  OPENCLAW_DEFAULT_MODEL='local'
  write_env_from_template || return $?
  source_env_file || return $?
  success "ClawBox .env now uses $new_reference."
  out 'The VM OpenClaw config still points to the old alias until explicitly synced.'
  VM_ALIAS_SYNC_HANDLED=true
  blank_line
  prompt_yes_no "Update the VM OpenClaw default model to $new_reference now?" 'n'
  if ! is_yes "$REPLY"; then
    out 'OpenClaw may continue using the old alias until its VM config is synced.'
    outf "Inspect it later with: ssh %s 'zsh -lc \"openclaw config get agents.defaults.model.primary\"'" "${VM_HOST:-<vm-user>@<vm-ip>}"
    return 0
  fi

  update_vm_openclaw_default_model "$old_reference" "$new_reference"
}

update_vm_openclaw_default_model() {
  local old_reference="$1"
  local new_reference="$2"
  local remote_command=''
  local actual_reference=''

  remote_command="openclaw config set agents.defaults.model.primary $(printf '%q' "$new_reference")"
  if ! ssh "$VM_HOST" "zsh -lc $(printf '%q' "$remote_command")"; then
    error 'The VM OpenClaw default model was not updated.'
    return 1
  fi
  actual_reference="$(ssh "$VM_HOST" "zsh -lc $(printf '%q' 'openclaw config get agents.defaults.model.primary')")" || return 1
  if [ "$actual_reference" != "$new_reference" ]; then
    error "VM OpenClaw default model verification failed; expected $new_reference, got $actual_reference."
    return 1
  fi
  success "VM OpenClaw default model changed from $old_reference to $new_reference."
  out 'Only agents.defaults.model.primary was updated; onboarding and custom settings were preserved.'
  offer_vm_openclaw_gateway_restart
}

vm_openclaw_restart_command() {
  printf '%s\n' 'launchctl kickstart -k gui/$(id -u)/com.clawbox.openclaw'
}

print_vm_openclaw_restart_command() {
  outf "  ssh %s 'zsh -lc \"launchctl kickstart -k gui/\$(id -u)/com.clawbox.openclaw\"'" "$VM_HOST"
}

print_vm_openclaw_restart_diagnostics() {
  out 'Diagnose the VM OpenClaw gateway with:'
  outf "  ssh %s 'zsh -lc \"launchctl print gui/\$(id -u)/com.clawbox.openclaw\"'" "$VM_HOST"
  outf "  ssh %s 'zsh -lc \"pgrep -fl openclaw; lsof -nP -iTCP:18789 -sTCP:LISTEN\"'" "$VM_HOST"
  out "  VM logs: ${VM_RUNTIME_PATH:-<VM_RUNTIME_PATH>}/logs/runtime/openclaw.out.log"
  out "           ${VM_RUNTIME_PATH:-<VM_RUNTIME_PATH>}/logs/runtime/openclaw.err.log"
}

wait_for_vm_openclaw_gateway() {
  local attempt=1

  while [ "$attempt" -le 30 ]; do
    if openclaw_runtime_has_launchd_gateway; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

warn_vm_openclaw_external_owner() {
  warn 'An OpenClaw gateway outside the ClawBox launchd service is already running.'
  out 'ClawBox will not stop that gateway automatically from this model command.'
  out 'To let ClawBox take over the gateway port, run on the VM:'
  out '  openclaw gateway stop'
  out '  launchctl bootout gui/$(id -u)/ai.openclaw.gateway'
  out 'Then restart the ClawBox service with:'
  print_vm_openclaw_restart_command
}

offer_vm_openclaw_gateway_restart() {
  local restart_command=''

  prompt_yes_no 'Restart the VM OpenClaw gateway now to apply this change?' 'y'
  if ! is_yes "$REPLY"; then
    out 'Restart the VM OpenClaw gateway later with:'
    print_vm_openclaw_restart_command
    return 0
  fi

  if openclaw_runtime_has_manual_process; then
    warn_vm_openclaw_external_owner
    print_vm_openclaw_restart_diagnostics
    return 0
  fi

  restart_command="$(vm_openclaw_restart_command)"
  if ssh "$VM_HOST" "zsh -lc $(printf '%q' "$restart_command")"; then
    step 'Waiting for VM OpenClaw gateway to restart...'
    if wait_for_vm_openclaw_gateway; then
      success 'VM OpenClaw gateway restarted and is running.'
    else
      warn 'VM OpenClaw gateway did not become healthy after restart.'
      if openclaw_runtime_has_manual_process; then
        warn_vm_openclaw_external_owner
      fi
      print_vm_openclaw_restart_diagnostics
    fi
  else
    warn 'VM OpenClaw gateway restart failed.'
    out 'Restart it manually with:'
    print_vm_openclaw_restart_command
    print_vm_openclaw_restart_diagnostics
  fi
}

offer_vm_openclaw_alias_sync_if_drift() {
  local intended_reference="${OPENCLAW_PROVIDER_NAME:-clawbox}/${OPENCLAW_DEFAULT_MODEL:-local}"
  local current_reference=''

  [ "${VM_ALIAS_SYNC_HANDLED:-false}" = true ] && return 0
  [ "${OPENCLAW_DEFAULT_MODEL:-local}" = 'local' ] || return 0
  if [ -z "${VM_HOST:-}" ]; then
    warn 'VM alias drift was not checked because VM_HOST is not configured. Continuing with host-only model behavior.'
    return 0
  fi
  if ! current_reference="$(ssh "$VM_HOST" "zsh -lc $(printf '%q' 'openclaw config get agents.defaults.model.primary')" 2>/dev/null)"; then
    warn 'VM alias drift was not checked because OpenClaw config could not be read over SSH. Continuing with host-only model behavior.'
    return 0
  fi
  [ "$current_reference" = "$intended_reference" ] && return 0

  blank_line
  out 'The VM OpenClaw config currently uses:'
  out "$current_reference"
  blank_line
  out 'ClawBox is configured to use:'
  out "$intended_reference"
  blank_line
  prompt_yes_no "Update the VM OpenClaw default model to $intended_reference now?" 'n'
  if is_yes "$REPLY"; then
    update_vm_openclaw_default_model "$current_reference" "$intended_reference"
  else
    out 'OpenClaw may continue using the old alias until VM sync is performed.'
  fi
}

sync_model_openclaw_config_scope() {
  local scope="$1"

  if ! sync_openclaw_config_targeted_only "$scope"; then
    warn 'Host model switch completed, but optional OpenClaw provider metadata sync did not finish.'
    out 'OpenClaw remains pointed at the configured stable model reference.'
    out 'Run ./clawbox setup to retry targeted config sync, or ./clawbox openclaw reset for an explicit full reset.'
    return 0
  fi
  if ! offer_targeted_openclaw_config_restart; then
    warn 'OpenClaw restart guidance did not complete, but host model switching is finished.'
    return 0
  fi
}

switch_primary_model() {
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
  offer_openclaw_alias_migration || return $?
  offer_vm_openclaw_alias_sync_if_drift || return $?
  blank_line
  prompt_yes_no 'Switch models?' 'n'
  is_yes "$REPLY" || { out 'Model switch cancelled; host model is unchanged.'; return 0; }

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
  sync_model_openclaw_config_scope primary
  success "Host llama-server now uses ${MODEL_PATH##*/}."
  out "Selected GGUF: $MODEL_PATH"
  out "Advertised OpenClaw model: ${OPENCLAW_PROVIDER_NAME:-clawbox}/${OPENCLAW_DEFAULT_MODEL:-local}"
  out "llama-server API: ${LLAMA_BASE_URL:-not configured}"
  if [ "${CONFIG_TARGETED_UPDATED:-false}" = true ]; then
    out 'OpenClaw config was not replaced; only ClawBox-managed primary keys were synced.'
  elif [ "${CONFIG_TARGETED_NO_CHANGE:-false}" = true ]; then
    out 'OpenClaw config already matched; no OpenClaw changes were made.'
  fi
  out 'Check status with: ./clawbox status'
  offer_qualification_after_primary_model_switch
}

main() {
  local target="${1:-}"
  if [ "$target" = metadata ]; then
    shift || true
    model_metadata_command "$@"
    return $?
  fi
  [ -f "$ENV_FILE" ] || { error 'Missing .env. Run ./clawbox setup first.'; return 1; }
  source_env_file || return $?
  case "$target" in
    embedding|embeddings) switch_embeddings_model ;;
    primary) switch_primary_model ;;
    '')
      section 'Host Models'
      out "Primary model: ${MODEL_PATH:-not configured}"
      out "Embeddings model: ${EMBEDDINGS_MODEL_PATH:-not configured}"
      out '1) Switch primary chat/inference model'
      out '2) Configure or switch embeddings model'
      prompt_with_suffix 'Choose model operation' '[1-2]'
      case "$REPLY" in 1|'') switch_primary_model;; 2) switch_embeddings_model;; *) error 'Invalid model operation.'; return 1;; esac
      ;;
    *) error 'Usage: ./clawbox model [primary|embedding|embeddings]'; return 1;;
  esac
}

if [ "${CLAWBOX_MODEL_LIB_ONLY:-false}" != true ]; then
  main "$@"
fi
