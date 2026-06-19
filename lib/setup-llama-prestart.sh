stop_user_owned_llama_instance() {
  local host_ip_value="$1"
  local llama_port_value="$2"
  local existing_llama_mode=''
  local plist_dest=''
  local stopped_any=false
  local attempt=1

  detect_existing_llama_install_mode_for_connection "$host_ip_value" "$llama_port_value" >/dev/null 2>&1 || true
  existing_llama_mode="$REPLY"

  # Stop LaunchAgent if it's ours
  if [ "$existing_llama_mode" = 'user' ]; then
    plist_dest="$(llama_mode_plist_dest "$existing_llama_mode")"
    launchctl bootout "$(llama_mode_domain "$existing_llama_mode")" "$plist_dest" >/dev/null 2>&1 || true
    stopped_any=true
  fi

  # Only kill processes owned by this user
  if pgrep -u "$(id -u)" -f 'llama-server' >/dev/null 2>&1; then
    pkill -u "$(id -u)" -f 'llama-server' >/dev/null 2>&1 || true
    stopped_any=true
  fi

  if [ "$stopped_any" != true ]; then
    return 1
  fi

  while [ "$attempt" -le 5 ]; do
    if ! llama_api_responding "$host_ip_value" "$llama_port_value"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  return 1
}

resolve_prestart_llama_port() {
  local host_ip_value="$1"
  local llama_port_value="$2"
  local discovered_port=''
  local configured_endpoint_unhealthy=false

  REPLY="$llama_port_value"

  llama_classify_runtime_health "$host_ip_value" "$llama_port_value" >/dev/null 2>&1 || true

  if [ "$LLAMA_INSTANCE_HEALTH" = 'unhealthy' ]; then
    configured_endpoint_unhealthy=true
    warn "Detected unhealthy llama-server state at http://$host_ip_value:$llama_port_value"
    out 'Readiness checks:'
    out "  Process present: $LLAMA_INSTANCE_HAS_PROCESS"
    out "  Listening socket: $LLAMA_INSTANCE_HAS_LISTENER"
    out "  Health endpoint: $LLAMA_INSTANCE_HEALTHCHECK_OK"
    out "  launchd loaded: $LLAMA_INSTANCE_LAUNCHD_LOADED"
    blank_line
  fi

  if llama_discover_healthy_instance_port "$host_ip_value" "$llama_port_value"; then
    discovered_port="$REPLY"
    if [ "$discovered_port" != "$llama_port_value" ]; then
      if [ "$configured_endpoint_unhealthy" = true ]; then
        out "Configured endpoint $llama_port_value is unhealthy."
        out "Using discovered healthy endpoint $discovered_port instead."
      else
        out "Found healthy llama-server endpoint at http://$host_ip_value:$discovered_port"
      fi
      blank_line
    fi
    return 0
  fi

  REPLY="$llama_port_value"
  return 0
}

run_prestart_llama_instance_flow() {
  local host_ip_value="$1"
  local llama_port_value="$2"
  local resolved_port=''

  resolve_prestart_llama_port "$host_ip_value" "$llama_port_value"
  resolved_port="$REPLY"

  handle_prestart_llama_instance_choice "$host_ip_value" "$resolved_port"
}

