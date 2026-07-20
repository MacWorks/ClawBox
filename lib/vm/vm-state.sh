resolve_utmctl_bin() {
  REPLY=''

  if [ -n "${CLAWBOX_UTMCTL_BIN:-}" ] && [ -x "$CLAWBOX_UTMCTL_BIN" ]; then
    REPLY="$CLAWBOX_UTMCTL_BIN"
    return 0
  fi

  if command -v utmctl >/dev/null 2>&1; then
    REPLY="$(command -v utmctl)"
    return 0
  fi

  if [ -x '/Applications/UTM.app/Contents/MacOS/utmctl' ]; then
    REPLY='/Applications/UTM.app/Contents/MacOS/utmctl'
    return 0
  fi

  return 1
}

resolve_ps_bin() {
  REPLY=''

  if [ -n "${CLAWBOX_PS_BIN:-}" ] && [ -x "$CLAWBOX_PS_BIN" ]; then
    REPLY="$CLAWBOX_PS_BIN"
    return 0
  fi

  if command -v ps >/dev/null 2>&1; then
    REPLY="$(command -v ps)"
    return 0
  fi

  return 1
}

VM_RUNNING_STATE_CONFIDENCE='unknown'
VM_GENERIC_VIRTUALIZATION_RUNNING=false

normalize_vm_machine_name() {
  local vm_name="$1"

  vm_name="${vm_name//$'\r'/}"
  vm_name="${vm_name//$'\n'/}"
  vm_name="$(printf '%s' "$vm_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  REPLY="$vm_name"
  return 0
}

vm_process_line_indicates_virtualization() {
  local process_line="$2"

  case "$process_line" in
    *qemu-system*|*com.apple.Virtualization.VirtualMachine*|*AppleVirtualization*|*Virtualization.framework*)
      return 0
      ;;
  esac

  return 1
}

setup_vm_is_running_via_utmctl() {
  local utmctl_bin=''
  local vm_name=''
  local line

  normalize_vm_machine_name "${VM_MACHINE_NAME:-}"
  vm_name="$REPLY"
  [ -n "$vm_name" ] || return 1

  resolve_utmctl_bin || return 1
  utmctl_bin="$REPLY"

  while IFS= read -r line; do
    case "$line" in
      *"$vm_name"*)
        case "$line" in
          *running*|*started*)
            VM_RUNNING_STATE_CONFIDENCE='exact'
            return 0
            ;;
        esac
        ;;
    esac
  done <<EOF
$($utmctl_bin list 2>/dev/null)
EOF

  return 1
}

setup_selected_vm_is_running() {
  VM_RUNNING_STATE_CONFIDENCE='unknown'

  if setup_vm_is_running_via_utmctl; then
    return 0
  fi

  return 1
}

setup_vm_is_running_via_virtualization_processes() {
  local ps_bin=''
  local line

  resolve_ps_bin || return 1
  ps_bin="$REPLY"

  while IFS= read -r line; do
    if vm_process_line_indicates_virtualization "$line" "$line"; then
      VM_RUNNING_STATE_CONFIDENCE='generic'
      return 0
    fi
  done <<EOF
$($ps_bin axo user=,pid=,command= 2>/dev/null)
EOF

  return 1
}

setup_vm_is_running() {
  setup_selected_vm_is_running
}

refresh_generic_virtualization_context() {
  VM_GENERIC_VIRTUALIZATION_RUNNING=false

  if setup_vm_is_running_via_virtualization_processes; then
    VM_GENERIC_VIRTUALIZATION_RUNNING=true
    VM_RUNNING_STATE_CONFIDENCE='unknown'
    return 0
  fi

  VM_RUNNING_STATE_CONFIDENCE='unknown'
  return 1
}

detect_vm_state() {
  if ssh_check "echo ok" >/dev/null 2>&1; then
    VM_RUNNING_STATE_CONFIDENCE='exact'
    REPLY='ready'
    return 0
  fi

  refresh_generic_virtualization_context >/dev/null 2>&1 || true

  if setup_selected_vm_is_running; then
    if [ "${VM_RECENTLY_STARTED:-false}" = true ]; then
      REPLY='booting'
    else
      REPLY='running-no-ssh'
    fi

    return 0
  fi

  REPLY='stopped'
  return 0
}
