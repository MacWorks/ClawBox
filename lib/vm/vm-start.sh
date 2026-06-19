vm_onboarding_wait_interval() {
  if [ -n "${CLAWBOX_VM_WAIT_INTERVAL_SECONDS:-}" ]; then
    printf '%s\n' "$CLAWBOX_VM_WAIT_INTERVAL_SECONDS"
    return 0
  fi

  status_tick_interval
}

vm_runtime_wait_max_attempts() {
  printf '%s\n' "${CLAWBOX_VM_RUNTIME_WAIT_MAX_ATTEMPTS:-267}"
}

manual_vm_runtime_wait_max_attempts() {
  printf '%s\n' "${CLAWBOX_MANUAL_VM_RUNTIME_WAIT_MAX_ATTEMPTS:-20}"
}

vm_network_wait_max_attempts() {
  printf '%s\n' "${CLAWBOX_VM_NETWORK_WAIT_MAX_ATTEMPTS:-15}"
}

vm_network_wait_interval() {
  if [ -n "${CLAWBOX_VM_NETWORK_WAIT_INTERVAL_SECONDS:-}" ]; then
    printf '%s\n' "$CLAWBOX_VM_NETWORK_WAIT_INTERVAL_SECONDS"
    return 0
  fi

  # Network polling is intentionally slower than spinner redraws to reduce false negatives.
  printf '%s\n' '2'
}

vm_ssh_wait_max_attempts() {
  printf '%s\n' "${CLAWBOX_VM_SSH_WAIT_MAX_ATTEMPTS:-200}"
}

utm_output_indicates_automation_denial() {
  local output="$1"

  printf '%s\n' "$output" | grep -Eq '(^|[^0-9])-1743([^0-9]|$)'
}

print_utm_automation_guidance() {
  if [ "${UTM_AUTOMATION_GUIDANCE_SHOWN:-false}" = true ]; then
    return 0
  fi

  warn 'Automatic VM start is blocked by macOS Automation permissions.'
  out 'ClawBox cannot bypass this macOS security control.'
  out 'Open System Settings > Privacy & Security > Automation.'
  out 'Allow Terminal, iTerm, VS Code, osascript, or utmctl, if listed, to control UTM.'
  out 'Fully quit and reopen the terminal app after changing this permission.'
  out 'If automation still fails, log out of macOS and log back in.'
  blank_line
  out 'Verify AppleScript automation with:'
  out "/usr/bin/osascript -e 'tell application \"UTM\" to get name of every virtual machine'"
  out 'Verify utmctl automation with:'
  out '/Applications/UTM.app/Contents/MacOS/utmctl list'
  out 'Error -1743 means macOS is blocking automation.'
  blank_line
  out 'Otherwise, start the VM manually in UTM and continue setup.'

  UTM_AUTOMATION_GUIDANCE_SHOWN=true
}

print_utmctl_identity_diagnostics() {
  local utmctl_bin="$1"
  local requested_identity="$2"
  local list_output=''
  local list_status=0

  out "Requested UTM VM identity: $requested_identity"

  list_output="$("$utmctl_bin" list 2>&1)" || list_status=$?
  if utm_output_indicates_automation_denial "$list_output"; then
    UTM_AUTOMATION_BLOCKED=true
    warn 'macOS blocked utmctl automation for UTM.'
    out 'utmctl list output:'
    while IFS= read -r line; do
      out "  $line"
    done <<< "$list_output"
    print_utm_automation_guidance
    return 0
  fi

  if [ "$list_status" -eq 0 ] && [ -n "$list_output" ]; then
    out 'utmctl registered VMs for this macOS user:'
    while IFS= read -r line; do
      out "  $line"
    done <<< "$list_output"
    return 0
  fi

  out 'utmctl did not report any registered VMs for this macOS user.'
  if [ -n "$list_output" ]; then
    out "utmctl list: $list_output"
  fi
}

print_utm_applescript_failure() {
  local applescript_output="$1"

  if [ -n "$applescript_output" ]; then
    error "$applescript_output"
  fi

  if utm_output_indicates_automation_denial "$applescript_output"; then
    UTM_AUTOMATION_BLOCKED=true
    warn 'macOS blocked AppleScript automation for UTM.'
    print_utm_automation_guidance
    return 0
  fi

  out 'AppleScript failed for a non-Automation reason.'
  out 'Review the error above and the registered UTM VM identities.'
}

