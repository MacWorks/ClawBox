vm_should_offer_ssh_bootstrap() {
  local ssh_probe_state="$1"
  local running_confidence="${2:-unknown}"

  case "$ssh_probe_state" in
    ready|ssh-auth-required|ssh-refused)
      return 0
      ;;
    ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict|ssh-remote-command-failed)
      return 1
      ;;
    unknown)
      if [ "$running_confidence" = 'exact' ]; then
        return 1
      fi
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

update_vm_ip_selection() {
  local vm_ip_value="$1"

  [ -n "$vm_ip_value" ] || return 1

  VM_IP="$vm_ip_value"
  VM_HOST="${VM_USER}@${vm_ip_value}"
  return 0
}

offer_vm_ip_recovery() {
  local discovered_candidates=''
  local candidate_count=0
  local candidate_ip=''
  local option_number=1
  local retry_option_number=0
  local abort_option_number=0
  local selected_option=''

  status_begin 'Attempting VM IP discovery...'

  if ! discover_vm_ip_candidates; then
    status_end 'VM IP discovery did not find a candidate.' 'warning'
    warn 'No likely VM IP addresses were discovered on the expected subnet.'
    return 1
  fi

  status_end 'VM IP discovery completed.' 'success'

  discovered_candidates="$REPLY"

  while IFS= read -r candidate_ip; do
    [ -n "$candidate_ip" ] || continue
    candidate_count=$((candidate_count + 1))
  done <<EOF
$discovered_candidates
EOF

  if [ "$candidate_count" -eq 1 ]; then
    candidate_ip="$discovered_candidates"
    warn "The current VM IP address (${VM_IP:-}) was unreachable."
    out "Detected likely VM address: $candidate_ip"
    prompt_yes_no 'Use this address?' 'y'

    if [ "$REPLY" = 'true' ]; then
      update_vm_ip_selection "$candidate_ip" || return 1
      success "Using detected VM address: $candidate_ip"
      return 0
    fi
  else
    warn "The current VM IP address (${VM_IP:-}) was unreachable."
    menu_begin 'Detected possible VM addresses:'

    while IFS= read -r candidate_ip; do
      [ -n "$candidate_ip" ] || continue
      outf '%s) %s' "$option_number" "$candidate_ip"
      option_number=$((option_number + 1))
    done <<EOF
$discovered_candidates
EOF

    retry_option_number="$option_number"
    abort_option_number=$((option_number + 1))
    outf '%s) Retry manual entry' "$retry_option_number"
    outf '%s) Abort setup' "$abort_option_number"
    menu_end

    while true; do
      prompt_with_suffix 'Choose VM address' "[1-$abort_option_number]"
      selected_option="$REPLY"

      if ! [[ "$selected_option" =~ ^[0-9]+$ ]]; then
        error "Invalid selection. Enter a number between 1 and $abort_option_number."
        continue
      fi

      if [ "$selected_option" -lt 1 ] || [ "$selected_option" -gt "$abort_option_number" ]; then
        error "Invalid selection. Enter a number between 1 and $abort_option_number."
        continue
      fi

      break
    done

    if [ "$selected_option" -lt "$retry_option_number" ]; then
      option_number=1
      while IFS= read -r candidate_ip; do
        [ -n "$candidate_ip" ] || continue
        if [ "$option_number" -eq "$selected_option" ]; then
          update_vm_ip_selection "$candidate_ip" || return 1
          success "Using detected VM address: $candidate_ip"
          return 0
        fi
        option_number=$((option_number + 1))
      done <<EOF
$discovered_candidates
EOF
    fi

    if [ "$selected_option" -eq "$abort_option_number" ]; then
      return 1
    fi
  fi

  prompt_with_default 'Enter VM IP address' "${VM_IP:-}"
  update_vm_ip_selection "$REPLY" || return 1
  return 0
}

prompt_for_vm_ip_replacement() {
  local replacement_ip=''

  prompt_with_default 'Enter replacement VM IP address' "${VM_IP:-}"
  replacement_ip="$REPLY"

  update_vm_ip_selection "$replacement_ip" || return 1
  success "Using entered VM address: $replacement_ip"
  return 0
}

print_possible_causes() {
  local cause=''

  out 'Possible causes:'
  blank_line

  for cause in "$@"; do
    out "- $cause"
  done

  blank_line
}

