#!/bin/bash
set +e

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

VM_NAME="$1"
VM_HOST="$2"
max_attempts="${CLAWBOX_VM_AUTOSTART_MAX_ATTEMPTS:-10}"
start_request_attempts="${CLAWBOX_VM_AUTOSTART_START_ATTEMPTS:-3}"
attempt=1

log_info() {
  printf '[INFO] %s\n' "$1"
}

log_warn() {
  printf '[WARN] %s\n' "$1"
}

log_error() {
  printf '[ERROR] %s\n' "$1" >&2
}

command_path() {
  local override="$1"
  local fallback_name="$2"
  local fallback_path="$3"

  if [ -n "$override" ]; then
    printf '%s\n' "$override"
    return 0
  fi

  if command -v "$fallback_name" >/dev/null 2>&1; then
    command -v "$fallback_name"
    return 0
  fi

  if [ -n "$fallback_path" ] && [ -x "$fallback_path" ]; then
    printf '%s\n' "$fallback_path"
    return 0
  fi

  return 1
}

utmctl_bin() {
  command_path "${CLAWBOX_UTMCTL_BIN:-}" 'utmctl' '/Applications/UTM.app/Contents/MacOS/utmctl'
}

osascript_bin() {
  command_path "${CLAWBOX_OSASCRIPT_BIN:-}" 'osascript' '/usr/bin/osascript'
}

ssh_bin() {
  command_path "${CLAWBOX_SSH_BIN:-}" 'ssh' '/usr/bin/ssh'
}

sleep_cmd() {
  if [ -n "${CLAWBOX_SLEEP_BIN:-}" ]; then
    "$CLAWBOX_SLEEP_BIN" "$@"
    return $?
  fi

  sleep "$@"
}

output_indicates_automation_denial() {
  printf '%s\n' "$1" | grep -Eq '(^|[^0-9])-1743([^0-9]|$)'
}

log_automation_guidance() {
  local sender="$1"

  log_warn "macOS blocked $sender automation for UTM."
  log_warn 'Automatic VM start requires macOS Automation permission; ClawBox cannot bypass it.'
  log_warn 'Open System Settings > Privacy & Security > Automation.'
  log_warn 'Allow bash, Terminal/iTerm/VS Code, osascript, or utmctl, if listed, to control UTM.'
  log_warn 'Fully quit and reopen the terminal app, or log out/in, after changing Automation permission.'
  log_warn 'Verification: /usr/bin/osascript -e '\''tell application "UTM" to get name of every virtual machine'\'''
  log_warn 'Verification: /Applications/UTM.app/Contents/MacOS/utmctl list'
  log_warn 'Error -1743 means macOS is blocking automation.'
}

vm_is_running_via_utmctl() {
  local line
  local list_output
  local bin

  bin="$(utmctl_bin)" || return 1

  list_output="$("$bin" list 2>&1)" || {
    if output_indicates_automation_denial "$list_output"; then
      log_automation_guidance 'utmctl'
    fi
    return 1
  }

  while IFS= read -r line; do
    case "$line" in
      *"$VM_NAME"*)
        case "$line" in
          *running*|*started*)
            return 0
            ;;
        esac
        ;;
    esac
  done <<EOF
$list_output
EOF

  return 1
}

vm_is_reachable_via_ssh() {
  local bin

  [ -n "$VM_HOST" ] || return 1
  bin="$(ssh_bin)" || return 1

  "$bin" \
    -o BatchMode=yes \
    -o ConnectTimeout=2 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$VM_HOST" exit >/dev/null 2>&1
}

vm_is_running() {
  if vm_is_running_via_utmctl; then
    return 0
  fi

  if vm_is_reachable_via_ssh; then
    return 0
  fi

  return 1
}

start_with_utmctl() {
  local output
  local bin

  bin="$(utmctl_bin)" || return 1

  log_info "Attempting to start VM with utmctl: $VM_NAME"
  output="$("$bin" start "$VM_NAME" 2>&1)" && {
    log_info "utmctl start requested successfully for VM: $VM_NAME"
    return 0
  }

  log_warn "utmctl could not start VM: $VM_NAME"
  if [ -n "$output" ]; then
    log_warn "utmctl output: $output"
  fi

  if output_indicates_automation_denial "$output"; then
    log_automation_guidance 'utmctl'
  fi

  return 1
}

start_with_applescript() {
  local output
  local bin

  bin="$(osascript_bin)" || return 1

  log_info "Attempting to start VM with AppleScript: $VM_NAME"
  output="$("$bin" \
    -e 'on run argv' \
    -e 'set vmIdentifier to item 1 of argv' \
    -e 'tell application "UTM"' \
    -e 'activate' \
    -e 'set matchingVMs to every virtual machine whose name is my vmIdentifier' \
    -e 'if (count of matchingVMs) is 0 then set matchingVMs to every virtual machine whose id is my vmIdentifier' \
    -e 'if (count of matchingVMs) is 0 then error "No registered UTM virtual machine matches identity: " & my vmIdentifier number -1728' \
    -e 'start item 1 of matchingVMs' \
    -e 'end tell' \
    -e 'end run' \
    "$VM_NAME" 2>&1)" && {
    log_info "AppleScript start requested successfully for VM: $VM_NAME"
    return 0
  }

  log_error "Failed to request VM start via AppleScript: $VM_NAME"
  if [ -n "$output" ]; then
    log_error "AppleScript output: $output"
  fi

  if output_indicates_automation_denial "$output"; then
    log_automation_guidance 'AppleScript'
  fi

  return 1
}

request_vm_start() {
  start_with_utmctl && return 0
  start_with_applescript && return 0
  return 1
}

if [ -z "$VM_NAME" ]; then
  log_warn 'VM name not provided; skipping UTM start.'
  exit 0
fi

log_info "ClawBox VM auto-start wrapper launched for VM: $VM_NAME"
log_info "Configured VM SSH target: ${VM_HOST:-not configured}"

if vm_is_running; then
  if vm_is_reachable_via_ssh; then
    log_info "VM already reachable via SSH: $VM_HOST"
  else
    log_info "VM is already running: $VM_NAME"
  fi
  exit 0
fi

while [ "$attempt" -le "$start_request_attempts" ]; do
  log_info "VM start request attempt $attempt/$start_request_attempts"
  request_vm_start
  sleep_cmd 3

  if vm_is_running; then
    if vm_is_reachable_via_ssh; then
      log_info "VM is reachable via SSH after startup attempt: $VM_HOST"
    else
      log_info "VM is running after startup attempt: $VM_NAME"
    fi
    exit 0
  fi

  log_warn "VM did not report running after start request attempt $attempt/$start_request_attempts: $VM_NAME"
  attempt=$((attempt + 1))
done

attempt=1
while [ "$attempt" -le "$max_attempts" ]; do
  if vm_is_running; then
    if vm_is_reachable_via_ssh; then
      log_info "VM is reachable via SSH after startup wait: $VM_HOST"
    else
      log_info "VM is running after startup wait: $VM_NAME"
    fi
    exit 0
  fi

  if [ -n "$VM_HOST" ]; then
    log_info "SSH not yet available for $VM_HOST"
  fi

  log_info "Waiting for VM to report running state ($attempt/$max_attempts): $VM_NAME"
  attempt=$((attempt + 1))
  sleep_cmd 2
done

log_warn "VM did not report running after startup attempts: $VM_NAME"
exit 0
