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

prestart_discovered_port_is_embeddings_endpoint() {
  local host_ip_value="${1:-}"
  local discovered_port="${2:-}"
  local embeddings_url="${EMBEDDINGS_LLAMA_BASE_URL:-}"

  [ -n "$discovered_port" ] || return 1

  if clawbox_bool_enabled "${EMBEDDINGS_ENABLED:-false}"; then
    if [ -n "${EMBEDDINGS_LLAMA_PORT:-}" ] && [ "$discovered_port" = "$EMBEDDINGS_LLAMA_PORT" ]; then
      return 0
    fi

    case "$embeddings_url" in
      "http://$host_ip_value:$discovered_port"|\
      "http://$host_ip_value:$discovered_port/"*|\
      "https://$host_ip_value:$discovered_port"|\
      "https://$host_ip_value:$discovered_port/"*|\
      "http://127.0.0.1:$discovered_port"|\
      "http://127.0.0.1:$discovered_port/"*|\
      "https://127.0.0.1:$discovered_port"|\
      "https://127.0.0.1:$discovered_port/"*|\
      "http://localhost:$discovered_port"|\
      "http://localhost:$discovered_port/"*|\
      "https://localhost:$discovered_port"|\
      "https://localhost:$discovered_port/"*)
        return 0
        ;;
    esac
  fi

  return 1
}

prestart_llama_has_identified_runtime_evidence() {
  [ "${LLAMA_INSTANCE_HAS_PROCESS:-false}" = true ] && return 0
  [ "${LLAMA_INSTANCE_HEALTHCHECK_OK:-false}" = true ] && return 0
  [ "${LLAMA_INSTANCE_LOCAL_HEALTHCHECK_OK:-false}" = true ] && return 0
  [ "${LLAMA_INSTANCE_LAUNCHD_LOADED:-false}" = true ] && return 0
  return 1
}

print_prestart_llama_runtime_diagnosis() {
  local host_ip_value="$1"
  local llama_port_value="$2"

  if prestart_llama_has_identified_runtime_evidence; then
    warn "Detected unhealthy llama-server state at http://$host_ip_value:$llama_port_value"
  elif [ "${LLAMA_INSTANCE_HAS_LISTENER:-false}" = true ]; then
    warn "Port $llama_port_value is already in use."
    out 'The listener on this port does not appear to be a healthy ClawBox-managed llama-server.'
  else
    warn "Detected unhealthy llama-server state at http://$host_ip_value:$llama_port_value"
  fi

  out 'Readiness checks:'
  out "  Process present: ${LLAMA_INSTANCE_HAS_PROCESS:-false}"
  out "  Listening socket: ${LLAMA_INSTANCE_HAS_LISTENER:-false}"
  out "  Health endpoint: ${LLAMA_INSTANCE_HEALTHCHECK_OK:-false}"
  out "  launchd loaded: ${LLAMA_INSTANCE_LAUNCHD_LOADED:-false}"
}

print_prestart_llama_port_menu_heading() {
  local host_ip_value="$1"
  local llama_port_value="$2"

  if prestart_llama_has_identified_runtime_evidence; then
    warn "Unhealthy llama-server detected at http://$host_ip_value:$llama_port_value"
  else
    warn "Port $llama_port_value is already in use."
    out 'The listener on this port does not appear to be a healthy ClawBox-managed llama-server.'
  fi
}

