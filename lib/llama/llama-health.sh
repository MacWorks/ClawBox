llama_api_url() {
  local host_ip="${1:-${HOST_IP:-}}"
  local port="${2:-${LLAMA_PORT:-}}"

  if [ "${LLAMA_EXTERNAL:-false}" = "true" ] && [ -n "${LLAMA_BASE_URL:-}" ] && [ -n "${LLAMA_PORT:-}" ] && [ "$port" = "${LLAMA_PORT:-}" ]; then
    printf '%s/models\n' "${LLAMA_BASE_URL%/}"
    return 0
  fi

  if [ -z "$host_ip" ] || [ -z "$port" ]; then
    return 1
  fi

  printf 'http://%s:%s/v1/models\n' "$host_ip" "$port"
}

llama_api_responding() {
  local host_ip="${1:-${HOST_IP:-}}"
  local port="${2:-${LLAMA_PORT:-}}"
  local api_url
  local connect_timeout="${CLAWBOX_LLAMA_HEALTH_CONNECT_TIMEOUT:-1}"
  local max_time="${CLAWBOX_LLAMA_HEALTH_MAX_TIME:-2}"

  api_url="$(llama_api_url "$host_ip" "$port")" || return 1

  curl -sS --fail --connect-timeout "$connect_timeout" --max-time "$max_time" "$api_url" >/dev/null 2>&1
}

