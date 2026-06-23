#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DEBUG_MODE=false
PARSED_ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--debug" ]; then
    DEBUG_MODE=true
  else
    PARSED_ARGS+=("$arg")
  fi
done
if [ "${#PARSED_ARGS[@]}" -gt 0 ]; then
  set -- "${PARSED_ARGS[@]}"
else
  set --
fi

source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/prompt.sh"
source "$BASE_DIR/lib/setup-env.sh"
source "$BASE_DIR/lib/setup-requirements.sh"
source "$BASE_DIR/lib/setup-derive.sh"
source "$BASE_DIR/lib/setup-models.sh"
source "$BASE_DIR/lib/llama.sh"
source "$BASE_DIR/lib/setup-llama-bin.sh"
source "$BASE_DIR/lib/setup-host-inference.sh"
source "$BASE_DIR/lib/setup-embeddings.sh"
source "$BASE_DIR/lib/setup-llama-prestart.sh"
source "$BASE_DIR/lib/setup-vm.sh"
source "$BASE_DIR/lib/setup-bootstrap.sh"
source "$BASE_DIR/lib/launchagent.sh"
source "$BASE_DIR/lib/ssh.sh"
source "$BASE_DIR/lib/setup-openclaw-provisioning.sh"
source "$BASE_DIR/lib/vm/vm-state.sh"
source "$BASE_DIR/lib/vm/vm-start.sh"
source "$BASE_DIR/lib/vm/vm-ssh.sh"
source "$BASE_DIR/lib/vm/vm-repair.sh"
source "$BASE_DIR/lib/runtime.sh"
source "$BASE_DIR/lib/setup-openclaw-recovery.sh"
source "$BASE_DIR/lib/config.sh"
source "$BASE_DIR/lib/deploy.sh"
source "$BASE_DIR/lib/setup-deployment-flow.sh"

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  install_status_exit_trap
fi

title 'ClawBox'

out 'This setup script will guide you through'
out 'configuring your environment for ClawBox.'
blank_line
out 'Values in brackets [] are derived from inputs,'
out 'from existing .env values, or sensible defaults.'

ENV_FILE="$BASE_DIR/.env"
ENV_EXAMPLE_FILE="$BASE_DIR/.env.example"
GENERATE_SCRIPT="$BASE_DIR/host/scripts/generate-openclaw-config.sh"
PROVISION_SCRIPT="$BASE_DIR/vm/vm-provision.sh"
RUNTIME_DIR="$BASE_DIR/vm/runtime"
CONFIG_PATH="$RUNTIME_DIR/openclaw.json"
REMOTE_CONFIG_DIR="~/.openclaw"
REMOTE_CONFIG_PATH="~/.openclaw/openclaw.json"
VM_REPAIR_MODE="${VM_REPAIR_MODE:-false}"
ENV_BOOTSTRAPPED=false
ENV_CREATED_FROM_EXAMPLE=false
ENV_BACKUP_DECISION_MADE=false
ENV_BACKUP_ENABLED=false
LLAMA_USE_EXISTING_INSTANCE=false
LLAMA_EXTERNAL=false
VM_SKIP_DETECTED_UTM_FLOW=false
# Preserve this dev-only switch before .env is sourced. The recovery helper
# must not accept a value persisted in .env.
CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE_PROCESS_VALUE="${CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE:-false}"

error_exit() {
  error "$1"
  return 1
}

is_yes() {
  case "$1" in
    [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  local status

  if [ "${1:-}" = "--doctor" ]; then
    doctor_llama_environment
    return 0
  fi

  llama_capture_status ensure_env_bootstrap
  status=$LLAMA_LAST_STATUS

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$status" -ne 0 ]; then
    return "$status"
  fi

  if [ "$LLAMA_USE_EXISTING_INSTANCE" != true ]; then
    llama_capture_status ensure_llama_bin_ready
    status=$LLAMA_LAST_STATUS

    if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    if [ "$status" -ne 0 ]; then
      return "$status"
    fi
  fi

  validate_setup_requirements || return $?

  NEEDS_PROVISIONING=false
  IS_RUNNING=false
  CONFIG_OVERWRITTEN=false

  if run_provisioning_and_deployment; then
    blank_line
    return 0
  else
    status=$?
  fi

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  return "$status"
}

status=0
set +e
(
  set -euo pipefail
  main "$@"
)
status=$?
set -e
terminal_safe_exit "$status"
chr