print_ssh_auth_status() {
  out 'SSH connectivity is working.'
  out 'Passwordless SSH authentication could not be confirmed yet.'
}

vm_should_attempt_ip_discovery() {
  local running_confidence="$1"
  local ssh_probe_state="$2"

  case "$ssh_probe_state" in
    invalid-target|unreachable)
      return 0
      ;;
  esac

  return 1
}

print_vm_ssh_probe_guidance() {
  local vm_state="$1"
  local running_confidence="$2"
  local ssh_probe_state="$3"
  local vm_ip_value=''

  case "$ssh_probe_state" in
    network-timeout)
      print_possible_causes \
        'VM is still booting' \
        'Networking is not ready yet'
      return 0
      ;;
    invalid-target)
      if [ "$running_confidence" = 'exact' ]; then
        warn 'VM is running, but the current VM address is invalid.'
      elif [ "$running_confidence" = 'generic' ]; then
        warn 'A virtualization process is running on this Mac, but the current VM address is invalid.'
      else
        warn 'The current VM address is invalid.'
      fi
      print_possible_causes \
        'The VM IP address is incorrect' \
        'The current VM address cannot be resolved'
      return 0
      ;;
    unreachable)
      if [ "$running_confidence" = 'exact' ]; then
        warn 'VM is running, but the current VM address is not reachable.'
      elif [ "$running_confidence" = 'generic' ]; then
        warn 'A virtualization process is running on this Mac, but the current VM address is not reachable.'
      elif [ "$vm_state" = 'stopped' ] && [ "${VM_GENERIC_VIRTUALIZATION_RUNNING:-false}" = true ]; then
        warn "Another virtualization process is running, but the selected VM \"${VM_MACHINE_NAME:-configured VM}\" is not confirmed running."
      else
        warn 'The current VM address is not reachable.'
      fi
      if [ "$vm_state" = 'stopped' ]; then
        print_possible_causes \
          'The selected VM is not running' \
          'VM networking is not ready yet' \
          'The VM IP address is incorrect or unroutable'
      else
        print_possible_causes \
          'VM networking is not ready yet' \
          'The VM IP address is incorrect or unroutable'
      fi
      return 0
      ;;
    ssh-refused)
      if [ "$running_confidence" = 'exact' ]; then
        warn 'VM is running, but SSH on port 22 is refusing connections.'
      else
        warn 'VM host responded, but SSH on port 22 is refusing connections.'
      fi
      print_possible_causes \
        'Remote Login is disabled' \
        'The SSH service is not started yet'
      return 0
      ;;
    ssh-timeout)
      if [ "$running_confidence" = 'exact' ] || [ "$vm_state" = 'booting' ]; then
        warn 'VM is booting or running, but SSH timed out.'
      else
        warn 'Timed out waiting for SSH access to the current VM address.'
      fi
      print_possible_causes \
        'VM is still booting' \
        'Networking is not ready yet'
      return 0
      ;;
    ssh-auth-required)
      print_ssh_auth_status
      return 0
      ;;
    ssh-hostkey-unknown)
      warn 'SSH has not trusted this VM host key yet.'
      out 'ClawBox can safely add a new host key without replacing an existing key.'
      blank_line
      return 0
      ;;
    ssh-hostkey-changed)
      warn 'SSH reports that the VM host key changed.'
      vm_ip_value="${VM_HOST##*@}"
      if [ -n "$vm_ip_value" ]; then
        out 'If this VM was recreated, remove the stale entry after reviewing the change:'
        out "ssh-keygen -R $vm_ip_value"
        blank_line
      fi
      return 0
      ;;
    ssh-hostkey-strict)
      warn 'SSH strict host key checking is blocking this connection.'
      out 'Review the host key policy in ~/.ssh/config, then connect interactively:'
      out "ssh $VM_HOST 'echo ok'"
      blank_line
      return 0
      ;;
    ssh-remote-command-failed)
      warn 'SSH key authentication may have succeeded, but the remote command failed.'
      print_possible_causes \
        'Remote shell startup/profile scripts returned a non-zero status' \
        'Required shell/runtime commands are missing on the VM'
      return 0
      ;;
    *)
      if [ "$running_confidence" = 'exact' ]; then
        warn 'VM is running but is not yet reachable via SSH.'
      elif [ "$running_confidence" = 'generic' ]; then
        warn 'A virtualization process is running on this Mac, but ClawBox could not confirm that it matches the configured VM.'
      else
        warn 'Unable to connect to VM via SSH.'
      fi
      print_possible_causes \
        'VM is still booting' \
        'Remote Login is disabled' \
        'Networking is not ready yet' \
        'SSH keys are not configured'
      return 0
      ;;
  esac
}