open_utm_vm_package() {
  local vm_path="${VM_UTM_PATH:-}"
  local open_bin="${CLAWBOX_OPEN_BIN:-}"
  local open_output=''

  if [ -z "$vm_path" ] || [ ! -d "$vm_path" ]; then
    return 1
  fi

  case "$vm_path" in
    *.utm) ;;
    *) return 1 ;;
  esac

  if [ -z "$open_bin" ]; then
    open_bin="$(command -v open 2>/dev/null || true)"
  fi
  if [ -z "$open_bin" ]; then
    return 1
  fi

  out "Attempting UTM package path: $vm_path"
  if ! open_output="$("$open_bin" -a UTM "$vm_path" 2>&1)"; then
    error "Could not open UTM package path: $vm_path"
    if [ -n "$open_output" ]; then
      error "$open_output"
    fi
    return 1
  fi

  UTM_PACKAGE_OPENED=true
  return 0
}

open_utm_for_manual_start() {
  local open_bin="${CLAWBOX_OPEN_BIN:-}"
  local open_output=''

  if open_utm_vm_package; then
    return 0
  fi

  if [ -z "$open_bin" ]; then
    open_bin="$(command -v open 2>/dev/null || true)"
  fi
  if [ -z "$open_bin" ]; then
    return 1
  fi

  if ! open_output="$("$open_bin" -a UTM 2>&1)"; then
    error 'Could not open UTM.'
    if [ -n "$open_output" ]; then
      error "$open_output"
    fi
    return 1
  fi

  return 0
}

start_vm_via_utm_package_path() {
  local vm_name="$1"
  local utmctl_bin="$2"
  local retry_output=''

  if ! open_utm_vm_package; then
    return 1
  fi

  out 'UTM package opened for registration/selection; retrying VM start.'
  sleep 2

  if [ -z "$utmctl_bin" ]; then
    out 'The package was opened, but utmctl is unavailable to confirm startup.'
    return 1
  fi

  if retry_output="$("$utmctl_bin" start "$vm_name" 2>&1)"; then
    return 0
  fi

  error "utmctl still could not start VM \"$vm_name\" after opening the package."
  if [ -n "$retry_output" ]; then
    out "utmctl: $retry_output"
  fi
  return 1
}

start_vm_with_utm() {
  local vm_name=''
  local utmctl_bin=''
  local utmctl_output=''
  local osascript_bin="${CLAWBOX_OSASCRIPT_BIN:-/usr/bin/osascript}"
  local osascript_output=''

  UTM_AUTOMATION_BLOCKED=false
  UTM_AUTOMATION_GUIDANCE_SHOWN=false
  UTM_PACKAGE_OPENED=false

  normalize_vm_machine_name "${VM_MACHINE_NAME:-}"
  vm_name="$REPLY"

  if [ -z "$vm_name" ]; then
    error 'Cannot start UTM VM because VM_MACHINE_NAME is empty.'
    return 1
  fi

  if [ -z "${VM_UTM_PATH:-}" ] \
    && declare -F resolve_detected_utm_vm_path >/dev/null 2>&1 \
    && resolve_detected_utm_vm_path "$vm_name"; then
    VM_UTM_PATH="$REPLY"
  fi

  status_begin 'Starting VM with UTM...'

  if resolve_utmctl_bin; then
    utmctl_bin="$REPLY"
  fi

  if [ -n "$utmctl_bin" ]; then
    if utmctl_output="$("$utmctl_bin" start "$vm_name" 2>&1)"; then
      status_end '' 'info'
      return 0
    fi

    status_end "utmctl could not start VM \"$vm_name\"; trying AppleScript." 'warning'
    if [ -n "$utmctl_output" ]; then
      out "utmctl: $utmctl_output"
      if utm_output_indicates_automation_denial "$utmctl_output"; then
        UTM_AUTOMATION_BLOCKED=true
      fi
      if printf '%s\n' "$utmctl_output" | grep -q 'Virtual machine not found'; then
        print_utmctl_identity_diagnostics "$utmctl_bin" "$vm_name"
      fi
    fi
    status_begin 'Starting VM with UTM via AppleScript...'
  fi

  if [ -z "$utmctl_bin" ] && [ "${UTMCTL_GUIDANCE_SHOWN:-false}" != true ]; then
    out 'utmctl provides more reliable VM control than AppleScript.'
    out 'It is included inside the UTM app bundle.'
    out 'Example path: /Applications/UTM.app/Contents/MacOS/utmctl'
    UTMCTL_GUIDANCE_SHOWN=true
  fi

  if ! osascript_output="$("$osascript_bin" -e 'tell application "UTM" to activate' 2>&1)"; then
    status_end "AppleScript could not activate UTM for VM \"$vm_name\"." 'error'
    print_utm_applescript_failure "$osascript_output"

    if [ "$UTM_AUTOMATION_BLOCKED" = true ]; then
      open_utm_vm_package || true
      return 1
    fi

    if start_vm_via_utm_package_path "$vm_name" "$utmctl_bin"; then
      return 0
    fi
    return 1
  fi

  sleep 2
  status_tick 'Starting VM with UTM via AppleScript...'

  if ! osascript_output="$("$osascript_bin" \
    -e 'on run argv' \
    -e 'set vmIdentifier to item 1 of argv' \
    -e 'tell application "UTM"' \
    -e 'set matchingVMs to every virtual machine whose name is my vmIdentifier' \
    -e 'if (count of matchingVMs) is 0 then set matchingVMs to every virtual machine whose id is my vmIdentifier' \
    -e 'if (count of matchingVMs) is 0 then error "No registered UTM virtual machine matches identity: " & my vmIdentifier number -1728' \
    -e 'start item 1 of matchingVMs' \
    -e 'end tell' \
    -e 'end run' \
    "$vm_name" 2>&1)"; then
    status_end "AppleScript could not start VM \"$vm_name\"." 'error'
    print_utm_applescript_failure "$osascript_output"

    if [ "$UTM_AUTOMATION_BLOCKED" = true ]; then
      open_utm_vm_package || true
      return 1
    fi

    if start_vm_via_utm_package_path "$vm_name" "$utmctl_bin"; then
      return 0
    fi
    return 1
  fi

  sleep 5
  status_end '' 'info'
  return 0
}

