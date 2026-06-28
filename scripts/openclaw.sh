#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$BASE_DIR/.env"
ENV_EXAMPLE_FILE="$BASE_DIR/.env.example"
RUNTIME_DIR="$BASE_DIR/vm/runtime"
CONFIG_PATH="$RUNTIME_DIR/openclaw.json"
REMOTE_CONFIG_DIR='~/.openclaw'
REMOTE_CONFIG_PATH='~/.openclaw/openclaw.json'
GENERATE_SCRIPT="$BASE_DIR/host/scripts/generate-openclaw-config.sh"

source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/prompt.sh"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/ssh.sh"

is_yes() {
  case "$1" in [Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]) return 0;; *) return 1;; esac
}

show_openclaw_help() {
  out 'Usage: ./clawbox openclaw reset'
  out '  reset  Back up and replace the VM OpenClaw config after confirmation.'
}

resolve_remote_openclaw_config_paths() {
  local remote_home="${VM_USER_PATH:-}"

  if [ -z "$remote_home" ]; then
    remote_home="$(ssh_exec 'printf %s "$HOME"')" || {
      error 'Unable to resolve VM home directory for OpenClaw config reset.'
      return 1
    }
  fi

  [ -n "$remote_home" ] || {
    error 'Unable to resolve VM home directory for OpenClaw config reset.'
    return 1
  }

  REMOTE_CONFIG_DIR="$remote_home/.openclaw"
  REMOTE_CONFIG_PATH="$REMOTE_CONFIG_DIR/openclaw.json"
}

reset_openclaw_config() {
  local backup_path=''
  [ -f "$ENV_FILE" ] || { error 'Missing .env. Run ./clawbox setup first.'; return 1; }
  set -a; . "$ENV_FILE"; set +a
  [ -n "${VM_HOST:-}" ] || { error 'VM_HOST is not configured.'; return 1; }
  ssh_check 'echo ok' >/dev/null || { error 'VM SSH connectivity is required for reset.'; return 1; }
  resolve_remote_openclaw_config_paths || return $?

  warn 'WARNING'
  blank_line
  warn 'This operation replaces the VM OpenClaw config:'
  warn '~/.openclaw/openclaw.json'
  warn 'It can remove OpenClaw onboarding and custom settings.'
  prompt_yes_no 'Replace the VM OpenClaw config now?' 'n'
  is_yes "$REPLY" || { out 'OpenClaw config reset cancelled.'; return 0; }

  if ssh_exec "test -f $(printf '%q' "$REMOTE_CONFIG_PATH")"; then
    backup_path="$REMOTE_CONFIG_PATH.clawbox-backup-$(date +%Y%m%d-%H%M%S)"
    out "Creating VM backup: $backup_path"
    if ! ssh_exec "cp $(printf '%q' "$REMOTE_CONFIG_PATH") $(printf '%q' "$backup_path")"; then
      error "Failed to create VM OpenClaw config backup: $backup_path"
      error 'OpenClaw config was not replaced.'
      return 1
    fi
    if ! ssh_exec "test -f $(printf '%q' "$backup_path")"; then
      error "VM OpenClaw config backup was not found after copy: $backup_path"
      error 'OpenClaw config was not replaced.'
      return 1
    fi
    out "Created VM backup: $backup_path"
  fi
  "$GENERATE_SCRIPT"
  ssh_run_quiet "mkdir -p $(printf '%q' "$REMOTE_CONFIG_DIR")"
  scp -O -q "$CONFIG_PATH" "$VM_HOST:$REMOTE_CONFIG_PATH" </dev/null
  ssh_exec "test -f $(printf '%q' "$REMOTE_CONFIG_PATH")"
  success 'VM OpenClaw config was replaced from the minimal ClawBox config.'
  out 'OpenClaw was not restarted. Restart it explicitly if required.'
}

main() {
  case "${1:-}" in
    reset) reset_openclaw_config ;;
    ''|help|-h|--help) show_openclaw_help ;;
    *) error "Unknown OpenClaw command: $1"; show_openclaw_help; return 1 ;;
  esac
}

if [ "${CLAWBOX_OPENCLAW_LIB_ONLY:-false}" != true ]; then
  main "$@"
fi