resolve_prestart_llama_port() {
  local host_ip_value="$1"
  local llama_port_value="$2"
  local discovery_mode="${3:-discover}"
  local discovered_port=''
  local configured_endpoint_unhealthy=false

  REPLY="$llama_port_value"

  llama_classify_runtime_health "$host_ip_value" "$llama_port_value" >/dev/null 2>&1 || true

  if [ "$LLAMA_INSTANCE_HEALTH" = 'unhealthy' ]; then
    configured_endpoint_unhealthy=true
    print_prestart_llama_runtime_diagnosis "$host_ip_value" "$llama_port_value"
    blank_line
  fi

  if [ "$discovery_mode" = 'selected' ]; then
    REPLY="$llama_port_value"
    return 0
  fi

  if [ "$LLAMA_INSTANCE_HEALTH" = 'healthy' ] \
    && [ "${LLAMA_INSTANCE_LOCAL_HEALTHCHECK_OK:-false}" = true ] \
    && [ "${LLAMA_INSTANCE_HEALTHCHECK_OK:-false}" != true ]; then
    REPLY="$llama_port_value"
    return 0
  fi

  if llama_discover_healthy_instance_port "$host_ip_value" "$llama_port_value"; then
    discovered_port="$REPLY"
    if [ "$discovered_port" != "$llama_port_value" ]; then
      if prestart_discovered_port_is_embeddings_endpoint "$host_ip_value" "$discovered_port"; then
        if [ "$configured_endpoint_unhealthy" = true ]; then
          out "Configured primary endpoint $llama_port_value is unhealthy."
          out "Discovered healthy endpoint $discovered_port is the configured embeddings endpoint, so it will not be used as primary."
        else
          out "Discovered healthy endpoint $discovered_port is the configured embeddings endpoint, so it will not be used as primary."
        fi
        blank_line
        REPLY="$llama_port_value"
        return 0
      fi

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
  local discovery_mode="${3:-discover}"
  local resolved_port=''

  resolve_prestart_llama_port "$host_ip_value" "$llama_port_value" "$discovery_mode"
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
  local managed_runtime_matches=true
  local existing_instance_responding=false
  local local_readiness_host=''

  LLAMA_USE_EXISTING_INSTANCE=false
  LLAMA_EXTERNAL=false

  if LLAMA_EXTERNAL="$original_llama_external" llama_api_responding "$host_ip_value" "$llama_port_value"; then
    existing_instance_responding=true
  elif [ "${LLAMA_EXTERNAL:-false}" != true ]; then
    local_readiness_host="$(llama_local_readiness_host "${LLAMA_HOST:-}")"
    if [ -n "$local_readiness_host" ] \
      && [ "$local_readiness_host" != "$host_ip_value" ] \
      && LLAMA_EXTERNAL="$original_llama_external" llama_api_responding "$local_readiness_host" "$llama_port_value"; then
      existing_instance_responding=true
      LLAMA_INSTANCE_LOCAL_HEALTHCHECK_OK=true
    fi
  fi

  if [ "$existing_instance_responding" = true ]; then
    llama_describe_existing_instance "$llama_port_value" "$host_ip_value" >/dev/null 2>&1 || true

    if llama_existing_instance_is_current_user_managed; then
      reuse_label="Use the existing running llama-server on port $llama_port_value"
      managed_label="Restart the existing llama-server on port $llama_port_value"
      managed_action='restart-managed'
      managed_instance_reuse_first=true

      managed_runtime_matches=false
      if llama_runtime_env_matches_mode user; then
        managed_runtime_matches=true
      elif user_has_sudo && llama_runtime_env_matches_mode system; then
        managed_runtime_matches=true
      fi
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
      if [ "$managed_runtime_matches" = true ]; then
        reuse_label="$reuse_label (recommended)"
      else
        reuse_label="$reuse_label without applying .env changes"
        managed_label="$managed_label to apply .env changes (recommended)"
      fi
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
      if [ "$LLAMA_INSTANCE_LOCAL_HEALTHCHECK_OK" = true ] && [ "$LLAMA_INSTANCE_HEALTHCHECK_OK" != true ]; then
        warn "llama-server detected at http://$local_readiness_host:$llama_port_value"
        out "VM-facing endpoint is not reachable yet: http://$host_ip_value:$llama_port_value"
        out 'The UTM/VM host network interface may be offline because the selected VM is stopped.'
      else
        warn "llama-server detected at http://$host_ip_value:$llama_port_value"
      fi
      llama_print_existing_instance_details "$llama_port_value"
      blank_line
      if [ "$managed_instance_reuse_first" = true ]; then
        if [ "$managed_runtime_matches" != true ]; then
          warn 'The running ClawBox service does not match the current .env runtime settings.'
          out 'Reuse will not apply the current .env changes.'
        fi
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
    print_prestart_llama_port_menu_heading "$host_ip_value" "$llama_port_value"
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