attempt_ssh_access_bootstrap() {
  status_begin 'Configuring SSH access...'

  if ! ensure_host_ssh_key; then
    status_end 'SSH access configuration did not complete.' 'warning'
    return 1
  fi

  status_tick 'Configuring SSH access...'
  if ! copy_ssh_key_to_vm; then
    status_end 'SSH access configuration did not complete.' 'warning'
    return 1
  fi

  status_tick 'Configuring SSH access...'
  if ssh_onboarding_check "echo ok" >/dev/null 2>&1; then
    status_end 'SSH access configured successfully.' 'success'
    return 0
  fi

  status_end 'SSH access configuration did not complete.' 'warning'
  return 1
}

wait_for_known_vm_ssh_readiness() {
  local probe_state=''

  if ! wait_for_vm_network; then
    probe_state="$REPLY"
    if [ "$probe_state" = 'ssh-timeout' ]; then
      REPLY='network-timeout'
    else
      REPLY="$probe_state"
    fi
    return 1
  fi

  probe_state="$REPLY"
  if wait_for_vm_ssh_service; then
    probe_state="$REPLY"
    if [ "$probe_state" = 'ready' ]; then
      return 0
    fi
  else
    probe_state="$REPLY"
  fi

  REPLY="$probe_state"
  return 1
}

wait_for_vm_ssh_after_network_ready() {
  local probe_state=''

  classify_vm_ssh_connectivity
  probe_state="$REPLY"

  case "$probe_state" in
    ready)
      return 0
      ;;
    ssh-auth-required|ssh-refused|invalid-target|unreachable|unknown|ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict|ssh-remote-command-failed)
      REPLY="$probe_state"
      return 1
      ;;
  esac

  if wait_for_vm_ssh_service; then
    probe_state="$REPLY"
    if [ "$probe_state" = 'ready' ]; then
      return 0
    fi
  else
    probe_state="$REPLY"
  fi

  REPLY="$probe_state"
  return 1
}

offer_started_vm_network_recovery() {
  local choice=''
  local attempts=0
  local max_attempts='2'
  local probe_state=''

  if [ -n "${CLAWBOX_VM_STARTUP_RECOVERY_MAX_ATTEMPTS:-}" ]; then
    max_attempts="$CLAWBOX_VM_STARTUP_RECOVERY_MAX_ATTEMPTS"
  fi

  while [ "$attempts" -lt "$max_attempts" ]; do
    blank_line
    out '1) Retry VM network detection'
    out '2) Enter a different IP address'
    out '3) Attempt VM IP discovery'
    out '4) Continue waiting'
    out '5) Abort setup'
    blank_line

    while true; do
      prompt_with_suffix 'Choose next step' '[1-5]'
      choice="$REPLY"

      if [ -z "$choice" ]; then
        choice='1'
      fi

      case "$choice" in
        1|2|3|4|5)
          break
          ;;
        *)
          error 'Invalid selection. Enter a number between 1 and 5.'
          ;;
      esac
    done

    case "$choice" in
      1)
        attempts=$((attempts + 1))
        if wait_for_vm_network; then
          probe_state="$REPLY"
          if [ "$probe_state" = 'ready' ]; then
            return 0
          fi

          if wait_for_vm_ssh_after_network_ready; then
            return 0
          fi

          probe_state="$REPLY"
        else
          probe_state="$REPLY"
          if [ "$probe_state" = 'ssh-timeout' ]; then
            probe_state='network-timeout'
          fi
        fi
        ;;
      2)
        attempts=$((attempts + 1))
        if ! prompt_for_vm_ip_replacement; then
          probe_state='network-timeout'
          continue
        fi

        if wait_for_vm_ssh_after_network_ready; then
          return 0
        fi

        probe_state="$REPLY"
        ;;
      3)
        attempts=$((attempts + 1))
        if ! offer_vm_ip_recovery; then
          continue
        fi

        if wait_for_vm_ssh_after_network_ready; then
          return 0
        fi

        probe_state="$REPLY"
        ;;
      4)
        attempts=$((attempts + 1))
        if wait_for_known_vm_ssh_readiness; then
          return 0
        fi

        probe_state="$REPLY"
        ;;
      5)
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
    esac

    if [ "$probe_state" != 'network-timeout' ]; then
      REPLY="$probe_state"
      return 1
    fi
  done

  REPLY='network-timeout'
  return 1
}