llama_port_in_use() {
  local port="$1"

  [ -n "$port" ] || return 1

  # TCP connect test (works across users, no sudo required)
  if (echo >/dev/tcp/127.0.0.1/"$port") >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

llama_suggest_available_port() {
  local host_ip="$1"
  local current_port="$2"
  local candidate=''
  local attempts=0

  if ! [[ "$current_port" =~ ^[0-9]+$ ]]; then
    REPLY=''
    return 1
  fi

  candidate=$((current_port + 1))
  while [ "$attempts" -lt 100 ]; do
    if ! llama_port_in_use "$candidate"; then
      REPLY="$candidate"
      return 0
    fi

    candidate=$((candidate + 1))
    attempts=$((attempts + 1))
  done

  REPLY=''
  return 1
}

llama_listening_process_report() {
  local port="${1:-${LLAMA_PORT:-}}"

  REPLY=''

  if [ -z "$port" ] || ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi

  REPLY="$(lsof -i :"$port" -sTCP:LISTEN -n -P 2>/dev/null || true)"
  [ -n "$REPLY" ]
}

llama_show_port_conflict_warning() {
  local port="${1:-${LLAMA_PORT:-}}"
  local lsof_output=''
  local line=''

  llama_listening_process_report "$port" >/dev/null 2>&1 || true
  lsof_output="$REPLY"

  if [ -z "$lsof_output" ]; then
    return 0
  fi

  warn "Port $port may already be in use."
  err 'This may indicate a port conflict.'
  err_blank_line

  while IFS= read -r line; do
    if [ -n "$line" ]; then
      err "$line"
    fi
  done <<EOF
$lsof_output
EOF

  err_blank_line
}

llama_prompt_for_available_port() {
  local host_ip="$1"
  local current_port="$2"
  local prompt_mode="${3:-general}"
  local prompt_default=''
  local selected_port=''
  local choice=''
  local reuse_label='Use this existing instance'
  local alternate_label='Choose a different port'
  local managed_runtime_matches=true

  while true; do
    llama_suggest_available_port "$host_ip" "$current_port"
    prompt_default="$REPLY"
    prompt_with_default 'Port for llama-server' "$prompt_default"
    selected_port="$REPLY"

    err 'Validating selected port...'

    if llama_api_responding "$host_ip" "$selected_port"; then
      llama_describe_existing_instance "$selected_port" "$host_ip" >/dev/null 2>&1 || true

      if [ "$prompt_mode" = 'dedicated' ] && llama_existing_instance_is_current_user_managed; then
        managed_runtime_matches=false
        if llama_files_match_mode user; then
          managed_runtime_matches=true
        elif user_has_sudo && llama_files_match_mode system; then
          managed_runtime_matches=true
        fi
        while true; do
          error "ClawBox-managed llama-server already running at http://$host_ip:$selected_port"
          llama_print_existing_instance_details "$selected_port"
          blank_line
          if [ "$managed_runtime_matches" = true ]; then
            out "1) Use the existing running llama-server on port $selected_port (recommended)"
            out "2) Restart the existing llama-server on port $selected_port"
          else
            warn 'The running ClawBox service does not match the current .env runtime settings.'
            out 'Reuse will not apply the current .env changes.'
            out "1) Use the existing running llama-server on port $selected_port without applying .env changes"
            out "2) Restart the existing llama-server on port $selected_port to apply .env changes (recommended)"
          fi
          out '3) Choose a different port'
          out '4) Exit setup'
          blank_line

          choice="$(llama_read_choice 'Choose [1-4]:')"
          if [ -z "$choice" ]; then
            choice='1'
          fi

          case "$choice" in
            1)
              LLAMA_USE_EXISTING_INSTANCE=true
              LLAMA_EXTERNAL=false
              REPLY="$selected_port"
              return 0
              ;;
            2)
              if stop_user_owned_llama_instance "$host_ip" "$selected_port"; then
                LLAMA_USE_EXISTING_INSTANCE=false
                LLAMA_EXTERNAL=false
                REPLY="$selected_port"
                return 0
              fi

              warn 'Existing ClawBox-managed instance could not be restarted.'
              out 'Choose a different port or inspect the current service state.'
              blank_line
              ;;
            3)
              current_port="$selected_port"
              break
              ;;
            4)
              return "$LLAMA_EXIT_GRACEFUL"
              ;;
            *)
              error 'Invalid selection. Enter one of the listed options.'
              ;;
          esac
        done

        continue
      fi

      if [ "$prompt_mode" = 'dedicated' ]; then
        error "A llama-server instance is already using http://$host_ip:$selected_port"
        llama_print_existing_instance_details "$selected_port"
        blank_line
        out 'Choose a different port for the dedicated ClawBox-managed instance.'
        blank_line
        current_port="$selected_port"
        continue
      fi

      if [ "$LLAMA_EXISTING_INSTANCE_RECOMMENDED" = true ]; then
        reuse_label='Use this existing instance (recommended)'
        alternate_label='Choose a different port'
      else
        reuse_label='Use this existing instance'
        alternate_label='Choose a different port (recommended)'
      fi

      error "LLaMA server already running at http://$host_ip:$selected_port"
      llama_print_existing_instance_details "$selected_port"
      blank_line
      out "1) $reuse_label"
      out "2) $alternate_label"
      out '3) Exit setup'
      blank_line

      while true; do
        choice="$(llama_read_choice 'Choose [1-3]:')"
        if [ -z "$choice" ]; then
          choice='1'
        fi

        case "$choice" in
          1)
            LLAMA_USE_EXISTING_INSTANCE=true
            if llama_existing_instance_is_external; then
              LLAMA_EXTERNAL=true
            else
              LLAMA_EXTERNAL=false
            fi
            REPLY="$selected_port"
            return 0
            ;;
          2)
            current_port="$selected_port"
            break
            ;;
          3)
            return "$LLAMA_EXIT_GRACEFUL"
            ;;
          *)
            error 'Invalid selection. Enter one of the listed options.'
            out "1) $reuse_label"
            out "2) $alternate_label"
            out '3) Exit setup'
            blank_line
            ;;
        esac
      done

      continue
    fi

    if llama_port_in_use "$selected_port"; then
      error "Port $selected_port is already in use by another process."
      out 'Choose a different port.'
      blank_line
      continue
    fi

    llama_show_port_conflict_warning "$selected_port"
    REPLY="$selected_port"
    return 0
  done
}

