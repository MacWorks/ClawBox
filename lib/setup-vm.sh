utm_vm_display_name_from_package() {
  local package_path="$1"
  local config_path="$package_path/config.plist"
  local display_name=''

  if [ ! -f "$config_path" ] || [ ! -x /usr/libexec/PlistBuddy ]; then
    return 1
  fi

  display_name="$(/usr/libexec/PlistBuddy -c 'Print :Information:Name' "$config_path" 2>/dev/null || true)"
  if [ -z "$display_name" ]; then
    return 1
  fi

  REPLY="$display_name"
  return 0
}

resolve_detected_utm_vm_path() {
  local vm_name="$1"
  local utm_documents_dir="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
  local utm_path=''
  local package_name=''
  local nullglob_was_enabled=false

  if [ ! -d "$utm_documents_dir" ]; then
    return 1
  fi

  if shopt -q nullglob; then
    nullglob_was_enabled=true
  fi
  shopt -s nullglob

  for utm_path in "$utm_documents_dir"/*.utm; do
    package_name="$(basename "$utm_path")"
    package_name="${package_name%.utm}"

    if utm_vm_display_name_from_package "$utm_path"; then
      if [ "$REPLY" = "$vm_name" ]; then
        REPLY="$utm_path"
        if [ "$nullglob_was_enabled" != true ]; then
          shopt -u nullglob
        fi
        return 0
      fi
    elif [ "$package_name" = "$vm_name" ]; then
      REPLY="$utm_path"
      if [ "$nullglob_was_enabled" != true ]; then
        shopt -u nullglob
      fi
      return 0
    fi
  done

  if [ "$nullglob_was_enabled" != true ]; then
    shopt -u nullglob
  fi
  return 1
}

select_utm_vm_identity() {
  local vm_name="$1"

  VM_UTM_PATH=''
  if resolve_detected_utm_vm_path "$vm_name"; then
    VM_UTM_PATH="$REPLY"
  fi

  REPLY="$vm_name"
}

list_detected_utm_vm_names() {
  local utm_documents_dir="$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
  local utm_path=''
  local utm_name=''
  local nullglob_was_enabled=false

  if [ ! -d "$utm_documents_dir" ]; then
    return 0
  fi

  if ! ls "$utm_documents_dir" >/dev/null 2>&1; then
    return 2
  fi

  if shopt -q nullglob; then
    nullglob_was_enabled=true
  fi
  shopt -s nullglob

  for utm_path in "$utm_documents_dir"/*.utm; do
    if utm_vm_display_name_from_package "$utm_path"; then
      printf '%s\n' "$REPLY"
      continue
    fi

    utm_name="$(basename "$utm_path")"
    printf '%s\n' "${utm_name%.utm}"
  done

  if [ "$nullglob_was_enabled" != true ]; then
    shopt -u nullglob
  fi
}

open_full_disk_access_settings() {
  command -v open >/dev/null 2>&1 || return 1
  open 'x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles' >/dev/null 2>&1
}

ensure_vm_platform_ready() {
  local is_apple_silicon=false
  local has_utm=false
  local has_utm_vms=false
  local detected_vm_names=()
  local detected_vm_name=''
  local detected_vm_output=''
  local detected_vm_status=0
  local privacy_choice=''
  local selected_index=''
  local next_step=1

  if [ "$(uname -m)" = 'arm64' ]; then
    is_apple_silicon=true
  fi

  if [ -d '/Applications/UTM.app' ]; then
    has_utm=true
  fi

  set +e
  detected_vm_output="$(list_detected_utm_vm_names)"
  detected_vm_status=$?
  set -e

  if [ "$detected_vm_status" -eq 2 ]; then
    section "VM Detection"
    out 'UTM access is blocked by macOS privacy settings.'
    blank_line
    out 'Guided VM detection requires:'
    out 'System Settings > Privacy & Security > Full Disk Access'
    menu_begin 'Options:'
    out '1) Grant Full Disk Access and re-run setup (recommended)'
    out '2) Continue with manual VM configuration'
    out '3) Exit'
    menu_end

    while true; do
      prompt_with_suffix 'Choose option' '[1-3]'
      privacy_choice="$REPLY"

      if [ -z "$privacy_choice" ]; then
        privacy_choice='1'
      fi

      case "$privacy_choice" in
        1)
          blank_line
          out 'ClawBox cannot continue with guided VM detection until macOS allows access to the UTM VM directory.'
          out 'Grant Full Disk Access to the app running setup (Terminal, iTerm, or Visual Studio Code).'
          out 'System Settings > Privacy & Security > Full Disk Access'
          blank_line
          out 'Attempting to open the Full Disk Access settings pane...'
          open_full_disk_access_settings || true
          blank_line
          out 'After granting Full Disk Access, re-run setup.'
          return "$LLAMA_EXIT_GRACEFUL"
          ;;
        2)
          VM_SKIP_DETECTED_UTM_FLOW=true
          return 0
          ;;
        3)
          return "$LLAMA_EXIT_GRACEFUL"
          ;;
        *)
          error 'Invalid selection. Enter a number between 1 and 3.'
          ;;
      esac
    done
  fi

  while IFS= read -r detected_vm_name; do
    if [ -n "$detected_vm_name" ]; then
      detected_vm_names+=("$detected_vm_name")
      has_utm_vms=true
    fi
  done <<EOF
$detected_vm_output
EOF

  if [ "$has_utm_vms" = true ]; then
    section "VM Detection"

    if [ "${#detected_vm_names[@]}" -eq 1 ]; then
      out 'Detected existing UTM VM:'
      blank_line
      out "- ${detected_vm_names[0]}"
      prompt_yes_no 'Use this VM?' 'y'

      if [ "$REPLY" = 'true' ]; then
        select_utm_vm_identity "${detected_vm_names[0]}"
        VM_MACHINE_NAME="$REPLY"
        return 0
      fi
    else
      menu_begin 'Detected UTM VMs:'

      next_step=1
      for detected_vm_name in "${detected_vm_names[@]}"; do
        outf '%s) %s' "$next_step" "$detected_vm_name"
        next_step=$((next_step + 1))
      done
      out '0) I want to create a new VM'
      menu_end

      while true; do
        prompt_with_suffix 'Choose VM' "[0-${#detected_vm_names[@]}]"
        selected_index="$REPLY"

        if [ -z "$selected_index" ]; then
          selected_index='1'
        fi

        if ! [[ "$selected_index" =~ ^[0-9]+$ ]]; then
          error "Invalid selection. Enter a number between 0 and ${#detected_vm_names[@]}."
          continue
        fi

        if [ "$selected_index" -eq 0 ]; then
          break
        fi

        if [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt "${#detected_vm_names[@]}" ]; then
          error "Invalid selection. Enter a number between 0 and ${#detected_vm_names[@]}."
          continue
        fi

        select_utm_vm_identity "${detected_vm_names[$((selected_index - 1))]}"
        VM_MACHINE_NAME="$REPLY"
        return 0
      done
    fi
  fi

  section "VM Platform Check"
  out 'ClawBox currently supports:'
  out "- Apple Silicon Host $( [ "$is_apple_silicon" = true ] && printf '✅' || printf '❌' )"
  out "- UTM virtualization $( [ "$has_utm" = true ] && printf '✅' || printf '❌' )"
  out "- macOS guest VMs $( [ "$has_utm_vms" = true ] && printf '✅' || printf '❌' )"

  if [ "$is_apple_silicon" = true ] && [ "$has_utm" = true ] && [ "$has_utm_vms" = true ]; then
    return 0
  fi

  menu_begin 'Next steps:'

  if [ "$is_apple_silicon" != true ]; then
    outf '%s) Use an Apple Silicon Mac host' "$next_step"
    next_step=$((next_step + 1))
  fi

  if [ "$has_utm" != true ]; then
    outf '%s) Install UTM' "$next_step"
    next_step=$((next_step + 1))
    outf '%s) Create a macOS VM in UTM' "$next_step"
    next_step=$((next_step + 1))
    outf '%s) Enable SSH inside the VM (Settings > General > Sharing > Remote Login)' "$next_step"
    next_step=$((next_step + 1))
    outf '%s) Continue or re-run setup' "$next_step"
    menu_end
    out 'Helpful link:'
    out 'https://mac.getutm.app/'
  elif [ "$has_utm_vms" != true ]; then
    outf '%s) Create a macOS VM in UTM' "$next_step"
    next_step=$((next_step + 1))
    outf '%s) Enable SSH inside the VM (Settings > General > Sharing > Remote Login)' "$next_step"
    next_step=$((next_step + 1))
    outf '%s) Continue or re-run setup' "$next_step"
    menu_end
  else
    menu_end
  fi

  prompt_yes_no 'Have you completed the above steps?' 'n'
  if [ "$REPLY" = 'true' ]; then
    return 0
  fi

  return "$LLAMA_EXIT_GRACEFUL"
}

offer_selected_vm_start_recovery_before_network_setup() {
  local choice=''
  local attempts=0
  local max_attempts="${CLAWBOX_SELECTED_VM_START_RECOVERY_MAX_ATTEMPTS:-3}"

  while [ "$attempts" -lt "$max_attempts" ]; do
    blank_line
    out "The selected VM \"${VM_MACHINE_NAME:-configured VM}\" did not enter a running state."
    print_selected_vm_start_attempt_summary
    blank_line
    out '1) Try starting the selected VM again'
    out '2) I started the VM manually; check again'
    out '3) Abort setup'
    blank_line

    while true; do
      prompt_with_suffix 'Choose next step' '[1-3]'
      choice="$REPLY"
      [ -n "$choice" ] || choice='1'

      case "$choice" in
        1|2|3)
          break
          ;;
        *)
          error 'Invalid selection. Enter a number between 1 and 3.'
          ;;
      esac
    done

    case "$choice" in
      1)
        attempts=$((attempts + 1))
        if start_selected_vm_for_setup; then
          return 0
        fi
        ;;
      2)
        attempts=$((attempts + 1))
        if wait_for_manual_vm_running; then
          return 0
        fi
        ;;
      3)
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
    esac
  done

  warn "The selected VM \"${VM_MACHINE_NAME:-configured VM}\" still is not confirmed running."
  return "$LLAMA_EXIT_GRACEFUL"
}

start_selected_vm_for_setup() {
  if command -v launchagent_start_selected_vm_for_setup >/dev/null 2>&1; then
    launchagent_start_selected_vm_for_setup
    return $?
  fi

  start_vm_with_utm && wait_for_vm_running
}

print_selected_vm_start_attempt_summary() {
  if command -v launchagent_print_start_attempt_summary >/dev/null 2>&1; then
    launchagent_print_start_attempt_summary
    return 0
  fi

  print_utm_start_attempt_summary
}

ensure_selected_vm_started_before_network_setup() {
  local selected_runtime_state='unknown'

  [ -n "${VM_MACHINE_NAME:-}" ] || return 0

  if command -v launchagent_start_selected_vm_for_setup >/dev/null 2>&1; then
    out "Starting selected VM: ${VM_MACHINE_NAME:-configured VM}"
    if start_selected_vm_for_setup; then
      return 0
    fi

    warn 'ClawBox could not confirm that the selected VM started.'
    offer_selected_vm_start_recovery_before_network_setup
    return $?
  fi

  if setup_selected_vm_runtime_state; then
    selected_runtime_state="$REPLY"
  fi

  if [ "$selected_runtime_state" = 'running' ]; then
    return 0
  fi

  out "Starting selected VM: ${VM_MACHINE_NAME:-configured VM}"
  if start_selected_vm_for_setup; then
    return 0
  fi

  warn 'ClawBox could not confirm that the selected VM started.'
  offer_selected_vm_start_recovery_before_network_setup
}

resolve_vm_machine_name_value() {
  local current_value="$1"
  local fallback_value="$2"
  local detected_vm_names=()
  local detected_vm_name=''
  local selected_index=''
  local option_number=1
  local prompt_status=0

  if [ "${VM_SKIP_DETECTED_UTM_FLOW:-false}" = true ]; then
    prompt_resolved_value 'Enter VM name' 'VM_MACHINE_NAME' "$current_value" "$fallback_value" || prompt_status=$?
    if [ "$prompt_status" -ne 0 ]; then
      return "$prompt_status"
    fi
    select_utm_vm_identity "$REPLY"
    return 0
  fi

  while IFS= read -r detected_vm_name; do
    if [ -n "$detected_vm_name" ]; then
      detected_vm_names+=("$detected_vm_name")
    fi
  done < <(list_detected_utm_vm_names)

  if [ -n "$current_value" ]; then
    for detected_vm_name in "${detected_vm_names[@]}"; do
      if [ "$current_value" = "$detected_vm_name" ]; then
        select_utm_vm_identity "$current_value"
        return 0
      fi
    done
  fi

  if [ "${#detected_vm_names[@]}" -eq 0 ]; then
    prompt_resolved_value 'Enter VM name' 'VM_MACHINE_NAME' "$current_value" "$fallback_value" || prompt_status=$?
    if [ "$prompt_status" -ne 0 ]; then
      return "$prompt_status"
    fi
    select_utm_vm_identity "$REPLY"
    return 0
  fi

  if [ "${#detected_vm_names[@]}" -eq 1 ]; then
    prompt_yes_no "Use detected UTM VM \"${detected_vm_names[0]}\"?" 'y'
    if [ "$REPLY" = 'true' ]; then
      select_utm_vm_identity "${detected_vm_names[0]}"
      return 0
    fi

    prompt_resolved_value 'Enter VM name' 'VM_MACHINE_NAME' "$current_value" "$fallback_value" || prompt_status=$?
    if [ "$prompt_status" -ne 0 ]; then
      return "$prompt_status"
    fi
    select_utm_vm_identity "$REPLY"
    return 0
  fi

  menu_begin 'Detected UTM VMs:'
  for detected_vm_name in "${detected_vm_names[@]}"; do
    outf '  %s) %s' "$option_number" "$detected_vm_name"
    option_number=$((option_number + 1))
  done
  menu_end

  while true; do
    prompt_with_suffix 'Choose detected UTM VM' "[1-${#detected_vm_names[@]}]"
    selected_index="$REPLY"

    if [ -z "$selected_index" ]; then
      selected_index='1'
    fi

    if ! [[ "$selected_index" =~ ^[0-9]+$ ]]; then
      error "Invalid selection. Enter a number between 1 and ${#detected_vm_names[@]}."
      continue
    fi

    if [ "$selected_index" -lt 1 ] || [ "$selected_index" -gt "${#detected_vm_names[@]}" ]; then
      error "Invalid selection. Enter a number between 1 and ${#detected_vm_names[@]}."
      continue
    fi

    select_utm_vm_identity "${detected_vm_names[$((selected_index - 1))]}"
    return 0
  done
}

count_vm_ip_candidates() {
  local candidates="$1"
  local candidate_ip=''
  local count=0

  while IFS= read -r candidate_ip; do
    [ -n "$candidate_ip" ] || continue
    count=$((count + 1))
  done <<EOF
$candidates
EOF

  printf '%s\n' "$count"
}

choose_discovered_vm_ip_candidate() {
  local candidates="$1"
  local candidate_count=''
  local candidate_ip=''
  local option_number=1
  local manual_option_number=0
  local selected_option=''

  candidate_count="$(count_vm_ip_candidates "$candidates")"

  if [ "$candidate_count" -eq 1 ]; then
    candidate_ip="$candidates"
    if [ "${VM_IP_DISCOVERY_CONFIDENCE:-}" = 'selected-vm' ]; then
      status_end "Detected VM IP: $candidate_ip ✓" 'progress'
      REPLY="$candidate_ip"
      return 0
    fi
  fi

  status_end 'VM IP discovery completed.' 'success'
  menu_begin 'Detected possible VM IP addresses:'

  while IFS= read -r candidate_ip; do
    [ -n "$candidate_ip" ] || continue
    outf '%s) %s' "$option_number" "$candidate_ip"
    option_number=$((option_number + 1))
  done <<EOF
$candidates
EOF

  manual_option_number="$option_number"
  outf '%s) Enter an IP address manually' "$manual_option_number"
  menu_end

  while true; do
    prompt_with_suffix 'Select VM IP' "[1]"
    selected_option="$REPLY"
    [ -n "$selected_option" ] || selected_option='1'

    if ! [[ "$selected_option" =~ ^[0-9]+$ ]]; then
      error "Invalid selection. Enter a number between 1 and $manual_option_number."
      continue
    fi

    if [ "$selected_option" -lt 1 ] || [ "$selected_option" -gt "$manual_option_number" ]; then
      error "Invalid selection. Enter a number between 1 and $manual_option_number."
      continue
    fi

    break
  done

  if [ "$selected_option" -eq "$manual_option_number" ]; then
    REPLY=''
    return 1
  fi

  option_number=1
  while IFS= read -r candidate_ip; do
    [ -n "$candidate_ip" ] || continue
    if [ "$option_number" -eq "$selected_option" ]; then
      REPLY="$candidate_ip"
      return 0
    fi
    option_number=$((option_number + 1))
  done <<EOF
$candidates
EOF

  return 1
}

discover_vm_ip_candidates_with_active_status() {
  local reply_file=''
  local confidence_file=''
  local pid=''
  local status=0

  reply_file="$(mktemp "${TMPDIR:-/tmp}/clawbox-vm-ip-candidates.XXXXXX")" || return 1
  confidence_file="$(mktemp "${TMPDIR:-/tmp}/clawbox-vm-ip-confidence.XXXXXX")" || {
    rm -f "$reply_file"
    return 1
  }

  (
    if discover_vm_ip_candidates; then
      printf '%s\n' "$REPLY" > "$reply_file"
      printf '%s\n' "${VM_IP_DISCOVERY_CONFIDENCE:-}" > "$confidence_file"
      exit 0
    else
      exit "$?"
    fi
  ) >/dev/null 2>&1 &
  pid="$!"

  if status_wait_for_pid_active "$pid" "${CLAWBOX_STATUS_MESSAGE:-Discovering VM IP address...}"; then
    status=0
  else
    status=$?
  fi

  REPLY=''
  if [ -s "$reply_file" ]; then
    REPLY="$(cat "$reply_file")"
  fi
  if [ -s "$confidence_file" ]; then
    IFS= read -r VM_IP_DISCOVERY_CONFIDENCE < "$confidence_file" || VM_IP_DISCOVERY_CONFIDENCE=''
  fi

  rm -f "$reply_file" "$confidence_file"
  return "$status"
}

probe_ssh_target_endpoint_with_active_status() {
  local target="$1"
  local reply_file=''
  local pid=''
  local status=0

  reply_file="$(mktemp "${TMPDIR:-/tmp}/clawbox-vm-ip-probe.XXXXXX")" || return 1

  (
    probe_ssh_target_endpoint "$target" || true
    printf '%s\n' "$REPLY" > "$reply_file"
  ) >/dev/null 2>&1 &
  pid="$!"

  if status_wait_for_pid_active "$pid" "${CLAWBOX_STATUS_MESSAGE:-Discovering VM IP address...}"; then
    status=0
  else
    status=$?
  fi

  REPLY=''
  if [ -s "$reply_file" ]; then
    IFS= read -r REPLY < "$reply_file" || REPLY=''
  fi

  rm -f "$reply_file"
  return "$status"
}

discover_vm_ip_before_manual_prompt() {
  local vm_ip_default="$1"
  local discovered_candidates=''
  local saved_vm_ip="${VM_IP:-}"
  local saved_vm_user="${VM_USER:-}"
  local configured_probe_state=''
  local attempts=1
  local max_attempts=''
  local interval=''
  local configured_attempts=1
  local configured_max_attempts=''
  local configured_interval=''

  if ! command -v discover_vm_ip_candidates >/dev/null 2>&1; then
    prompt_with_default 'Enter VM IP address' "$vm_ip_default"
    return 0
  fi

  max_attempts="${CLAWBOX_FRESH_VM_IP_DISCOVERY_ATTEMPTS:-8}"
  interval="${CLAWBOX_FRESH_VM_IP_DISCOVERY_INTERVAL:-2}"
  configured_max_attempts="${CLAWBOX_CONFIGURED_VM_IP_VALIDATION_ATTEMPTS:-4}"
  configured_interval="${CLAWBOX_CONFIGURED_VM_IP_VALIDATION_INTERVAL:-1}"

  status_begin 'Discovering VM IP address...'

  if [ -n "$saved_vm_ip" ] && [ -n "$saved_vm_user" ] && vm_ip_is_ipv4 "$saved_vm_ip"; then
    while [ "$configured_attempts" -le "$configured_max_attempts" ]; do
      probe_ssh_target_endpoint_with_active_status "${saved_vm_user}@${saved_vm_ip}"
      configured_probe_state="$REPLY"

      if vm_network_state_is_reachable "$configured_probe_state"; then
        status_end "Detected VM IP: $saved_vm_ip ✓" 'progress'
        VM_IP="$saved_vm_ip"
        VM_USER="$saved_vm_user"
        REPLY="$saved_vm_ip"
        return 0
      fi

      if [ "$configured_attempts" -lt "$configured_max_attempts" ]; then
        if [ -n "${CLAWBOX_SLEEP_BIN:-}" ]; then
          "$CLAWBOX_SLEEP_BIN" "$configured_interval"
        else
          status_sleep "$configured_interval"
        fi
      fi

      configured_attempts=$((configured_attempts + 1))
    done
  fi

  VM_IP="$vm_ip_default"
  if [ -z "${VM_USER:-}" ]; then
    VM_USER='clawbox'
  fi

  while [ "$attempts" -le "$max_attempts" ]; do
    if discover_vm_ip_candidates_with_active_status; then
      discovered_candidates="$REPLY"
      VM_IP="$saved_vm_ip"
      VM_USER="$saved_vm_user"
      if choose_discovered_vm_ip_candidate "$discovered_candidates"; then
        return 0
      fi
      prompt_with_default 'Enter VM IP address' "$vm_ip_default"
      return 0
    fi

    if [ "$attempts" -lt "$max_attempts" ]; then
      if [ -n "${CLAWBOX_SLEEP_BIN:-}" ]; then
        "$CLAWBOX_SLEEP_BIN" "$interval"
      else
        status_sleep "$interval"
      fi
    fi

    attempts=$((attempts + 1))
  done

  VM_IP="$saved_vm_ip"
  VM_USER="$saved_vm_user"

  status_end 'ClawBox could not automatically determine the VM IP address.' 'warning'
  prompt_with_default 'Enter VM IP address' "$vm_ip_default"
  return 0
}

ensure_vm_connection_setup() {
  local vm_ip_default
  local vm_host_ip_default
  local vm_user_default
  local vm_user_path_default
  local vm_ip_value
  local vm_user_value
  local vm_user_path_value
  local vm_machine_name_value

  ensure_vm_platform_ready || return $?
  ensure_selected_vm_started_before_network_setup || return $?

  section "Network + VM Configuration"
  parse_vm_ip_from_host "${VM_HOST:-}"
  vm_host_ip_default="$REPLY"
  configured_or_default 'VM_IP' "${VM_IP:-}" "$vm_host_ip_default"
  configured_or_default 'VM_IP' "$REPLY" '192.168.64.2'
  vm_ip_default="$REPLY"
  parse_vm_user_from_host "${VM_HOST:-}"
  configured_or_default 'VM_USER' "${VM_USER:-}" "$REPLY"
  vm_user_default="$REPLY"
  discover_vm_ip_before_manual_prompt "$vm_ip_default"
  vm_ip_value="$REPLY"
  prompt_with_default 'Enter VM username (lowercase)' "$vm_user_default"
  vm_user_value="$REPLY"

  vm_user_path_default="/Users/$vm_user_value"
  prompt_with_default 'Enter VM home directory path' "$vm_user_path_default"
  vm_user_path_value="$REPLY"
  if ! resolve_vm_machine_name_value "${VM_MACHINE_NAME:-}" "$(get_example_value 'VM_MACHINE_NAME')"; then
    error 'VM settings could not be saved.'
    return 1
  fi
  vm_machine_name_value="$REPLY"

  VM_IP="$vm_ip_value"
  VM_USER="$vm_user_value"
  VM_USER_PATH="$vm_user_path_value"
  VM_HOST="${vm_user_value}@${vm_ip_value}"
  derive_runtime_path "$vm_user_path_value"
  VM_RUNTIME_PATH="$REPLY"
  VM_MACHINE_NAME="$vm_machine_name_value"

  write_env_from_template
  if ! source_env_file; then
    error 'VM settings could not be saved.'
    return 1
  fi

  out 'VM settings saved.'
}
