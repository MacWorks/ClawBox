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

  section "Network + VM Configuration"
  parse_vm_ip_from_host "${VM_HOST:-}"
  vm_host_ip_default="$REPLY"
  configured_or_default 'VM_IP' "${VM_IP:-}" "$vm_host_ip_default"
  configured_or_default 'VM_IP' "$REPLY" '192.168.64.2'
  vm_ip_default="$REPLY"
  parse_vm_user_from_host "${VM_HOST:-}"
  configured_or_default 'VM_USER' "${VM_USER:-}" "$REPLY"
  vm_user_default="$REPLY"
  prompt_with_default 'Enter VM IP address' "$vm_ip_default"
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