vm_startup_readiness_can_prompt() {
  [ -t 0 ]
}

offer_vm_startup_readiness_recovery() {
  local vm_state="${1:-booting}"
  local running_confidence="${2:-unknown}"
  local probe_state="${3:-network-timeout}"
  local choice=''
  local attempts=0
  local max_attempts="${CLAWBOX_VM_STARTUP_READINESS_MAX_ATTEMPTS:-3}"
  local selected_vm_running=false
  local discovery_confirmed=false

  print_vm_ssh_probe_guidance "$vm_state" "$running_confidence" "$probe_state"

  if ! vm_startup_readiness_can_prompt; then
    error 'VM did not become SSH-ready before the timeout.'
    print_utm_start_attempt_summary
    out 'Manual next step: start the selected VM in UTM, confirm Remote Login is enabled, then re-run setup.'
    REPLY="$probe_state"
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  while [ "$attempts" -lt "$max_attempts" ]; do
    if setup_selected_vm_is_running; then
      selected_vm_running=true
      vm_state='booting'
      running_confidence='exact'
    else
      selected_vm_running=false
      vm_state='stopped'
      running_confidence='unknown'
      refresh_generic_virtualization_context >/dev/null 2>&1 || true
    fi

    blank_line
    if [ "$selected_vm_running" = true ]; then
      out "The selected VM \"${VM_MACHINE_NAME:-configured VM}\" is running, but SSH is not ready yet."
    elif [ "${VM_GENERIC_VIRTUALIZATION_RUNNING:-false}" = true ]; then
      out "Another virtualization process is running, but the selected VM \"${VM_MACHINE_NAME:-configured VM}\" is not confirmed running."
    else
      out "The selected VM \"${VM_MACHINE_NAME:-configured VM}\" is not confirmed running."
    fi
    blank_line
    out '1) Try starting the selected VM again'
    out '2) I started the VM manually; check again'
    out '3) Discover VM addresses again'
    out '4) Enter the VM address manually'
    out '5) Show manual SSH guidance'
    out '6) Exit setup'
    blank_line

    while true; do
      prompt_with_suffix 'Choose next step' '[1-6]'
      choice="$REPLY"
      [ -n "$choice" ] || choice='2'

      case "$choice" in
        1|2|3|4|5|6)
          break
          ;;
        *)
          error 'Invalid selection. Enter a number between 1 and 6.'
          ;;
      esac
    done

    case "$choice" in
      1)
        attempts=$((attempts + 1))
        capture_vm_ip_discovery_baseline >/dev/null 2>&1 || true
        if ! start_vm_with_utm; then
          warn 'ClawBox could not start the selected VM automatically.'
          print_utm_start_attempt_summary
          probe_state='network-timeout'
          continue
        fi
        VM_RECENTLY_STARTED=true
        if ! wait_for_vm_running; then
          warn 'ClawBox started UTM but did not confirm that the selected VM is running.'
          print_utm_start_attempt_summary
          probe_state='network-timeout'
          continue
        fi
        if wait_for_known_vm_ssh_readiness; then
          return 0
        fi
        probe_state="$REPLY"
        print_vm_ssh_probe_guidance 'booting' 'exact' "$probe_state"
        ;;
      2)
        attempts=$((attempts + 1))
        if ! wait_for_manual_vm_running; then
          warn 'The selected VM is still not confirmed running.'
          probe_state='network-timeout'
          continue
        fi
        if wait_for_known_vm_ssh_readiness; then
          return 0
        fi
        probe_state="$REPLY"
        case "$probe_state" in
          ssh-refused|ssh-auth-required|ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict)
            REPLY="$probe_state"
            return 1
            ;;
        esac
        print_vm_ssh_probe_guidance 'booting' 'exact' "$probe_state"
        ;;
      3)
        attempts=$((attempts + 1))
        discovery_confirmed=false
        if setup_selected_vm_is_running; then
          discovery_confirmed=true
        else
          warn 'The selected VM is still not confirmed running.'
          out 'Address discovery may be incomplete until the selected VM is running.'
          prompt_yes_no 'Run VM address discovery anyway?' 'n'
          if is_yes "$REPLY"; then
            discovery_confirmed=true
          fi
        fi

        if [ "$discovery_confirmed" != true ]; then
          probe_state='network-timeout'
          continue
        fi

        if ! offer_vm_ip_recovery; then
          probe_state='network-timeout'
          continue
        fi

        if wait_for_vm_ssh_after_network_ready; then
          return 0
        fi
        probe_state="$REPLY"
        print_vm_ssh_probe_guidance 'running-no-ssh' 'exact' "$probe_state"
        ;;
      4)
        attempts=$((attempts + 1))
        if ! prompt_for_vm_ip_replacement; then
          probe_state='network-timeout'
          continue
        fi
        if wait_for_vm_ssh_after_network_ready; then
          return 0
        fi
        probe_state="$REPLY"
        print_vm_ssh_probe_guidance 'running-no-ssh' 'exact' "$probe_state"
        ;;
      5)
        print_manual_ssh_setup_instructions
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
      6)
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
    esac
  done

  REPLY="$probe_state"
  return 1
}

