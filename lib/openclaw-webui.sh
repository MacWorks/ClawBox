OPENCLAW_WEBUI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$OPENCLAW_WEBUI_LIB_DIR/output.sh"
source "$OPENCLAW_WEBUI_LIB_DIR/log-paths.sh"

openclaw_webui_service_label() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_SERVICE_LABEL:-com.clawbox.openclaw-ui-tunnel}"
}

openclaw_webui_app_support_dir() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_APP_SUPPORT_DIR:-$HOME/Library/Application Support/ClawBox}"
}

openclaw_webui_wrapper_src() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_WRAPPER_SRC:-${BASE_DIR:-$(pwd)}/host/scripts/openclaw-ui-tunnel.sh}"
}

openclaw_webui_wrapper_dest() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_WRAPPER_DEST:-$(openclaw_webui_app_support_dir)/bin/openclaw-ui-tunnel.sh}"
}

openclaw_webui_service_env_file() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_ENV_FILE:-$(openclaw_webui_app_support_dir)/openclaw-ui-tunnel.env}"
}

openclaw_webui_plist_path() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_PLIST_PATH:-$HOME/Library/LaunchAgents/$(openclaw_webui_service_label).plist}"
}

openclaw_webui_service_state_dir() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_SERVICE_STATE_DIR:-$(openclaw_webui_app_support_dir)/state}"
}

openclaw_webui_service_stdout_log() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_STDOUT_LOG:-$(clawbox_openclaw_ui_tunnel_stdout_log_default)}"
}

openclaw_webui_service_stderr_log() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_WEBUI_STDERR_LOG:-$(clawbox_openclaw_ui_tunnel_stderr_log_default)}"
}

openclaw_webui_service_target() {
  printf 'gui/%s/%s\n' "$(id -u)" "$(openclaw_webui_service_label)"
}

openclaw_webui_load_service_env() {
  local env_file=''
  env_file="$(openclaw_webui_service_env_file)"
  [ -f "$env_file" ] || return 1

  # shellcheck source=/dev/null
  . "$env_file"
}

openclaw_webui_service_installed() {
  [ -f "$(openclaw_webui_plist_path)" ] \
    && [ -f "$(openclaw_webui_service_env_file)" ] \
    && [ -x "$(openclaw_webui_wrapper_dest)" ]
}

openclaw_webui_service_loaded() {
  launchctl print "$(openclaw_webui_service_target)" >/dev/null 2>&1
}

openclaw_webui_state_dir() {
  if [ -n "${OPENCLAW_WEBUI_STATE_DIR:-}" ]; then
    printf '%s\n' "$OPENCLAW_WEBUI_STATE_DIR"
    return 0
  fi

  if [ -f "$(openclaw_webui_service_env_file)" ]; then
    openclaw_webui_load_service_env >/dev/null 2>&1 || true
    if [ -n "${OPENCLAW_WEBUI_STATE_DIR:-}" ]; then
      printf '%s\n' "$OPENCLAW_WEBUI_STATE_DIR"
      return 0
    fi
  fi

  printf '%s\n' "${BASE_DIR:-$(pwd)}/.clawbox"
}

openclaw_webui_state_file() {
  printf '%s\n' "$(openclaw_webui_state_dir)/openclaw-webui-tunnel.env"
}

openclaw_webui_default_host_port() {
  if [ -z "${OPENCLAW_WEBUI_TUNNEL_PORT:-}" ] && [ -f "$(openclaw_webui_service_env_file)" ]; then
    openclaw_webui_load_service_env >/dev/null 2>&1 || true
  fi

  printf '%s\n' "${OPENCLAW_WEBUI_TUNNEL_PORT:-18790}"
}

openclaw_webui_gateway_port() {
  if [ -n "${OPENCLAW_WEBUI_GATEWAY_PORT:-}" ]; then
    printf '%s\n' "$OPENCLAW_WEBUI_GATEWAY_PORT"
    return 0
  fi

  if command -v vm_openclaw_gateway_port >/dev/null 2>&1; then
    vm_openclaw_gateway_port
    return 0
  fi

  printf '%s\n' '18789'
}

openclaw_webui_ssh_connect_timeout() {
  printf '%s\n' "${OPENCLAW_WEBUI_SSH_CONNECT_TIMEOUT:-8}"
}

openclaw_webui_readiness_timeout() {
  printf '%s\n' "${OPENCLAW_WEBUI_READINESS_TIMEOUT:-10}"
}