llama_update_connection_values() {
  local host_ip="$1"
  local port="$2"

  LLAMA_PORT="$port"

  if [ -n "$host_ip" ]; then
    HOST_IP="$host_ip"
    LLAMA_BASE_URL="http://$host_ip:$port/v1"
  fi

  if command -v write_env_from_template >/dev/null 2>&1; then
    write_env_from_template
  fi

  if command -v source_env_file >/dev/null 2>&1; then
    source_env_file || return $?
  fi

  return 0
}

llama_show_recent_error_log() {
  local mode="${1:-${LLAMA_ACTIVE_MODE:-user}}"
  local stderr_path=''

  stderr_path="$(llama_mode_stderr_log "$mode")"

  out 'Recent llama-server logs:'
  tail -n 20 "$stderr_path" 2>/dev/null || out '(no log output)'
}

llama_service_loaded() {
  local mode="$1"
  local target

  target="$(llama_mode_target "$mode")"

  if [ "$mode" = 'system' ] && ! user_has_sudo; then
    return 1
  fi

  llama_maybe_sudo "$mode" launchctl print "$target" >/dev/null 2>&1
}

llama_files_match_mode() {
  local mode="$1"
  local wrapper_src
  local wrapper_dest
  local env_dest
  local plist_dest
  local env_temp
  local plist_temp
  local stdout_path
  local stderr_path
  local matches=false

  wrapper_src="$(llama_wrapper_src)"
  wrapper_dest="$(llama_mode_wrapper_dest "$mode")"
  env_dest="$(llama_mode_env_dest "$mode")"
  plist_dest="$(llama_mode_plist_dest "$mode")"
  stdout_path="$(llama_mode_stdout_log "$mode")"
  stderr_path="$(llama_mode_stderr_log "$mode")"
  env_temp="$(mktemp)"
  plist_temp="$(mktemp)"

  write_llama_runtime_env "$env_temp"
  llama_render_plist "$plist_temp" "$wrapper_dest" "$env_dest" "$stdout_path" "$stderr_path"

  if [ -f "$wrapper_dest" ] && [ -f "$env_dest" ] && [ -f "$plist_dest" ] \
    && cmp -s "$wrapper_src" "$wrapper_dest" \
    && cmp -s "$env_temp" "$env_dest" \
    && cmp -s "$plist_temp" "$plist_dest"; then
    matches=true
  fi

  rm -f "$env_temp" "$plist_temp"

  [ "$matches" = true ]
}

detect_existing_llama_install_mode() {
  if llama_files_match_mode user; then
    REPLY='user'
    return 0
  fi

  if user_has_sudo && llama_files_match_mode system; then
    REPLY='system'
    return 0
  fi

  REPLY=''
  return 1
}

detect_existing_llama_install_mode_for_connection() {
  local host_ip="$1"
  local port="$2"
  local original_host_ip="${HOST_IP-}"
  local original_llama_port="${LLAMA_PORT-}"
  local original_llama_base_url="${LLAMA_BASE_URL-}"
  local status=0

  if [ -n "$host_ip" ]; then
    HOST_IP="$host_ip"
  fi

  if [ -n "$port" ]; then
    LLAMA_PORT="$port"
    if [ -n "${HOST_IP:-}" ]; then
      LLAMA_BASE_URL="http://${HOST_IP}:${port}/v1"
    fi
  fi

  detect_existing_llama_install_mode
  status=$?

  HOST_IP="$original_host_ip"
  LLAMA_PORT="$original_llama_port"
  LLAMA_BASE_URL="$original_llama_base_url"

  return "$status"
}