handle_prestart_llama_instance_choice() {
  local host_ip_value="$1"
  local llama_port_value="$2"
  local choice=''
  local original_llama_external="${LLAMA_EXTERNAL:-false}"
  local reuse_label='Use existing instance'
  local managed_label='Stop existing instance and use ClawBox-managed instance'
  local managed_action='replace'
  local managed_instance_reuse_first=false

  LLAMA_USE_EXISTING_INSTANCE=false
  LLAMA_EXTERNAL=false

  if LLAMA_EXTERNAL="$original_llama_external" llama_api_responding "$host_ip_value" "$llama_port_value"; then
    llama_describe_existing_instance "$llama_port_value" "$host_ip_value" >/dev/null 2>&1 || true

    if llama_existing_instance_is_current_user_managed; then
      reuse_label="Use the existing running llama-server on port $llama_port_value"
      managed_label="Restart the existing llama-server on port $llama_port_value"
      managed_action='restart-managed'
      managed_instance_reuse_first=true
    elif [ "$LLAMA_EXISTING_INSTANCE_RUNTIME" = 'cross-user-session' ] \
      || [ "$LLAMA_EXISTING_INSTANCE_RUNTIME" = 'interactive user session' ] \
      || [ "$LLAMA_EXISTING_INSTANCE_RUNTIME" = 'LaunchAgent for another macOS user' ]; then
      managed_action='alternate-port'
      managed_label='Start a separate ClawBox-managed instance on another port'
    elif [ "$LLAMA_EXISTING_INSTANCE_CONTROLLABLE" = true ]; then
      managed_action='replace'
      managed_label='Stop existing instance and use ClawBox-managed instance'
    else
      managed_action='replace'
      managed_label='Stop existing instance and use ClawBox-managed instance'
    fi

    if [ "$managed_instance_reuse_first" = true ]; then
      reuse_label="$reuse_label (recommended)"
    else
      case "$reuse_label" in
        *' (recommended)')
          reuse_label="${reuse_label% (recommended)}"
          ;;
      esac

      case "$managed_label" in
        *' (recommended)')
          ;;
        *)
          managed_label="$managed_label (recommended)"
          ;;
      esac
    fi

    while true; do
      blank_line
      warn "llama-server detected at http://$host_ip_value:$llama_port_value"
      llama_print_existing_instance_details "$llama_port_value"
      blank_line
      if [ "$managed_instance_reuse_first" = true ]; then
        out "1) $reuse_label"
        out "2) $managed_label"
      else
        out "1) $managed_label"
        out "2) $reuse_label"
      fi
      out '3) Choose a different port'
      out '4) Exit'
      blank_line

      choice="$(llama_read_choice 'Choose [1-4]:')"
      if [ -z "$choice" ]; then
        choice='1'
      fi

      case "$choice" in
        1)
          if [ "$managed_instance_reuse_first" = true ]; then
            LLAMA_USE_EXISTING_INSTANCE=true
            LLAMA_EXTERNAL=false
            REPLY="$llama_port_value"
            return 0
          fi

          if [ "$managed_action" = 'alternate-port' ]; then
            llama_prompt_for_available_port "$host_ip_value" "$llama_port_value" 'dedicated' || return $?
            REPLY="$REPLY"
            return 0
          fi

          if [ "$managed_action" = 'restart-managed' ]; then
            if stop_user_owned_llama_instance "$host_ip_value" "$llama_port_value"; then
              LLAMA_EXTERNAL=false
              REPLY="$llama_port_value"
              return 0
            fi

            warn 'Existing ClawBox-managed instance could not be restarted.'
            out 'Choose another port or inspect the current service state.'
            blank_line
            continue
          fi

          if stop_user_owned_llama_instance "$host_ip_value" "$llama_port_value"; then
            LLAMA_EXTERNAL=false
            REPLY="$llama_port_value"
            return 0
          fi

          warn 'Existing llama-server is not owned by this user.'
          out 'ClawBox will not stop an instance it does not control.'
          blank_line
          ;;
        2)
          if [ "$managed_instance_reuse_first" = true ]; then
            if stop_user_owned_llama_instance "$host_ip_value" "$llama_port_value"; then
              LLAMA_EXTERNAL=false
              REPLY="$llama_port_value"
              return 0
            fi

            warn 'Existing ClawBox-managed instance could not be restarted.'
            out 'Choose another port or inspect the current service state.'
            blank_line
            continue
          fi

          LLAMA_USE_EXISTING_INSTANCE=true
          if llama_existing_instance_is_external; then
            LLAMA_EXTERNAL=true
          else
            LLAMA_EXTERNAL=false
          fi
          REPLY="$llama_port_value"
          return 0
          ;;
        3)
          llama_prompt_for_available_port "$host_ip_value" "$llama_port_value" || return $?
          REPLY="$REPLY"
          return 0
          ;;
        4)
          return "$LLAMA_EXIT_GRACEFUL"
          ;;
        *)
          error 'Invalid selection. Enter one of the listed options.'
          ;;
      esac
    done
  fi

  if ! llama_port_in_use "$llama_port_value"; then
    llama_show_port_conflict_warning "$llama_port_value"
    REPLY="$llama_port_value"
    return 0
  fi

  while true; do
    blank_line
    warn "llama-server detected at http://$host_ip_value:$llama_port_value"
    blank_line
    out '1) Retry (wait for service to become ready)'
    out '2) Stop existing instance and use ClawBox-managed instance'
    out '3) Choose a different port'
    out '4) View logs'
    out '5) Exit'
    blank_line

    choice="$(llama_read_choice 'Choose [1-5]:')"
    if [ -z "$choice" ]; then
      choice='1'
    fi

    case "$choice" in
      1)
        return "$LLAMA_EXIT_RETRY"
        ;;
      2)
        if stop_user_owned_llama_instance "$host_ip_value" "$llama_port_value"; then
          REPLY="$llama_port_value"
          return 0
        fi

        warn 'Existing process is not owned by this user.'
        out 'ClawBox will not stop an instance it does not control.'
        blank_line
        ;;
      3)
        llama_prompt_for_available_port "$host_ip_value" "$llama_port_value" || return $?
        REPLY="$REPLY"
        return 0
        ;;
      4)
        llama_show_recent_error_log
        blank_line
        ;;
      5)
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
      *)
        error 'Invalid selection. Enter one of the listed options.'
        ;;
    esac
  done
}
