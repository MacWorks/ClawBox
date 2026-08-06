#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$BASE_DIR/.env"
ENV_EXAMPLE_FILE="$BASE_DIR/.env.example"

source "$BASE_DIR/lib/output.sh"
source "$BASE_DIR/lib/log.sh"
source "$BASE_DIR/lib/setup-env.sh"
source "$BASE_DIR/lib/ssh.sh"
source "$BASE_DIR/lib/prompt.sh"
source "$BASE_DIR/lib/openclaw-webui.sh"

show_ui_help() {
  cat <<EOF
Usage: ./clawbox ui [options]

Open the VM OpenClaw Web UI through a host-loopback SSH tunnel.

Options:
  --port <port>       Use a specific host loopback tunnel port
  --no-open           Create or verify the tunnel without opening a browser
  --install-service   Install or update the login LaunchAgent tunnel
  --remove-service    Remove the login LaunchAgent tunnel
  --status            Show tunnel and LaunchAgent status
  --stop              Stop the ClawBox-managed tunnel; unload service if needed
  -h, --help          Show this help message

Examples:
  ./clawbox ui
  ./clawbox ui --no-open
  ./clawbox ui --port 18791
  ./clawbox ui --install-service
  ./clawbox ui --install-service --port 18791
EOF
}

load_ui_environment() {
  [ -f "$ENV_FILE" ] || {
    error 'Missing .env. Run ./clawbox setup first.'
    return 1
  }

  source_env_file || return $?

  [ -n "${VM_HOST:-}" ] || {
    error 'VM_HOST is not configured. Run ./clawbox setup first.'
    return 1
  }
}

print_ui_ready_summary() {
  local host_port="$1"
  local url=''

  url="$(openclaw_webui_url_for_port "$host_port")"
  out 'OpenClaw Web UI tunnel ready.'
  outf 'VM target: %s' "$VM_HOST"
  outf 'Local URL: %s' "$url"
  outf 'Tunnel: %s' "${OPENCLAW_WEBUI_TUNNEL_ACTION:-ready}"
  out 'Gateway readiness: reachable through tunnel'
}

ui_status() {
  local gateway_port='' state_pid='' state_port='' url=''

  load_ui_environment || return $?
  gateway_port="$(openclaw_webui_gateway_port)"

  openclaw_webui_service_status || true

  if ! openclaw_webui_load_state; then
    out 'OpenClaw Web UI tunnel: not recorded'
    return 1
  fi

  state_pid="${OPENCLAW_WEBUI_TUNNEL_PID:-}"
  state_port="${OPENCLAW_WEBUI_TUNNEL_HOST_PORT:-}"
  if openclaw_webui_tunnel_signature_matches "$state_pid" "$state_port" "$gateway_port" \
    && openclaw_webui_probe_gateway "$state_port"; then
    url="$(openclaw_webui_url_for_port "$state_port")"
    out 'OpenClaw Web UI tunnel: ready'
    outf 'VM target: %s' "$VM_HOST"
    outf 'Local URL: %s' "$url"
    return 0
  fi

  out 'OpenClaw Web UI tunnel: not ready'
  return 1
}

ui_stop() {
  load_ui_environment || return $?

  if openclaw_webui_service_loaded; then
    openclaw_webui_unload_service || {
      error 'OpenClaw Web UI tunnel service could not be unloaded.'
      return 1
    }
    out 'OpenClaw Web UI tunnel service unloaded to prevent automatic restart.'
    out 'Run ./clawbox ui --install-service to load it again, or --remove-service to remove it.'
  fi

  if openclaw_webui_stop_recorded_tunnel >/dev/null 2>&1; then
    out 'OpenClaw Web UI tunnel stopped.'
    return 0
  fi

  out 'OpenClaw Web UI tunnel: not recorded'
}

open_ui() {
  local requested_port=''
  local no_open=false
  local install_service=false
  local remove_service=false
  local host_port=''
  local url=''
  local service_installed=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        shift
        [ "$#" -gt 0 ] || {
          error 'Missing value for --port.'
          return 1
        }
        requested_port="$1"
        ;;
      --port=*)
        requested_port="${1#--port=}"
        ;;
      --no-open)
        no_open=true
        ;;
      --install-service)
        install_service=true
        ;;
      --remove-service)
        remove_service=true
        ;;
      -h|--help)
        show_ui_help
        return 0
        ;;
      *)
        error "Unknown ui option: $1"
        show_ui_help
        return 1
        ;;
    esac
    shift
  done

  load_ui_environment || return $?

  if [ "$remove_service" = true ]; then
    openclaw_webui_remove_service
    return $?
  fi

  if [ "$install_service" = true ]; then
    OPENCLAW_WEBUI_COMMAND_MODE='install-service' openclaw_webui_install_service "$requested_port"
    return $?
  fi

  OPENCLAW_WEBUI_COMMAND_MODE='open'
  if ! openclaw_webui_ensure_tunnel "$requested_port"; then
    OPENCLAW_WEBUI_TUNNEL_VERIFIED=false
    openclaw_webui_debug 'prompt decision: command_mode=open tunnel_verified=false browser_open_completed=false final_eligible=false'
    return 1
  fi
  host_port="$REPLY"
  OPENCLAW_WEBUI_LAST_HOST_PORT="$host_port"
  OPENCLAW_WEBUI_TUNNEL_VERIFIED=true
  url="$(openclaw_webui_url_for_port "$host_port")"

  print_ui_ready_summary "$host_port"

  if [ "$no_open" = true ]; then
    openclaw_webui_debug 'prompt decision: command_mode=no-open tunnel_verified=true browser_open_completed=false final_eligible=false'
    out 'Browser: not opened (--no-open)'
    return 0
  fi

  if openclaw_webui_open_browser "$url"; then
    OPENCLAW_WEBUI_BROWSER_OPEN_COMPLETED=true
    success 'OpenClaw Web UI opened in your browser.'
  else
    OPENCLAW_WEBUI_BROWSER_OPEN_COMPLETED=false
    warn 'OpenClaw Web UI tunnel is ready, but the browser did not open automatically.'
    outf 'Open this local URL in your browser: %s' "$url"
  fi

  openclaw_webui_service_installed && service_installed=true || service_installed=false
  openclaw_webui_debug "open path completed: tunnel_verified=${OPENCLAW_WEBUI_TUNNEL_VERIFIED:-false} browser_open_completed=${OPENCLAW_WEBUI_BROWSER_OPEN_COMPLETED:-false} service_installed=$service_installed"
  openclaw_webui_offer_persistence_prompt || true
}

main() {
  case "${1:-}" in
    --status)
      shift
      [ "$#" -eq 0 ] || {
        error 'The --status option does not accept additional arguments.'
        return 1
      }
      ui_status
      ;;
    --stop)
      shift
      [ "$#" -eq 0 ] || {
        error 'The --stop option does not accept additional arguments.'
        return 1
      }
      ui_stop
      ;;
    -h|--help|help)
      show_ui_help
      ;;
    *)
      open_ui "$@"
      ;;
  esac
}

if [ "${CLAWBOX_UI_LIB_ONLY:-false}" != true ]; then
  main "$@"
fi