LLAMA_EXISTING_INSTANCE_PID=''
LLAMA_EXISTING_INSTANCE_OWNER=''
LLAMA_EXISTING_INSTANCE_RUNTIME=''
LLAMA_EXISTING_INSTANCE_MODE=''
LLAMA_EXISTING_INSTANCE_OWNER_LINE=''
LLAMA_EXISTING_INSTANCE_NOTE=''
LLAMA_EXISTING_INSTANCE_LAUNCH_LABEL=''
LLAMA_EXISTING_INSTANCE_BINARY_PATH=''
LLAMA_EXISTING_INSTANCE_RECOMMENDED=false
LLAMA_EXISTING_INSTANCE_CONTROLLABLE=false

llama_trim_value() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

llama_reset_existing_instance_context() {
  LLAMA_EXISTING_INSTANCE_PID=''
  LLAMA_EXISTING_INSTANCE_OWNER=''
  LLAMA_EXISTING_INSTANCE_RUNTIME=''
  LLAMA_EXISTING_INSTANCE_MODE=''
  LLAMA_EXISTING_INSTANCE_OWNER_LINE=''
  LLAMA_EXISTING_INSTANCE_NOTE=''
  LLAMA_EXISTING_INSTANCE_LAUNCH_LABEL=''
  LLAMA_EXISTING_INSTANCE_BINARY_PATH=''
  LLAMA_EXISTING_INSTANCE_RECOMMENDED=false
  LLAMA_EXISTING_INSTANCE_CONTROLLABLE=false
}

llama_existing_instance_is_current_user_managed() {
  case "${LLAMA_EXISTING_INSTANCE_RUNTIME:-}" in
    'ClawBox-managed LaunchAgent'|'current user LaunchAgent')
      return 0
      ;;
  esac

  return 1
}

llama_existing_instance_is_external() {
  case "${LLAMA_EXISTING_INSTANCE_RUNTIME:-}" in
    'ClawBox-managed LaunchAgent'|'ClawBox-managed system-wide LaunchDaemon'|'current user LaunchAgent')
      return 1
      ;;
  esac

  return 0
}

llama_print_existing_instance_details() {
  local port="${1:-${LLAMA_PORT:-}}"

  outf 'Port: %s' "$port"

  if [ -n "${LLAMA_EXISTING_INSTANCE_LAUNCH_LABEL:-}" ]; then
    outf 'Launch label: %s' "$LLAMA_EXISTING_INSTANCE_LAUNCH_LABEL"
  fi

  if [ -n "${LLAMA_EXISTING_INSTANCE_BINARY_PATH:-}" ]; then
    outf 'Binary: %s' "$LLAMA_EXISTING_INSTANCE_BINARY_PATH"
  fi

  out "$LLAMA_EXISTING_INSTANCE_OWNER_LINE"

  if [ -n "$LLAMA_EXISTING_INSTANCE_NOTE" ]; then
    if [ "${LLAMA_EXISTING_INSTANCE_RUNTIME:-}" = 'cross-user-session' ]; then
      error "$LLAMA_EXISTING_INSTANCE_NOTE"
    else
      out "$LLAMA_EXISTING_INSTANCE_NOTE"
    fi
  fi
}

llama_listening_pid() {
  local port="${1:-${LLAMA_PORT:-}}"

  REPLY=''

  if [ -z "$port" ] || ! command -v lsof >/dev/null 2>&1; then
    return 1
  fi

  REPLY="$(lsof -i :"$port" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
  [ -n "$REPLY" ]
}

llama_port_has_local_listener() {
  local port="${1:-${LLAMA_PORT:-}}"

  REPLY=''

  if [ -z "$port" ] || ! command -v netstat >/dev/null 2>&1; then
    return 1
  fi

  REPLY="$(netstat -an 2>/dev/null | grep -E "(^|[[:space:]])tcp" | grep -E "[.:]$port[[:space:]].*LISTEN" | head -n 1 || true)"
  [ -n "$REPLY" ]
}