handle_ssh_refused_onboarding() {
  local vm_state="$1"
  local running_confidence="$2"
  local retry_attempt=1
  local max_retry_attempts=2
  local retry_state=''

  if [ "$running_confidence" = 'exact' ]; then
    warn 'VM is running, but SSH on port 22 is refusing connections.'
  else
    warn 'VM host responded, but SSH on port 22 is refusing connections.'
  fi

  out 'Remote Login may not yet be enabled inside the VM.'
  outf 'In the VM, enable: %b%s%b' "${COLOR_BOLD:-}" 'System Settings > Sharing > Remote Login' "${COLOR_RESET:-}"
  prompt_yes_no 'Is Remote Login now enabled?' 'y'

  if ! is_yes "$REPLY"; then
    print_manual_ssh_setup_instructions
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  while [ "$retry_attempt" -le "$max_retry_attempts" ]; do
    if wait_for_vm_ssh_service; then
      classify_vm_ssh_connectivity
      retry_state="$REPLY"
    else
      retry_state="$REPLY"
    fi

    case "$retry_state" in
      ready)
        return 0
        ;;
      ssh-auth-required|unknown|ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict)
        REPLY="$retry_state"
        return 1
        ;;
      ssh-refused)
        if [ "$retry_attempt" -lt "$max_retry_attempts" ]; then
          warn 'SSH is still refusing connections on port 22.'
          out 'Remote Login may still be starting inside the VM.'
          prompt_yes_no 'Retry after confirming Remote Login is enabled?' 'y'
          if ! is_yes "$REPLY"; then
            print_manual_ssh_setup_instructions
            return "$LLAMA_EXIT_GRACEFUL"
          fi

          retry_attempt=$((retry_attempt + 1))
          continue
        fi

        print_vm_ssh_probe_guidance "$vm_state" "$running_confidence" "$retry_state"
        out 'Verify Remote Login is enabled for the VM user, then re-run setup.'
        blank_line
        print_manual_ssh_setup_instructions
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
      *)
        print_vm_ssh_probe_guidance "$vm_state" "$running_confidence" "$retry_state"
        print_manual_ssh_setup_instructions
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
    esac
  done
}