openclaw_webui_validate_port() {
  local port="$1"

  case "$port" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

openclaw_webui_port_in_use() {
  local port="$1"
  local lsof_status=1

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    lsof_status=$?
    if [ "$lsof_status" -eq 0 ]; then
      return 0
    fi
  fi

  if openclaw_webui_loopback_port_accepts_connections "$port"; then
    return 0
  fi

  return 1
}

openclaw_webui_loopback_port_accepts_connections() {
  local port="$1"

  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi

  (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1
}

openclaw_webui_find_tunnel_pid() {
  local host_port="$1"
  local gateway_port="$2"
  local pattern=''

  pattern="127.0.0.1:$host_port:127.0.0.1:$gateway_port"
  pgrep -f "$pattern.*${VM_HOST:-}" 2>/dev/null | tail -1
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

openclaw_webui_probe_gateway() {
  local host_port="$1"
  local status=''

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

openclaw_webui_wait_for_gateway() {
  local host_port="$1"
  local timeout_seconds=''
  local deadline=0
  local now=0

  timeout_seconds="$(openclaw_webui_readiness_timeout)"
  case "$timeout_seconds" in
    ''|*[!0-9]*)
      timeout_seconds=10
      ;;
  esac

  deadline=$(($(date +%s) + timeout_seconds))
  while true; do
    if openclaw_webui_probe_gateway "$host_port"; then
      return 0
    fi

    now="$(date +%s)"
    [ "$now" -lt "$deadline" ] || break
    sleep 0.25
  done

  return 1
}

openclaw_webui_check_ssh() {
  local timeout_seconds=''
  local output=''

  [ -n "${VM_HOST:-}" ] || {
    error 'VM_HOST is not configured. Run ./clawbox setup first.'
    return 1
  }

  timeout_seconds="$(openclaw_webui_ssh_connect_timeout)"
  case "$timeout_seconds" in
    ''|*[!0-9]*)
      timeout_seconds=8
      ;;
  esac

  output="$(ssh -n \
    -o BatchMode=yes \
    -o ConnectTimeout="$timeout_seconds" \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    "$VM_HOST" 'echo ok' 2>/dev/null || true)"

  [ "$output" = 'ok' ]
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

openclaw_webui_remove_state() {
  local state_file=''

  state_file="$(openclaw_webui_state_file)"
  rm -f "$state_file"
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

openclaw_webui_existing_tunnel_ready() {
  local host_port="$1"
  local gateway_port="$2"
  local pid=''

  pid="$(openclaw_webui_find_tunnel_pid "$host_port" "$gateway_port")"
  if openclaw_webui_tunnel_signature_matches "$pid" "$host_port" "$gateway_port" \
    && openclaw_webui_probe_gateway "$host_port"; then
    REPLY="$pid"
    return 0
  fi

  return 1
}

openclaw_webui_start_tunnel() {
  local host_port="$1"
  local gateway_port="$2"
  local timeout_seconds=''

  timeout_seconds="$(openclaw_webui_ssh_connect_timeout)"
  case "$timeout_seconds" in
    ''|*[!0-9]*)
      timeout_seconds=8
      ;;
  esac

  ssh -f -N \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ConnectTimeout="$timeout_seconds" \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=2 \
    -L "127.0.0.1:$host_port:127.0.0.1:$gateway_port" \
    "$VM_HOST"
}

openclaw_webui_concise_ssh_error() {
  local output="$1"

  output="${output//$'\r'/}"
  output="$(printf '%s\n' "$output" | sed -e '/^[[:space:]]*$/d' | head -5)"
  [ -n "$output" ] || return 1
  printf '%s\n' "$output"
}

openclaw_webui_stop_recorded_tunnel() {
  local gateway_port='' state_pid='' state_port=''

  gateway_port="$(openclaw_webui_gateway_port)"
  if ! openclaw_webui_load_state; then
    return 1
  fi

  state_pid="${OPENCLAW_WEBUI_TUNNEL_PID:-}"
  state_port="${OPENCLAW_WEBUI_TUNNEL_HOST_PORT:-}"
  if openclaw_webui_tunnel_signature_matches "$state_pid" "$state_port" "$gateway_port"; then
    kill "$state_pid" >/dev/null 2>&1 || true
    openclaw_webui_remove_state
    return 0
  fi

  openclaw_webui_remove_state
  return 2
}

openclaw_webui_ensure_tunnel() {
  local requested_port="${1:-}"
  local gateway_port='' host_port='' state_pid='' state_port='' pid=''
  local default_port=''

  OPENCLAW_WEBUI_TUNNEL_ACTION=''
  OPENCLAW_WEBUI_TUNNEL_GATEWAY_READY=false

  [ -z "$requested_port" ] || openclaw_webui_validate_port "$requested_port" || {
    error "Invalid OpenClaw Web UI local port: $requested_port"
    error 'Use an integer from 1 to 65535.'
    return 1
  }

  gateway_port="$(openclaw_webui_gateway_port)"
  openclaw_webui_validate_port "$gateway_port" || {
    error "Invalid OpenClaw gateway port: $gateway_port"
    return 1
  }

  if ! openclaw_webui_check_ssh; then
    error "Unable to connect to the VM over SSH: ${VM_HOST:-<unset>}"
    error 'Start the VM and verify passwordless SSH, then retry ./clawbox ui.'
    return 1
  fi

  if openclaw_webui_load_state; then
    state_pid="${OPENCLAW_WEBUI_TUNNEL_PID:-}"
    state_port="${OPENCLAW_WEBUI_TUNNEL_HOST_PORT:-}"
    if [ -n "$state_port" ] \
      && { [ -z "$requested_port" ] || [ "$requested_port" = "$state_port" ]; } \
      && [ "${OPENCLAW_WEBUI_TUNNEL_VM_HOST:-}" = "${VM_HOST:-}" ] \
      && openclaw_webui_tunnel_signature_matches "$state_pid" "$state_port" "$gateway_port" \
      && openclaw_webui_probe_gateway "$state_port"
    then
      OPENCLAW_WEBUI_TUNNEL_ACTION='reused'
      OPENCLAW_WEBUI_TUNNEL_GATEWAY_READY=true
      REPLY="$state_port"
      return 0
    fi

    if openclaw_webui_tunnel_signature_matches "$state_pid" "$state_port" "$gateway_port"; then
      kill "$state_pid" >/dev/null 2>&1 || true
      openclaw_webui_remove_state
    fi
  fi

  if [ -n "$requested_port" ]; then
    if openclaw_webui_existing_tunnel_ready "$requested_port" "$gateway_port"; then
      openclaw_webui_write_state "$REPLY" "$requested_port"
      OPENCLAW_WEBUI_TUNNEL_ACTION='reused'
      OPENCLAW_WEBUI_TUNNEL_GATEWAY_READY=true
      REPLY="$requested_port"
      return 0
    fi

    if openclaw_webui_port_in_use "$requested_port"; then
      error "Local port $requested_port is already in use by another process."
      error 'Choose another port with ./clawbox ui --port <port>.'
      return 1
    fi
    host_port="$requested_port"
  else
    default_port="$(openclaw_webui_default_host_port)"
    if openclaw_webui_existing_tunnel_ready "$default_port" "$gateway_port"; then
      openclaw_webui_write_state "$REPLY" "$default_port"
      OPENCLAW_WEBUI_TUNNEL_ACTION='reused'
      OPENCLAW_WEBUI_TUNNEL_GATEWAY_READY=true
      REPLY="$default_port"
      return 0
    fi

    openclaw_webui_select_host_port "$default_port" || {
      error 'No available local loopback port was found for the OpenClaw Web UI tunnel.'
      return 1
    }
    host_port="$REPLY"
  fi

  local tunnel_output=''
  if ! tunnel_output="$(openclaw_webui_start_tunnel "$host_port" "$gateway_port" 2>&1)"; then
    error 'Could not establish the OpenClaw Web UI SSH tunnel.'
    if openclaw_webui_concise_ssh_error "$tunnel_output" >/dev/null 2>&1; then
      error 'SSH reported:'
      while IFS= read -r line; do
        error "$line"
      done <<EOF
$(openclaw_webui_concise_ssh_error "$tunnel_output")
EOF
    fi
    error 'Verify VM SSH access and that the remote OpenClaw gateway is running.'
    return 1
  fi

  pid="$(pgrep -f "127.0.0.1:$host_port:127.0.0.1:$gateway_port.*${VM_HOST:-}" | tail -1 || true)"
  if ! openclaw_webui_tunnel_signature_matches "$pid" "$host_port" "$gateway_port"; then
    error 'OpenClaw Web UI tunnel did not verify after startup.'
    return 1
  fi

  if ! openclaw_webui_wait_for_gateway "$host_port"; then
    error "OpenClaw gateway did not become reachable through the tunnel at http://127.0.0.1:$host_port/."
    return 1
  fi

  openclaw_webui_write_state "$pid" "$host_port"
  OPENCLAW_WEBUI_TUNNEL_ACTION='created'
  OPENCLAW_WEBUI_TUNNEL_GATEWAY_READY=true
  REPLY="$host_port"
}

openclaw_webui_write_service_env() {
  local host_port="$1" gateway_port="$2"
  local env_file='' state_dir=''

  env_file="$(openclaw_webui_service_env_file)"
  state_dir="$(openclaw_webui_service_state_dir)"
  mkdir -p "$(dirname "$env_file")" "$state_dir"
  chmod 700 "$state_dir" >/dev/null 2>&1 || true
  {
    printf 'VM_HOST=%q\n' "${VM_HOST:-}"
    printf 'OPENCLAW_WEBUI_TUNNEL_PORT=%q\n' "$host_port"
    printf 'OPENCLAW_WEBUI_GATEWAY_PORT=%q\n' "$gateway_port"
    printf 'OPENCLAW_WEBUI_STATE_DIR=%q\n' "$state_dir"
    printf 'OPENCLAW_WEBUI_SSH_CONNECT_TIMEOUT=%q\n' "$(openclaw_webui_ssh_connect_timeout)"
    printf 'OPENCLAW_WEBUI_READINESS_TIMEOUT=%q\n' "$(openclaw_webui_readiness_timeout)"
  } > "$env_file"
  chmod 600 "$env_file" >/dev/null 2>&1 || true
}

openclaw_webui_write_service_plist() {
  local plist_path='' wrapper_dest='' stdout_log='' stderr_log='' label=''

  plist_path="$(openclaw_webui_plist_path)"
  wrapper_dest="$(openclaw_webui_wrapper_dest)"
  stdout_log="$(openclaw_webui_service_stdout_log)"
  stderr_log="$(openclaw_webui_service_stderr_log)"
  label="$(openclaw_webui_service_label)"

  mkdir -p "$(dirname "$plist_path")" "$(dirname "$stdout_log")" "$(dirname "$stderr_log")"
  touch "$stdout_log" "$stderr_log"
  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>

  <key>ProgramArguments</key>
  <array>
    <string>$wrapper_dest</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>

  <key>ThrottleInterval</key>
  <integer>30</integer>

  <key>StandardOutPath</key>
  <string>$stdout_log</string>

  <key>StandardErrorPath</key>
  <string>$stderr_log</string>
</dict>
</plist>
EOF
}

openclaw_webui_install_service() {
  local requested_port="${1:-}"
  local host_port='' gateway_port='' wrapper_src='' wrapper_dest='' plist_path=''
  local previous_port=''

  [ -n "${VM_HOST:-}" ] || {
    error 'VM_HOST is not configured. Run ./clawbox setup first.'
    return 1
  }

  if [ -n "$requested_port" ]; then
    openclaw_webui_validate_port "$requested_port" || {
      error "Invalid OpenClaw Web UI service port: $requested_port"
      error 'Use an integer from 1 to 65535.'
      return 1
    }
    host_port="$requested_port"
  elif [ -f "$(openclaw_webui_service_env_file)" ]; then
    previous_port="$(OPENCLAW_WEBUI_TUNNEL_PORT='' openclaw_webui_load_service_env >/dev/null 2>&1; printf '%s\n' "${OPENCLAW_WEBUI_TUNNEL_PORT:-}")"
    if [ -n "$previous_port" ] && openclaw_webui_validate_port "$previous_port"; then
      host_port="$previous_port"
    fi
  fi

  [ -n "$host_port" ] || host_port='18790'
  gateway_port="$(openclaw_webui_gateway_port)"
  openclaw_webui_validate_port "$gateway_port" || {
    error "Invalid OpenClaw gateway port: $gateway_port"
    return 1
  }

  if ! openclaw_webui_existing_tunnel_ready "$host_port" "$gateway_port" \
    && openclaw_webui_port_in_use "$host_port"; then
    error "Local port $host_port is already in use by another process."
    error 'Choose another persistent port with ./clawbox ui --install-service --port <port>.'
    return 1
  fi

  wrapper_src="$(openclaw_webui_wrapper_src)"
  wrapper_dest="$(openclaw_webui_wrapper_dest)"
  plist_path="$(openclaw_webui_plist_path)"
  [ -f "$wrapper_src" ] || {
    error "OpenClaw UI tunnel wrapper source is missing: $wrapper_src"
    return 1
  }

  clawbox_ensure_standard_log_dirs
  mkdir -p "$(dirname "$wrapper_dest")"
  install -m 755 "$wrapper_src" "$wrapper_dest"
  openclaw_webui_write_service_env "$host_port" "$gateway_port"
  openclaw_webui_write_service_plist

  if openclaw_webui_service_loaded; then
    launchctl unload "$plist_path" >/dev/null 2>&1 || true
  fi
  launchctl load "$plist_path" || {
    error 'OpenClaw Web UI tunnel LaunchAgent could not be loaded.'
    return 1
  }

  OPENCLAW_WEBUI_TUNNEL_PORT="$host_port"
  OPENCLAW_WEBUI_GATEWAY_PORT="$gateway_port"
  OPENCLAW_WEBUI_STATE_DIR="$(openclaw_webui_service_state_dir)"
  if openclaw_webui_ensure_tunnel "$host_port"; then
    success 'OpenClaw Web UI tunnel service installed and verified.'
    outf 'Service label: %s' "$(openclaw_webui_service_label)"
    outf 'Local URL: %s' "$(openclaw_webui_url_for_port "$host_port")"
    return 0
  fi

  warn 'OpenClaw Web UI tunnel service was installed, but the tunnel is not ready yet.'
  warn 'launchd will retry after login while the VM or gateway is unavailable.'
  outf 'Service label: %s' "$(openclaw_webui_service_label)"
  outf 'stdout log: %s' "$(openclaw_webui_service_stdout_log)"
  outf 'stderr log: %s' "$(openclaw_webui_service_stderr_log)"
  return 1
}

openclaw_webui_unload_service() {
  local plist_path=''

  plist_path="$(openclaw_webui_plist_path)"
  if openclaw_webui_service_loaded; then
    launchctl unload "$plist_path" >/dev/null 2>&1 || return 1
  fi
}

openclaw_webui_remove_service() {
  local plist_path='' wrapper_dest='' env_file='' state_dir=''

  plist_path="$(openclaw_webui_plist_path)"
  wrapper_dest="$(openclaw_webui_wrapper_dest)"
  env_file="$(openclaw_webui_service_env_file)"
  state_dir="$(openclaw_webui_service_state_dir)"

  openclaw_webui_unload_service || {
    error 'OpenClaw Web UI tunnel LaunchAgent could not be unloaded.'
    return 1
  }
  openclaw_webui_stop_recorded_tunnel >/dev/null 2>&1 || true
  rm -f "$plist_path" "$wrapper_dest" "$env_file"
  rm -f "$state_dir/openclaw-webui-tunnel.env"
  out 'OpenClaw Web UI tunnel service removed.'
}

openclaw_webui_service_status() {
  local gateway_port='' state_pid='' state_port='' url=''
  local installed=false loaded=false ready=false

  gateway_port="$(openclaw_webui_gateway_port)"
  if openclaw_webui_service_installed; then
    installed=true
    openclaw_webui_load_service_env >/dev/null 2>&1 || true
  fi
  if openclaw_webui_service_loaded; then
    loaded=true
  fi

  if openclaw_webui_load_state; then
    state_pid="${OPENCLAW_WEBUI_TUNNEL_PID:-}"
    state_port="${OPENCLAW_WEBUI_TUNNEL_HOST_PORT:-}"
    if openclaw_webui_tunnel_signature_matches "$state_pid" "$state_port" "$gateway_port" \
      && openclaw_webui_probe_gateway "$state_port"; then
      ready=true
      url="$(openclaw_webui_url_for_port "$state_port")"
    fi
  fi

  if [ "$installed" = false ]; then
    out 'OpenClaw Web UI tunnel service: not installed'
  elif [ "$loaded" = true ] && [ "$ready" = true ]; then
    out 'OpenClaw Web UI tunnel service: loaded and operational'
  elif [ "$loaded" = true ]; then
    out 'OpenClaw Web UI tunnel service: loaded and waiting/retrying'
  elif [ "$installed" = true ]; then
    out 'OpenClaw Web UI tunnel service: installed but not loaded'
  fi

  outf 'Service label: %s' "$(openclaw_webui_service_label)"
  outf 'Configured VM target: %s' "${VM_HOST:-not configured}"
  if [ -n "$url" ]; then
    outf 'Local URL: %s' "$url"
  else
    outf 'Configured local port: %s' "$(openclaw_webui_default_host_port)"
  fi
  outf 'stdout log: %s' "$(openclaw_webui_service_stdout_log)"
  outf 'stderr log: %s' "$(openclaw_webui_service_stderr_log)"

  [ "$ready" = true ]
}

openclaw_webui_url_for_port() {
  local host_port="$1"

  printf 'http://127.0.0.1:%s/\n' "$host_port"
}

openclaw_webui_open_browser() {
  local url="$1"

  command -v open >/dev/null 2>&1 || return 1
  open "$url" >/dev/null 2>&1
}

openclaw_webui_debug_enabled() {
  case "${CLAWBOX_UI_DEBUG:-false}" in
    true|TRUE|yes|YES|1)
      return 0
      ;;
  esac
  return 1
}

openclaw_webui_debug() {
  openclaw_webui_debug_enabled || return 0
  printf 'DEBUG ui: %s\n' "$*" >&2
}

openclaw_webui_prompt_input_source() {
  if [ -t 0 ]; then
    printf 'stdin\n'
    return 0
  fi

  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '/dev/tty\n'
    return 0
  fi

  printf 'none\n'
  return 1
}

openclaw_webui_can_prompt() {
  openclaw_webui_prompt_input_source >/dev/null
}

openclaw_webui_prompt_yes_no() {
  local label="$1"
  local default="$2"
  local input_source=''

  input_source="$(openclaw_webui_prompt_input_source)" || return 1
  if [ "$input_source" = '/dev/tty' ]; then
    prompt_yes_no "$label" "$default" </dev/tty
    return $?
  fi

  prompt_yes_no "$label" "$default"
}

openclaw_webui_offer_persistence_prompt() {
  local choice='' input_source='none'
  local can_prompt=false service_installed=false helpers_available=true

  input_source="$(openclaw_webui_prompt_input_source 2>/dev/null)" || input_source='none'
  if openclaw_webui_can_prompt; then
    can_prompt=true
    if [ "$input_source" = 'none' ]; then
      input_source='custom'
    fi
  else
    can_prompt=false
  fi
  openclaw_webui_service_installed && service_installed=true || service_installed=false
  command -v prompt_yes_no >/dev/null 2>&1 || helpers_available=false
  command -v is_yes >/dev/null 2>&1 || helpers_available=false

  openclaw_webui_debug "prompt decision: command_mode=${OPENCLAW_WEBUI_COMMAND_MODE:-unknown} tunnel_verified=${OPENCLAW_WEBUI_TUNNEL_VERIFIED:-unknown} browser_open_completed=${OPENCLAW_WEBUI_BROWSER_OPEN_COMPLETED:-unknown} input_source=$input_source can_prompt=$can_prompt service_installed=$service_installed helpers_available=$helpers_available final_eligible=$([ "$can_prompt" = true ] && [ "$service_installed" = false ] && [ "$helpers_available" = true ] && printf true || printf false)"

  [ "$can_prompt" = true ] || return 0
  [ "$service_installed" = false ] || return 0
  [ "$helpers_available" = true ] || return 0

  if [ "$input_source" = 'custom' ]; then
    prompt_yes_no 'Keep the OpenClaw UI tunnel available automatically at login?' 'n'
  else
    openclaw_webui_prompt_yes_no 'Keep the OpenClaw UI tunnel available automatically at login?' 'n'
  fi
  choice="$REPLY"
  is_yes "$choice" || return 0

  openclaw_webui_install_service "${OPENCLAW_WEBUI_LAST_HOST_PORT:-}"
}

offer_openclaw_webui() {
  local choice='' host_port='' url=''

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

  if ! openclaw_webui_ensure_tunnel; then
    return 0
  fi
  host_port="$REPLY"
  OPENCLAW_WEBUI_LAST_HOST_PORT="$host_port"
  url="$(openclaw_webui_url_for_port "$host_port")"

  if openclaw_webui_open_browser "$url"; then
    success 'OpenClaw Web UI opened in your browser.'
  else
    warn 'OpenClaw Web UI tunnel is ready, but the browser did not open automatically.'
    outf 'Open this local URL in your browser: %s' "$url"
  fi

  openclaw_webui_offer_persistence_prompt || true
}