llama_listening_port_numbers() {
  REPLY=''

  if ! command -v netstat >/dev/null 2>&1; then
    return 1
  fi

  REPLY="$(
    netstat -an 2>/dev/null \
      | awk '
        /tcp/ && /LISTEN/ {
          local_addr=$4
          if (local_addr ~ /[.:][0-9]+$/) {
            port=local_addr
            sub(/^.*[.:]/, "", port)
            if (port ~ /^[0-9]+$/) {
              print port
            }
          }
        }
      ' \
      | awk '!seen[$0]++'
  )"

  [ -n "$REPLY" ]
}

llama_is_healthy_endpoint() {
  local host_ip="${1:-${HOST_IP:-}}"
  local port="${2:-${LLAMA_PORT:-}}"

  REPLY=''

  if [ -z "$host_ip" ] || [ -z "$port" ]; then
    return 1
  fi

  if ! llama_port_has_local_listener "$port"; then
    return 1
  fi

  if ! llama_api_responding "$host_ip" "$port"; then
    return 1
  fi

  REPLY='healthy'
  return 0
}

llama_discover_healthy_instance_port() {
  local host_ip="${1:-${HOST_IP:-}}"
  local preferred_port="${2:-${LLAMA_PORT:-}}"
  local discovered_ports=''
  local port=''

  REPLY=''

  if [ -n "$preferred_port" ] && llama_is_healthy_endpoint "$host_ip" "$preferred_port"; then
    REPLY="$preferred_port"
    return 0
  fi

  if ! llama_listening_port_numbers; then
    return 1
  fi
  discovered_ports="$REPLY"

  while IFS= read -r port; do
    if [ -z "$port" ] || [ "$port" = "$preferred_port" ]; then
      continue
    fi

    if llama_is_healthy_endpoint "$host_ip" "$port"; then
      REPLY="$port"
      return 0
    fi
  done <<EOF
$discovered_ports
EOF

  return 1
}

LLAMA_INSTANCE_HEALTH='inactive'
LLAMA_INSTANCE_HAS_PROCESS=false
LLAMA_INSTANCE_HAS_LISTENER=false
LLAMA_INSTANCE_HEALTHCHECK_OK=false
LLAMA_INSTANCE_LAUNCHD_LOADED=false

llama_classify_runtime_health() {
  local host_ip="${1:-${HOST_IP:-}}"
  local port="${2:-${LLAMA_PORT:-}}"
  local process_line=''

  LLAMA_INSTANCE_HEALTH='inactive'
  LLAMA_INSTANCE_HAS_PROCESS=false
  LLAMA_INSTANCE_HAS_LISTENER=false
  LLAMA_INSTANCE_HEALTHCHECK_OK=false
  LLAMA_INSTANCE_LAUNCHD_LOADED=false

  if [ -z "$port" ]; then
    REPLY="$LLAMA_INSTANCE_HEALTH"
    return 0
  fi

  process_line="$(
    ps -axo pid=,command= 2>/dev/null \
      | grep -E '(^|[[:space:]])([^[:space:]]*/)?llama-server([[:space:]]|$)' \
      | grep -E -- "--port[[:space:]]+$port([[:space:]]|$)" \
      | head -n 1 || true
  )"
  if [ -n "$process_line" ]; then
    LLAMA_INSTANCE_HAS_PROCESS=true
  fi

  if llama_port_has_local_listener "$port"; then
    LLAMA_INSTANCE_HAS_LISTENER=true
  fi

  if llama_api_responding "$host_ip" "$port"; then
    LLAMA_INSTANCE_HEALTHCHECK_OK=true
  fi

  if llama_service_loaded user; then
    LLAMA_INSTANCE_LAUNCHD_LOADED=true
  fi

  if [ "$LLAMA_INSTANCE_HAS_LISTENER" = true ] && [ "$LLAMA_INSTANCE_HEALTHCHECK_OK" = true ]; then
    LLAMA_INSTANCE_HEALTH='healthy'
  elif [ "$LLAMA_INSTANCE_HAS_PROCESS" = true ] \
    || [ "$LLAMA_INSTANCE_HAS_LISTENER" = true ] \
    || [ "$LLAMA_INSTANCE_HEALTHCHECK_OK" = true ] \
    || [ "$LLAMA_INSTANCE_LAUNCHD_LOADED" = true ]; then
    LLAMA_INSTANCE_HEALTH='unhealthy'
  else
    LLAMA_INSTANCE_HEALTH='inactive'
  fi

  REPLY="$LLAMA_INSTANCE_HEALTH"
  return 0
}