handle_ssh_hostkey_onboarding() {
  local vm_state="$1"
  local running_confidence="$2"
  local hostkey_state="$3"
  local retry_attempt=1
  local max_retry_attempts="${CLAWBOX_SSH_HOSTKEY_RETRY_MAX_ATTEMPTS:-3}"

  while [ "$retry_attempt" -le "$max_retry_attempts" ]; do
    print_vm_ssh_probe_guidance "$vm_state" "$running_confidence" "$hostkey_state"

    if [ "$hostkey_state" = 'ssh-hostkey-unknown' ]; then
      prompt_yes_no 'Trust this VM host key now?' 'y'
    else
      prompt_yes_no 'Retry SSH after completing this step?' 'y'
    fi

    if ! is_yes "$REPLY"; then
      print_manual_ssh_setup_instructions
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    if [ "$hostkey_state" = 'ssh-hostkey-unknown' ]; then
      accept_new_vm_ssh_host_key || true
    fi

    classify_vm_ssh_connectivity
    hostkey_state="$REPLY"

    case "$hostkey_state" in
      ready)
        return 0
        ;;
      ssh-auth-required|unknown|ssh-refused)
        REPLY="$hostkey_state"
        return 1
        ;;
      ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict)
        retry_attempt=$((retry_attempt + 1))
        ;;
      *)
        REPLY="$hostkey_state"
        return 1
        ;;
    esac
  done

  warn 'SSH host key verification is still blocking setup.'
  print_manual_ssh_setup_instructions
  return "$LLAMA_EXIT_GRACEFUL"
}

confirm_manual_utm_start() {
  blank_line
  warn 'macOS is blocking automated control of UTM.'

  if [ "${UTM_PACKAGE_OPENED:-false}" = true ]; then
    out 'ClawBox opened the selected VM package in UTM.'
    out 'Opening the package can select the VM, but it cannot start the VM.'
  else
    out "Open UTM and select the VM: ${VM_MACHINE_NAME:-configured VM}"
  fi

  out 'Click the Run/Play button in UTM.'
  blank_line
  prompt_yes_no 'Once the VM is starting or running, continue?' 'y'
  is_yes "$REPLY"
}

verify_manual_utm_start() {
  local check_count=0
  local choice=''
  local max_checks="${CLAWBOX_MANUAL_VM_START_MAX_CHECKS:-3}"
  local menu_attempts=0
  local max_menu_attempts="${CLAWBOX_MANUAL_VM_START_MAX_MENU_ATTEMPTS:-6}"

  if ! confirm_manual_utm_start; then
    return 1
  fi

  while [ "$check_count" -lt "$max_checks" ]; do
    check_count=$((check_count + 1))
    if wait_for_manual_vm_running; then
      return 0
    fi

    warn 'The VM is still not running.'

    if [ "$check_count" -ge "$max_checks" ]; then
      out 'ClawBox reached the manual VM start check limit.'
      return 1
    fi

    blank_line
    out '1) I clicked Run/Play; check again'
    out '2) Open UTM again'
    out '3) Abort setup'
    blank_line

    menu_attempts=0
    while [ "$menu_attempts" -lt "$max_menu_attempts" ]; do
      menu_attempts=$((menu_attempts + 1))
      prompt_with_suffix 'Choose next step' '[1-3]'
      choice="$REPLY"
      [ -n "$choice" ] || choice='1'

      case "$choice" in
        1)
          break
          ;;
        2)
          open_utm_for_manual_start || true
          out 'Click the Run/Play button in UTM, then choose check again.'
          ;;
        3)
          return 1
          ;;
        *)
          error 'Invalid selection. Enter a number between 1 and 3.'
          ;;
      esac
    done

    if [ "$menu_attempts" -ge "$max_menu_attempts" ] && [ "$choice" != '1' ]; then
      error 'Manual VM start menu limit reached.'
      return 1
    fi
  done

  return 1
}

