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

utm_start_output_indicates_failure() {
  local output="$1"

  printf '%s\n' "$output" | grep -Eqi '(^|[[:space:]])Error:|Virtual machine not found|No registered UTM virtual machine|Not authorized to send Apple events|command timed out'
}

utm_normalize_command_status() {
  local command_status="$1"
  local output="${2:-}"

  if [ "$command_status" -eq 0 ] && utm_start_output_indicates_failure "$output"; then
    printf '%s\n' '1'
    return 0
  fi

  printf '%s\n' "$command_status"
}

utm_concise_output_summary() {
  local output="$1"

  output="${output//$'\r'/}"
  output="$(printf '%s\n' "$output" | sed -e '/^[[:space:]]*$/d' | head -5)"
  if [ -z "$output" ]; then
    printf '%s\n' '(no output)'
  else
    printf '%s\n' "$output"
  fi
}

reset_utm_start_attempt_result() {
  UTM_START_ATTEMPT_METHODS=''
  UTM_START_LAST_METHOD=''
  UTM_START_LAST_STATUS=''
  UTM_START_LAST_OUTPUT=''
  UTM_START_VM_NAME=''
  UTM_START_VM_PATH=''
}

record_utm_start_attempt_result() {
  local method="$1"
  local command_status="$2"
  local output="${3:-}"

  if [ -n "${UTM_START_ATTEMPT_METHODS:-}" ]; then
    UTM_START_ATTEMPT_METHODS="${UTM_START_ATTEMPT_METHODS}, $method(status=$command_status)"
  else
    UTM_START_ATTEMPT_METHODS="$method(status=$command_status)"
  fi

  UTM_START_LAST_METHOD="$method"
  UTM_START_LAST_STATUS="$command_status"
  UTM_START_LAST_OUTPUT="$(utm_concise_output_summary "$output")"
  UTM_START_VM_NAME="${VM_MACHINE_NAME:-}"
  UTM_START_VM_PATH="${VM_UTM_PATH:-}"
}

print_utm_start_attempt_summary() {
  out "Selected VM: ${UTM_START_VM_NAME:-${VM_MACHINE_NAME:-unknown}}"
  if [ -n "${UTM_START_VM_PATH:-${VM_UTM_PATH:-}}" ]; then
    out "Selected VM path: ${UTM_START_VM_PATH:-$VM_UTM_PATH}"
  fi
  if [ -n "${UTM_START_ATTEMPT_METHODS:-}" ]; then
    out "Startup methods attempted: $UTM_START_ATTEMPT_METHODS"
  fi
  if [ -n "${UTM_START_LAST_METHOD:-}" ]; then
    out "Last startup method: $UTM_START_LAST_METHOD"
    out "Last startup exit status: ${UTM_START_LAST_STATUS:-unknown}"
    out 'Last startup output:'
    while IFS= read -r line; do
      out "  $line"
    done <<EOF
${UTM_START_LAST_OUTPUT:-'(no output)'}
EOF
  fi
}

print_utm_automation_guidance() {
  if [ "${UTM_AUTOMATION_GUIDANCE_SHOWN:-false}" = true ]; then
    return 0
  fi

  warn 'Automatic VM start is blocked by macOS Automation permissions.'
  out 'ClawBox cannot bypass this macOS security control.'
  out 'Open System Settings > Privacy & Security > Automation.'
  out 'The relevant Automation entry may not appear until macOS registers an Apple-event request.'
  out 'Open UTM normally, then run the AppleScript verification command below from the same terminal app.'
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

  list_output="$(run_vm_command_with_default_timeout "$utmctl_bin" list 2>&1)" || list_status=$?
  list_status="$(utm_normalize_command_status "$list_status" "$list_output")"
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
  if ! open_output="$(run_vm_command_with_default_timeout "$open_bin" -a UTM "$vm_path" 2>&1)"; then
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

  if ! open_output="$(run_vm_command_with_default_timeout "$open_bin" -a UTM 2>&1)"; then
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
    record_utm_start_attempt_result 'open-utm-package' 1 'UTM package path is unavailable or could not be opened.'
    return 1
  fi

  out 'UTM package opened for registration/selection; retrying VM start.'
  sleep 2

  if [ -z "$utmctl_bin" ]; then
    out 'The package was opened, but utmctl is unavailable to confirm startup.'
    record_utm_start_attempt_result 'open-utm-package' 1 'utmctl unavailable after opening package.'
    return 1
  fi

  retry_output="$(run_vm_command_with_default_timeout "$utmctl_bin" start "$vm_name" 2>&1)"
  local retry_status=$?
  retry_status="$(utm_normalize_command_status "$retry_status" "$retry_output")"
  if [ "$retry_status" -eq 0 ]; then
    record_utm_start_attempt_result 'utmctl-after-package-open' 0 "$retry_output"
    return 0
  fi
  record_utm_start_attempt_result 'utmctl-after-package-open' "$retry_status" "$retry_output"

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
  local command_status=0

  reset_utm_start_attempt_result
  UTM_AUTOMATION_BLOCKED=false
  UTM_AUTOMATION_GUIDANCE_SHOWN=false
  UTM_PACKAGE_OPENED=false

  normalize_vm_machine_name "${VM_MACHINE_NAME:-}"
  vm_name="$REPLY"

  if [ -z "$vm_name" ]; then
    error 'Cannot start UTM VM because VM_MACHINE_NAME is empty.'
    record_utm_start_attempt_result 'preflight' 1 'VM_MACHINE_NAME is empty.'
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
    utmctl_output="$(run_vm_command_with_default_timeout "$utmctl_bin" start "$vm_name" 2>&1)"
    command_status=$?
    command_status="$(utm_normalize_command_status "$command_status" "$utmctl_output")"
    if [ "$command_status" -eq 0 ]; then
      record_utm_start_attempt_result 'utmctl' 0 "$utmctl_output"
      status_end '' 'info'
      return 0
    fi

    record_utm_start_attempt_result 'utmctl' "$command_status" "$utmctl_output"
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

  osascript_output="$(run_vm_command_with_default_timeout "$osascript_bin" -e 'tell application "UTM" to activate' 2>&1)"
  command_status=$?
  command_status="$(utm_normalize_command_status "$command_status" "$osascript_output")"
  if [ "$command_status" -eq 0 ]; then
    :
  else
    record_utm_start_attempt_result 'applescript-activate' "$command_status" "$osascript_output"
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

  osascript_output="$(run_vm_command_with_default_timeout "$osascript_bin" \
    -e 'on run argv' \
    -e 'set vmIdentifier to item 1 of argv' \
    -e 'tell application "UTM"' \
    -e 'set matchingVMs to every virtual machine whose name is my vmIdentifier' \
    -e 'if (count of matchingVMs) is 0 then set matchingVMs to every virtual machine whose id is my vmIdentifier' \
    -e 'if (count of matchingVMs) is 0 then error "No registered UTM virtual machine matches identity: " & my vmIdentifier number -1728' \
    -e 'start item 1 of matchingVMs' \
    -e 'end tell' \
    -e 'end run' \
    "$vm_name" 2>&1)"
  command_status=$?
  command_status="$(utm_normalize_command_status "$command_status" "$osascript_output")"
  if [ "$command_status" -eq 0 ]; then
    :
  else
    record_utm_start_attempt_result 'applescript-start' "$command_status" "$osascript_output"
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

  record_utm_start_attempt_result 'applescript-start' 0 "$osascript_output"
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
    if setup_selected_vm_is_running; then
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
    if setup_selected_vm_is_running; then
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