llama_ps_value() {
  local field="$1"
  local pid="$2"

  REPLY=''

  if [ -z "$field" ] || [ -z "$pid" ]; then
    return 1
  fi

  REPLY="$(ps -o "$field=" -p "$pid" 2>/dev/null | head -n 1 || true)"
  REPLY="$(llama_trim_value "$REPLY")"
  [ -n "$REPLY" ]
}

llama_describe_existing_instance() {
  local port="${1:-${LLAMA_PORT:-}}"
  local host_ip="${2:-${HOST_IP:-}}"
  local current_user=''
  local existing_mode=''
  local pid=''
  local owner=''
  local parent_pid=''
  local parent_command=''
  local command_line=''
  local listener_line=''
  local runtime='unknown ownership/runtime classification'
  local note='ClawBox could not determine whether this instance is durable.'
  local recommended=false
  local controllable=false
  local launch_label=''
  local binary_path=''

  llama_reset_existing_instance_context

  err 'Checking for existing llama-server instances...'

  current_user="$(id -un 2>/dev/null || whoami 2>/dev/null || true)"
  detect_existing_llama_install_mode_for_connection "$host_ip" "$port" >/dev/null 2>&1 || true
  existing_mode="$REPLY"

  llama_listening_pid "$port" >/dev/null 2>&1 || true
  pid="$REPLY"
  llama_port_has_local_listener "$port" >/dev/null 2>&1 || true
  listener_line="$REPLY"

  if [ -n "$pid" ]; then
    llama_ps_value user "$pid" >/dev/null 2>&1 || true
    owner="$REPLY"
    llama_ps_value ppid "$pid" >/dev/null 2>&1 || true
    parent_pid="$REPLY"

    if [ -n "$parent_pid" ]; then
      llama_ps_value command "$parent_pid" >/dev/null 2>&1 || true
      parent_command="$REPLY"
    fi

    llama_ps_value command "$pid" >/dev/null 2>&1 || true
    command_line="$REPLY"
    binary_path="${command_line%% *}"
  fi

  if [ -n "$existing_mode" ]; then
    launch_label='com.clawbox.llama'
    if [ -n "${LLAMA_BIN:-}" ]; then
      binary_path="$LLAMA_BIN"
    fi

    case "$existing_mode" in
      user)
        runtime='ClawBox-managed LaunchAgent'
        note='This instance is managed by ClawBox for the current user.'
        recommended=true
        controllable=true
        ;;
      system)
        runtime='ClawBox-managed system-wide LaunchDaemon'
        note='This instance is managed by ClawBox system-wide.'
        recommended=true
        ;;
    esac
  elif [ -n "$owner" ] && [ -n "$parent_command" ] && [[ "$parent_command" == *launchd* ]]; then
    if [ "$owner" = 'root' ]; then
      runtime='system-wide LaunchDaemon'
      note='This service is managed system-wide by launchd.'
      recommended=true
    elif [ -n "$current_user" ] && [ "$owner" = "$current_user" ]; then
      runtime='current user LaunchAgent'
      note='This service is managed by launchd for the current user.'
      recommended=true
      controllable=true
    else
      runtime='LaunchAgent for another macOS user'
      note="This instance depends on the \"$owner\" account remaining logged in."
    fi
  elif [ -n "$owner" ]; then
    if [ -n "$current_user" ] && [ "$owner" = "$current_user" ]; then
      runtime='current user session'
      note='This instance will stop if you log out.'
      controllable=true
    else
      runtime='interactive user session'
      note="This instance depends on the \"$owner\" account remaining logged in."
    fi
  elif [ -n "$listener_line" ]; then
    owner='another macOS user session'
    runtime='cross-user-session'
    note='This instance may stop when the owning user logs out.'
  fi

  if [ -z "$owner" ]; then
    owner='unknown'
  fi

  LLAMA_EXISTING_INSTANCE_PID="$pid"
  LLAMA_EXISTING_INSTANCE_OWNER="$owner"
  LLAMA_EXISTING_INSTANCE_RUNTIME="$runtime"
  LLAMA_EXISTING_INSTANCE_MODE="$existing_mode"
  LLAMA_EXISTING_INSTANCE_LAUNCH_LABEL="$launch_label"
  LLAMA_EXISTING_INSTANCE_BINARY_PATH="$binary_path"
  if [ "$runtime" = 'cross-user-session' ]; then
    LLAMA_EXISTING_INSTANCE_OWNER_LINE='Owner: another macOS user session (process ownership not accessible)'
  else
    LLAMA_EXISTING_INSTANCE_OWNER_LINE="Owner: $owner ($runtime)"
  fi
  LLAMA_EXISTING_INSTANCE_NOTE="$note"
  LLAMA_EXISTING_INSTANCE_RECOMMENDED="$recommended"
  LLAMA_EXISTING_INSTANCE_CONTROLLABLE="$controllable"
  REPLY="$pid"

  [ -n "$pid" ]
}