ensure_vm_connectivity_or_repair() {
  local configure_ssh_choice
  local recovery_status=0
  local running_confidence='unknown'
  local ssh_probe_state='unknown'
  local started_vm_this_run=false
  local vm_state
  local vm_runtime_detected_after_start=false
  local readiness_wait_attempted=false
  local manual_vm_start_verified=false

  VM_RECENTLY_STARTED=false
  reset_vm_onboarding_probe_state >/dev/null 2>&1 || true

  status_begin 'Checking VM state...'
  detect_vm_state
  vm_state="$REPLY"
  running_confidence="${VM_RUNNING_STATE_CONFIDENCE:-unknown}"
  status_end '' 'info'

  if [ "$vm_state" = 'ready' ]; then
    return 0
  fi

  if [ "$vm_state" = 'stopped' ]; then
    warn 'VM is not running.'
    if [ "${VM_GENERIC_VIRTUALIZATION_RUNNING:-false}" = true ]; then
      out "Another virtualization process is running, but the selected VM \"${VM_MACHINE_NAME:-configured VM}\" is not confirmed running."
    fi

    blank_line
    prompt_yes_no 'Start the VM now?' 'y'

    if is_yes "$REPLY"; then
      capture_vm_ip_discovery_baseline
      UTM_AUTOMATION_BLOCKED=false
      UTM_PACKAGE_OPENED=false
      if ! start_vm_with_utm; then
        recovery_status=0
        offer_vm_startup_readiness_recovery 'stopped' 'unknown' 'network-timeout'
        recovery_status=$?
        if [ "$recovery_status" -eq 0 ]; then
          VM_RECENTLY_STARTED=false
          success 'VM started and SSH is now available.'
          return 0
        fi
        if [ "$recovery_status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
          return "$LLAMA_EXIT_GRACEFUL"
        fi
        ssh_probe_state="$REPLY"
        return "$LLAMA_EXIT_GRACEFUL"
      fi

      started_vm_this_run=true
      VM_RECENTLY_STARTED=true

      if [ "$manual_vm_start_verified" != true ] && ! wait_for_vm_running; then
        detect_vm_state
        vm_state="$REPLY"
        if offer_vm_startup_readiness_recovery "$vm_state" "$running_confidence" 'network-timeout'; then
          VM_RECENTLY_STARTED=false
          success 'VM started and SSH is now available.'
          return 0
        fi
        recovery_status=$?
        if [ "$recovery_status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
          VM_RECENTLY_STARTED=false
          return "$LLAMA_EXIT_GRACEFUL"
        fi
        ssh_probe_state="$REPLY"
      fi

      vm_runtime_detected_after_start=true

      detect_vm_state
      vm_state="$REPLY"
      running_confidence="${VM_RUNNING_STATE_CONFIDENCE:-unknown}"

      if [ "$vm_state" = 'booting' ] || { [ "$vm_state" = 'running-no-ssh' ] && [ "$running_confidence" = 'exact' ]; }; then
        readiness_wait_attempted=true
        if wait_for_known_vm_ssh_readiness; then
          VM_RECENTLY_STARTED=false
          success 'VM started and SSH is now available.'
          return 0
        fi

        ssh_probe_state="$REPLY"

        if [ "$ssh_probe_state" = 'network-timeout' ] && [ "$started_vm_this_run" = true ] && [ "$vm_runtime_detected_after_start" = true ]; then
          recovery_status=0
          offer_vm_startup_readiness_recovery "$vm_state" "$running_confidence" "$ssh_probe_state"
          recovery_status=$?

          if [ "$recovery_status" -eq 0 ]; then
            VM_RECENTLY_STARTED=false
            success 'VM started and SSH is now available.'
            return 0
          fi

          if [ "$recovery_status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
            VM_RECENTLY_STARTED=false
            return "$LLAMA_EXIT_GRACEFUL"
          fi

          ssh_probe_state="$REPLY"
        fi

        VM_RECENTLY_STARTED=false
      fi

      if [ "$vm_state" = 'stopped' ]; then
        error 'ClawBox launched UTM but did not observe the VM enter a running state.'
        return "$LLAMA_EXIT_GRACEFUL"
      fi
    else
      return "$LLAMA_EXIT_GRACEFUL"
    fi
  fi

  if [ "$vm_state" = 'booting' ] && [ "$readiness_wait_attempted" != true ]; then
    if wait_for_known_vm_ssh_readiness; then
      VM_RECENTLY_STARTED=false
      success 'VM started and SSH is now available.'
      return 0
    fi

    ssh_probe_state="$REPLY"
    VM_RECENTLY_STARTED=false
  fi

  if [ "$vm_state" = 'running-no-ssh' ] && [ "$ssh_probe_state" = 'unknown' ]; then
    classify_vm_ssh_connectivity
    ssh_probe_state="$REPLY"
  fi

  if [ "$ssh_probe_state" = 'ssh-refused' ]; then
    recovery_status=0
    handle_ssh_refused_onboarding "$vm_state" "$running_confidence"
    recovery_status=$?

    if [ "$recovery_status" -eq 0 ]; then
      success 'VM SSH is now available.'
      return 0
    fi

    if [ "$recovery_status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    ssh_probe_state="$REPLY"
  fi

  case "$ssh_probe_state" in
    ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict)
      recovery_status=0
      handle_ssh_hostkey_onboarding "$vm_state" "$running_confidence" "$ssh_probe_state"
      recovery_status=$?

      if [ "$recovery_status" -eq 0 ]; then
        success 'VM SSH is now available.'
        return 0
      fi

      if [ "$recovery_status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
        return "$LLAMA_EXIT_GRACEFUL"
      fi

      ssh_probe_state="$REPLY"
      ;;
  esac

  if [ "$ssh_probe_state" = 'network-timeout' ]; then
    print_vm_ssh_probe_guidance "$vm_state" "$running_confidence" "$ssh_probe_state"
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$vm_state" = 'running-no-ssh' ]; then
    if ! vm_should_offer_ssh_bootstrap "$ssh_probe_state" "$running_confidence"; then
      print_vm_ssh_probe_guidance "$vm_state" "$running_confidence" "$ssh_probe_state"
    elif [ "$ssh_probe_state" = 'unknown' ] && [ "$running_confidence" = 'generic' ]; then
      print_vm_ssh_probe_guidance "$vm_state" "$running_confidence" "$ssh_probe_state"
    fi
  fi

  if [ "$vm_state" = 'stopped' ]; then
    error 'VM started but did not become ready.'
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$vm_state" != 'running-no-ssh' ] && [ "$ssh_probe_state" = 'unknown' ]; then
    classify_vm_ssh_connectivity
    ssh_probe_state="$REPLY"
  fi

  if [ "$vm_state" != 'running-no-ssh' ] && [ "$ssh_probe_state" != 'unknown' ]; then
    if ! vm_should_offer_ssh_bootstrap "$ssh_probe_state" "$running_confidence"; then
      print_vm_ssh_probe_guidance "$vm_state" "$running_confidence" "$ssh_probe_state"
    fi
  fi

  if vm_should_attempt_ip_discovery "$running_confidence" "$ssh_probe_state"; then
    if offer_vm_ip_recovery; then
      if wait_for_vm_ssh_after_network_ready; then
        success 'VM SSH is now available.'
        return 0
      fi

      ssh_probe_state="$REPLY"

      if ! vm_should_offer_ssh_bootstrap "$ssh_probe_state" 'exact'; then
        print_vm_ssh_probe_guidance 'running-no-ssh' 'exact' "$ssh_probe_state"
      fi
    else
      print_manual_ssh_setup_instructions
      return "$LLAMA_EXIT_GRACEFUL"
    fi
  fi

  if [ "$ssh_probe_state" = 'ssh-refused' ]; then
    recovery_status=0
    handle_ssh_refused_onboarding "$vm_state" "$running_confidence"
    recovery_status=$?

    if [ "$recovery_status" -eq 0 ]; then
      success 'VM SSH is now available.'
      return 0
    fi

    if [ "$recovery_status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    ssh_probe_state="$REPLY"
  fi

  case "$ssh_probe_state" in
    ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict)
      recovery_status=0
      handle_ssh_hostkey_onboarding "$vm_state" "$running_confidence" "$ssh_probe_state"
      recovery_status=$?

      if [ "$recovery_status" -eq 0 ]; then
        success 'VM SSH is now available.'
        return 0
      fi

      if [ "$recovery_status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
        return "$LLAMA_EXIT_GRACEFUL"
      fi

      ssh_probe_state="$REPLY"
      ;;
  esac

  if ! vm_should_offer_ssh_bootstrap "$ssh_probe_state" "$running_confidence"; then
    print_manual_ssh_setup_instructions
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$ssh_probe_state" = 'ready' ]; then
    success 'SSH key-based authentication is already configured.'
    return 0
  fi

  if [ "$ssh_probe_state" = 'ssh-auth-required' ]; then
    print_ssh_auth_status
  elif [ "$ssh_probe_state" = 'unknown' ] && [ "$running_confidence" != 'generic' ]; then
    print_possible_causes 'SSH keys are not configured'
  fi

  prompt_yes_no 'Attempt to configure SSH access automatically?' 'y'
  configure_ssh_choice="$REPLY"

  if is_yes "$configure_ssh_choice"; then
    if attempt_ssh_access_bootstrap; then
      return 0
    fi

    error 'Automatic SSH setup failed.'
    print_manual_ssh_setup_instructions
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  print_manual_ssh_setup_instructions
  return "$LLAMA_EXIT_GRACEFUL"
}