wait_for_vm_running() {
  local attempt=1
  local max_attempts=''
  local wait_interval=''

  max_attempts="$(vm_runtime_wait_max_attempts)"
  wait_interval="$(vm_onboarding_wait_interval)"

  status_begin 'Waiting for VM runtime...'

  while [ "$attempt" -le "$max_attempts" ]; do
    if setup_vm_is_running; then
      status_end 'VM runtime detected.' 'success'
      return 0
    fi

    attempt=$((attempt + 1))
    status_sleep "$wait_interval" 'Waiting for VM runtime...'
  done

  status_end 'VM runtime was not detected.' 'warning'
  return 1
}

wait_for_manual_vm_running() {
  local attempt=1
  local max_attempts=''
  local wait_interval=''

  max_attempts="$(manual_vm_runtime_wait_max_attempts)"
  wait_interval="$(vm_onboarding_wait_interval)"

  status_begin 'Checking for VM runtime...'

  while [ "$attempt" -le "$max_attempts" ]; do
    if setup_vm_is_running; then
      status_end 'VM runtime detected.' 'success'
      return 0
    fi

    attempt=$((attempt + 1))
    status_sleep "$wait_interval" 'Checking for VM runtime...'
  done

  status_end 'VM runtime was not detected.' 'warning'
  return 1
}

wait_for_vm_network() {
  local attempt=1
  local max_attempts=''
  local wait_interval=''
  local probe_state=''

  max_attempts="$(vm_network_wait_max_attempts)"
  wait_interval="$(vm_network_wait_interval)"

  status_begin 'Waiting for VM network...'

  while [ "$attempt" -le "$max_attempts" ]; do
    probe_vm_network_endpoint
    probe_state="$REPLY"

    case "$probe_state" in
      ready|ssh-auth-required|ssh-refused|unknown)
        REPLY="$probe_state"
        status_end 'VM network detected.' 'success'
        return 0
        ;;
      invalid-target)
        REPLY="$probe_state"
        status_end 'VM network detection stopped.' 'warning'
        return 1
        ;;
    esac

    attempt=$((attempt + 1))
    status_sleep "$wait_interval" 'Waiting for VM network...'
  done

  REPLY='ssh-timeout'
  status_end 'VM network was not detected within the expected time window.' 'warning'
  return 1
}

wait_for_vm_ssh_service() {
  local attempt=1
  local max_attempts=''
  local wait_interval=''
  local probe_state=''

  max_attempts="$(vm_ssh_wait_max_attempts)"
  wait_interval="$(vm_onboarding_wait_interval)"

  status_begin 'Waiting for SSH...'

  while [ "$attempt" -le "$max_attempts" ]; do
    probe_vm_ssh_endpoint
    probe_state="$REPLY"

    case "$probe_state" in
      ready|ssh-auth-required)
        REPLY="$probe_state"
        status_end 'SSH readiness detected.' 'success'
        return 0
        ;;
      ssh-refused|invalid-target|unreachable)
        REPLY="$probe_state"
        status_end 'SSH readiness check stopped.' 'warning'
        return 1
        ;;
    esac

    attempt=$((attempt + 1))
    status_sleep "$wait_interval" 'Waiting for SSH...'
  done

  REPLY='ssh-timeout'
  status_end 'SSH readiness was not detected.' 'warning'
  return 1
}