llama_verify_service_health() {
  local attempt=1
  local api_url=''
  local choice=''
  local selected_port=''

  step "Waiting for llama-server port"
  while [ "$attempt" -le 120 ]; do
    if llama_port_in_use "$LLAMA_PORT"; then
      break
    fi

    attempt=$((attempt + 1))
    if [ $((attempt % 15)) -eq 0 ]; then
      out "Still waiting for llama-server port ($attempt/120 seconds)..."
    fi
    sleep 1
  done

  if [ "$attempt" -le 120 ]; then
    attempt=1
    while [ "$attempt" -le 120 ]; do
      if llama_api_responding "${HOST_IP:-}" "$LLAMA_PORT"; then
        success "llama-server is responding on port $LLAMA_PORT"
        return 0
      fi

      attempt=$((attempt + 1))
      if [ $((attempt % 15)) -eq 0 ]; then
        out "Still waiting for llama-server API readiness ($attempt/120 seconds)..."
      fi
      sleep 1
    done
  fi

  api_url="$(llama_api_url "${HOST_IP:-}" "$LLAMA_PORT")" || api_url="http://${HOST_IP:-}:${LLAMA_PORT:-}/v1/models"
  error "llama-server did not respond at $api_url"
  err 'Possible causes:'
  err '- Port conflict'
  err '- Startup failure'
  err '- Incorrect configuration'
  err_blank_line

  while true; do
    out '1) Retry startup'
    out '2) Change port'
    out '3) View logs'
    out '4) Exit'
    blank_line

    choice="$(llama_read_choice 'Choose [1-4]:')"
    if [ -z "$choice" ]; then
      choice='1'
    fi

    case "$choice" in
      1)
        return "$LLAMA_EXIT_RETRY"
        ;;
      2)
        llama_prompt_for_available_port "${HOST_IP:-}" "$LLAMA_PORT" || return $?
        selected_port="$REPLY"
        llama_update_connection_values "${HOST_IP:-}" "$selected_port" || return $?
        return "$LLAMA_EXIT_CHANGE_PORT"
        ;;
      3)
        llama_show_recent_error_log "${LLAMA_ACTIVE_MODE:-user}"
        err_blank_line
        ;;
      4)
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
      *)
        err 'Invalid selection. Enter one of the listed options.'
        ;;
    esac
  done
}
