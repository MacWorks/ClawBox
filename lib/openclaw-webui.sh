source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

openclaw_webui_state_dir() {
  printf '%s\n' "${BASE_DIR:-$(pwd)}/.clawbox"
}

openclaw_webui_state_file() {
  printf '%s\n' "$(openclaw_webui_state_dir)/openclaw-webui-tunnel.env"
}

openclaw_webui_default_host_port() {
  printf '%s\n' "${OPENCLAW_WEBUI_TUNNEL_PORT:-18790}"
}

openclaw_webui_gateway_port() {
  if command -v vm_openclaw_gateway_port >/dev/null 2>&1; then
    vm_openclaw_gateway_port
    return 0
  fi

  printf '%s\n' '18789'
}

openclaw_webui_port_in_use() {
  local port="$1"

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi

  return 1
}

openclaw_webui_select_host_port() {
  local port="${1:-$(openclaw_webui_default_host_port)}"
  local attempts=0

  while [ "$attempts" -lt 20 ]; do
    if ! openclaw_webui_port_in_use "$port"; then
      REPLY="$port"
      return 0
    fi
    port=$((port + 1))
    attempts=$((attempts + 1))
  done

  return 1
}

openclaw_webui_tunnel_signature_matches() {
  local pid="$1" host_port="$2" gateway_port="$3"
  local command_line=''

  [ -n "$pid" ] || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$command_line" ] || return 1

  [[ "$command_line" == *"ssh"* ]] || return 1
  [[ "$command_line" == *"127.0.0.1:$host_port:127.0.0.1:$gateway_port"* ]] || return 1
  [[ "$command_line" == *"${VM_HOST:-}"* ]] || return 1
  return 0
}

openclaw_webui_load_state() {
  local state_file=''

  state_file="$(openclaw_webui_state_file)"
  OPENCLAW_WEBUI_TUNNEL_PID=''
  OPENCLAW_WEBUI_TUNNEL_HOST_PORT=''
  OPENCLAW_WEBUI_TUNNEL_VM_HOST=''

  [ -f "$state_file" ] || return 1

  # shellcheck source=/dev/null
  . "$state_file"
}

openclaw_webui_write_state() {
  local pid="$1" host_port="$2"
  local state_dir='' state_file=''

  state_dir="$(openclaw_webui_state_dir)"
  state_file="$(openclaw_webui_state_file)"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir" >/dev/null 2>&1 || true
  {
    printf 'OPENCLAW_WEBUI_TUNNEL_PID=%q\n' "$pid"
    printf 'OPENCLAW_WEBUI_TUNNEL_HOST_PORT=%q\n' "$host_port"
    printf 'OPENCLAW_WEBUI_TUNNEL_VM_HOST=%q\n' "${VM_HOST:-}"
  } > "$state_file"
  chmod 600 "$state_file" >/dev/null 2>&1 || true
}

openclaw_webui_ensure_tunnel() {
  local gateway_port='' host_port='' state_pid='' state_port='' pid=''

  gateway_port="$(openclaw_webui_gateway_port)"
  if openclaw_webui_load_state; then
    state_pid="${OPENCLAW_WEBUI_TUNNEL_PID:-}"
    state_port="${OPENCLAW_WEBUI_TUNNEL_HOST_PORT:-}"
    if [ "${OPENCLAW_WEBUI_TUNNEL_VM_HOST:-}" = "${VM_HOST:-}" ] &&
       openclaw_webui_tunnel_signature_matches "$state_pid" "$state_port" "$gateway_port"
    then
      REPLY="$state_port"
      return 0
    fi

    if openclaw_webui_tunnel_signature_matches "$state_pid" "$state_port" "$gateway_port"; then
      kill "$state_pid" >/dev/null 2>&1 || true
    fi
  fi

  openclaw_webui_select_host_port "$(openclaw_webui_default_host_port)" || {
    warn 'No available local loopback port was found for the OpenClaw Web UI tunnel.'
    return 1
  }
  host_port="$REPLY"

  ssh -f -N \
    -L "127.0.0.1:$host_port:127.0.0.1:$gateway_port" \
    "$VM_HOST" >/dev/null 2>&1 || {
      warn 'Could not establish the OpenClaw Web UI SSH tunnel.'
      return 1
    }

  pid="$(pgrep -f "127.0.0.1:$host_port:127.0.0.1:$gateway_port.*${VM_HOST:-}" | tail -1 || true)"
  if ! openclaw_webui_tunnel_signature_matches "$pid" "$host_port" "$gateway_port"; then
    warn 'OpenClaw Web UI tunnel did not verify after startup.'
    return 1
  fi

  openclaw_webui_write_state "$pid" "$host_port"
  REPLY="$host_port"
}

openclaw_webui_auth_token_for_browser() {
  local token=''

  token="$(openclaw_config_remote_get 'gateway.auth.token' 2>/dev/null || true)"
  case "$token" in
    ''|null|'{}'|'[]'|__OPENCLAW_REDACTED__)
      REPLY=''
      return 1
      ;;
  esac

  REPLY="$token"
}

openclaw_webui_can_prompt() {
  [ -t 0 ]
}

offer_openclaw_webui() {
  local choice='' host_port='' token='' url=''

  openclaw_webui_can_prompt || return 0
  case "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-unknown}" in
    'managed by VM launchd'|'managed by native OpenClaw LaunchAgent')
      ;;
    *)
      return 0
      ;;
  esac

  prompt_yes_no 'Open the OpenClaw Web UI in your browser now?' 'y'
  choice="$REPLY"
  is_yes "$choice" || return 0

  openclaw_webui_ensure_tunnel || return 0
  host_port="$REPLY"
  url="http://127.0.0.1:$host_port/"

  if openclaw_webui_auth_token_for_browser; then
    token="$REPLY"
    url="${url}?token=${token}"
  fi

  if command -v open >/dev/null 2>&1 && open "$url" >/dev/null 2>&1; then
    success 'OpenClaw Web UI opened in your browser.'
  else
    warn 'OpenClaw Web UI tunnel is ready, but the browser did not open automatically.'
    outf 'Open this local URL in your browser: http://127.0.0.1:%s/' "$host_port"
  fi
}
