#!/bin/bash
set +e

PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"

ENV_FILE="${CLAWBOX_OPENCLAW_WEBUI_ENV_FILE:-$HOME/Library/Application Support/ClawBox/openclaw-ui-tunnel.env}"
max_attempts="${OPENCLAW_WEBUI_SERVICE_MAX_ATTEMPTS:-12}"
sleep_seconds="${OPENCLAW_WEBUI_SERVICE_RETRY_SECONDS:-5}"

log_info() {
  printf '[INFO] %s\n' "$1"
}

log_warn() {
  printf '[WARN] %s\n' "$1"
}

log_error() {
  printf '[ERROR] %s\n' "$1" >&2
}

if [ ! -f "$ENV_FILE" ]; then
  log_error "OpenClaw UI tunnel environment is missing: $ENV_FILE"
  exit 1
fi

# shellcheck source=/dev/null
. "$ENV_FILE"

state_file="${OPENCLAW_WEBUI_STATE_DIR:-$HOME/Library/Application Support/ClawBox/state}/openclaw-webui-tunnel.env"
host_port="${OPENCLAW_WEBUI_TUNNEL_PORT:-18790}"
gateway_port="${OPENCLAW_WEBUI_GATEWAY_PORT:-18789}"
ssh_timeout="${OPENCLAW_WEBUI_SSH_CONNECT_TIMEOUT:-8}"
readiness_timeout="${OPENCLAW_WEBUI_READINESS_TIMEOUT:-10}"

validate_port() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

tunnel_pid() {
  pgrep -f "127.0.0.1:$host_port:127.0.0.1:$gateway_port.*${VM_HOST:-}" 2>/dev/null | tail -1
}

tunnel_signature_matches() {
  local pid="$1"
  local command_line

  [ -n "$pid" ] || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$command_line" ] || return 1
  case "$command_line" in
    *ssh*127.0.0.1:"$host_port":127.0.0.1:"$gateway_port"*"$VM_HOST"*)
      return 0
      ;;
  esac
  return 1
}

gateway_ready() {
  local status

  command -v curl >/dev/null 2>&1 || return 1
  status="$(curl -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 1 \
    --max-time 2 \
    "http://127.0.0.1:$host_port/" 2>/dev/null || true)"
  case "$status" in
    2??|3??|401|403|404)
      return 0
      ;;
  esac
  return 1
}

wait_gateway_ready() {
  local deadline now

  deadline=$(($(date +%s) + readiness_timeout))
  while true; do
    gateway_ready && return 0
    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || break
    sleep 1
  done
  return 1
}

ssh_ready() {
  [ -n "${VM_HOST:-}" ] || return 1
  ssh -n \
    -o BatchMode=yes \
    -o ConnectTimeout="$ssh_timeout" \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    "$VM_HOST" 'echo ok' 2>/dev/null | grep -Fxq ok
}

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$host_port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$host_port" >/dev/null 2>&1
    return $?
  fi
  return 1
}

write_state() {
  local pid="$1"

  mkdir -p "$(dirname "$state_file")"
  chmod 700 "$(dirname "$state_file")" >/dev/null 2>&1 || true
  {
    printf 'OPENCLAW_WEBUI_TUNNEL_PID=%q\n' "$pid"
    printf 'OPENCLAW_WEBUI_TUNNEL_HOST_PORT=%q\n' "$host_port"
    printf 'OPENCLAW_WEBUI_TUNNEL_VM_HOST=%q\n' "$VM_HOST"
  } > "$state_file"
  chmod 600 "$state_file" >/dev/null 2>&1 || true
}

ensure_tunnel() {
  local pid

  validate_port "$host_port" || {
    log_error "Invalid OpenClaw UI tunnel port: $host_port"
    return 1
  }
  validate_port "$gateway_port" || {
    log_error "Invalid OpenClaw gateway port: $gateway_port"
    return 1
  }

  pid="$(tunnel_pid)"
  if tunnel_signature_matches "$pid" && gateway_ready; then
    write_state "$pid"
    log_info "OpenClaw UI tunnel already operational at http://127.0.0.1:$host_port/."
    return 0
  fi

  if port_in_use; then
    log_error "Local port $host_port is occupied by a process that is not the managed OpenClaw UI tunnel."
    log_error 'Reinstall the UI service with ./clawbox ui --install-service --port <port>.'
    return 1
  fi

  ssh_ready || {
    log_warn "VM SSH is not ready for OpenClaw UI tunnel target: ${VM_HOST:-not configured}"
    return 1
  }

  ssh -f -N \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ConnectTimeout="$ssh_timeout" \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    -L "127.0.0.1:$host_port:127.0.0.1:$gateway_port" \
    "$VM_HOST" || {
      log_error 'Failed to create OpenClaw UI SSH tunnel.'
      return 1
    }

  pid="$(tunnel_pid)"
  tunnel_signature_matches "$pid" || {
    log_error 'OpenClaw UI SSH tunnel process did not verify after startup.'
    return 1
  }

  wait_gateway_ready || {
    log_warn "OpenClaw gateway is not ready through http://127.0.0.1:$host_port/ yet."
    return 1
  }

  write_state "$pid"
  log_info "OpenClaw UI tunnel operational at http://127.0.0.1:$host_port/."
  return 0
}

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  log_info "OpenClaw UI tunnel service attempt $attempt of $max_attempts."
  if ensure_tunnel; then
    exit 0
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -le "$max_attempts" ] || break
  sleep "$sleep_seconds"
done

log_error 'OpenClaw UI tunnel service did not become operational before the retry limit.'
exit 1
