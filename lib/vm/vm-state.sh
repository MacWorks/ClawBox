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

vm_external_command_timeout_seconds() {
  printf '%s\n' "${CLAWBOX_VM_EXTERNAL_COMMAND_TIMEOUT_SECONDS:-5}"
}

run_vm_command_with_timeout() {
  local timeout_seconds="$1"

  shift
  command perl -MIPC::Open3 -MSymbol=gensym -MIO::Select -e '
    use strict;
    use warnings;

    my $timeout = shift @ARGV;
    my $err = gensym;
    my ($in, $out);
    my $pid = eval { open3($in, $out, $err, @ARGV) };
    if (!$pid) {
      print STDERR $@ || "failed to execute command\n";
      exit 127;
    }

    close $in;
    my $selector = IO::Select->new($out, $err);
    my $deadline = time() + $timeout;
    my $output = "";

    while ($selector->count) {
      my $remaining = $deadline - time();
      if ($remaining <= 0) {
        kill "TERM", $pid;
        select undef, undef, undef, 0.2;
        kill "KILL", $pid;
        print $output;
        print STDERR "command timed out after ${timeout}s\n";
        exit 124;
      }

      for my $fh ($selector->can_read($remaining)) {
        my $buffer = "";
        my $read = sysread($fh, $buffer, 4096);
        if ($read) {
          $output .= $buffer;
        } else {
          $selector->remove($fh);
          close $fh;
        }
      }
    }

    waitpid($pid, 0);
    my $status = $?;
    print $output;
    if ($status == -1) {
      exit 127;
    }
    if ($status & 127) {
      exit(128 + ($status & 127));
    }
    exit($status >> 8);
  ' "$timeout_seconds" "$@"
}

run_vm_command_with_default_timeout() {
  local timeout_seconds=''

  timeout_seconds="$(vm_external_command_timeout_seconds)"
  run_vm_command_with_timeout "$timeout_seconds" "$@"
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
VM_SELECTED_RUNTIME_STATE='unknown'
VM_GUEST_NETWORK_STATE='unknown'
VM_SSH_SERVICE_STATE='unknown'
VM_UTM_AUTOMATION_STATE='unknown'
VM_DETECTED_SSH_PROBE_STATE='unknown'

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
  setup_selected_vm_runtime_state_via_utmctl || return 1

  [ "$REPLY" = 'running' ]
}

setup_selected_vm_runtime_state_via_utmctl() {
  local utmctl_bin=''
  local vm_name=''
  local line
  local list_output=''
  local list_status=0

  REPLY='unknown'
  VM_UTM_AUTOMATION_STATE='unknown'

  normalize_vm_machine_name "${VM_MACHINE_NAME:-}"
  vm_name="$REPLY"
  [ -n "$vm_name" ] || return 1

  if ! resolve_utmctl_bin; then
    VM_UTM_AUTOMATION_STATE='unavailable'
    return 1
  fi
  utmctl_bin="$REPLY"

  list_output="$(run_vm_command_with_default_timeout "$utmctl_bin" list 2>&1)"
  list_status=$?

  if [ "$list_status" -eq 124 ]; then
    VM_UTM_AUTOMATION_STATE='timed-out'
    return 1
  fi

  if printf '%s\n' "$list_output" | grep -Eq '(^|[^0-9])-1743([^0-9]|$)|Not authorized to send Apple events'; then
    VM_UTM_AUTOMATION_STATE='denied'
    return 1
  fi

  if [ "$list_status" -ne 0 ]; then
    VM_UTM_AUTOMATION_STATE='unavailable'
    return 1
  fi

  VM_UTM_AUTOMATION_STATE='available'

  while IFS= read -r line; do
    case "$line" in
      *"$vm_name"*)
        case "$line" in
          *running*|*started*)
            VM_RUNNING_STATE_CONFIDENCE='exact'
            REPLY='running'
            return 0
            ;;
          *stopped*|*suspended*|*paused*)
            VM_RUNNING_STATE_CONFIDENCE='exact'
            REPLY='stopped'
            return 0
            ;;
          *)
            VM_RUNNING_STATE_CONFIDENCE='exact'
            REPLY='unknown'
            return 0
            ;;
        esac
        ;;
    esac
  done <<EOF
$list_output
EOF

  REPLY='unknown'
  return 1
}

setup_selected_vm_runtime_state() {
  VM_RUNNING_STATE_CONFIDENCE='unknown'

  setup_selected_vm_runtime_state_via_utmctl || return 1
}

setup_selected_vm_is_running() {
  VM_RUNNING_STATE_CONFIDENCE='unknown'

  if setup_selected_vm_runtime_state && [ "$REPLY" = 'running' ]; then
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
  local ssh_probe_state='unknown'
  local selected_runtime_state='unknown'

  VM_SELECTED_RUNTIME_STATE='unknown'
  VM_GUEST_NETWORK_STATE='unknown'
  VM_SSH_SERVICE_STATE='unknown'
  VM_RUNNING_STATE_CONFIDENCE='unknown'
  VM_DETECTED_SSH_PROBE_STATE='unknown'

  if [ -n "${VM_HOST:-}" ] && ssh_check "echo ok" >/dev/null 2>&1; then
    VM_RUNNING_STATE_CONFIDENCE='exact'
    VM_SELECTED_RUNTIME_STATE='running'
    VM_GUEST_NETWORK_STATE='reachable'
    VM_SSH_SERVICE_STATE='ready'
    REPLY='ready'
    return 0
  fi

  if [ -n "${VM_HOST:-}" ] && command -v classify_vm_ssh_connectivity >/dev/null 2>&1; then
    classify_vm_ssh_connectivity
    ssh_probe_state="$REPLY"
    VM_DETECTED_SSH_PROBE_STATE="$ssh_probe_state"

    case "$ssh_probe_state" in
      ready)
        VM_SELECTED_RUNTIME_STATE='running'
        VM_GUEST_NETWORK_STATE='reachable'
        VM_SSH_SERVICE_STATE='ready'
        VM_RUNNING_STATE_CONFIDENCE='exact'
        REPLY='ready'
        return 0
        ;;
      ssh-refused)
        VM_GUEST_NETWORK_STATE='reachable'
        VM_SSH_SERVICE_STATE='refused'
        if setup_selected_vm_runtime_state >/dev/null 2>&1 && [ "$REPLY" = 'running' ]; then
          VM_SELECTED_RUNTIME_STATE='running'
          VM_RUNNING_STATE_CONFIDENCE='exact'
        fi
        REPLY='running-no-ssh'
        return 0
        ;;
      ssh-auth-required)
        VM_GUEST_NETWORK_STATE='reachable'
        VM_SSH_SERVICE_STATE='auth-required'
        if setup_selected_vm_runtime_state >/dev/null 2>&1 && [ "$REPLY" = 'running' ]; then
          VM_SELECTED_RUNTIME_STATE='running'
          VM_RUNNING_STATE_CONFIDENCE='exact'
        fi
        REPLY='running-no-ssh'
        return 0
        ;;
      ssh-hostkey-unknown|ssh-hostkey-changed|ssh-hostkey-strict)
        VM_GUEST_NETWORK_STATE='reachable'
        VM_SSH_SERVICE_STATE='hostkey-blocked'
        if setup_selected_vm_runtime_state >/dev/null 2>&1 && [ "$REPLY" = 'running' ]; then
          VM_SELECTED_RUNTIME_STATE='running'
          VM_RUNNING_STATE_CONFIDENCE='exact'
        fi
        REPLY='running-no-ssh'
        return 0
        ;;
      ssh-remote-command-failed)
        VM_GUEST_NETWORK_STATE='reachable'
        VM_SSH_SERVICE_STATE='auth-failed'
        if setup_selected_vm_runtime_state >/dev/null 2>&1 && [ "$REPLY" = 'running' ]; then
          VM_SELECTED_RUNTIME_STATE='running'
          VM_RUNNING_STATE_CONFIDENCE='exact'
        fi
        REPLY='running-no-ssh'
        return 0
        ;;
      ssh-timeout)
        VM_GUEST_NETWORK_STATE='unknown'
        VM_SSH_SERVICE_STATE='timed-out'
        ;;
      invalid-target|unreachable)
        VM_GUEST_NETWORK_STATE='unreachable'
        VM_SSH_SERVICE_STATE='unreachable'
        ;;
      *)
        VM_GUEST_NETWORK_STATE='unknown'
        VM_SSH_SERVICE_STATE='unknown'
        ;;
    esac
  fi

  refresh_generic_virtualization_context >/dev/null 2>&1 || true

  if setup_selected_vm_runtime_state; then
    selected_runtime_state="$REPLY"
    VM_SELECTED_RUNTIME_STATE="$selected_runtime_state"
  else
    selected_runtime_state='unknown'
    VM_SELECTED_RUNTIME_STATE='unknown'
  fi

  if [ "$selected_runtime_state" = 'running' ]; then
    if [ "${VM_RECENTLY_STARTED:-false}" = true ]; then
      REPLY='booting'
    else
      REPLY='running-no-ssh'
    fi

    return 0
  fi

  if [ "$selected_runtime_state" = 'stopped' ]; then
    REPLY='stopped'
    return 0
  fi

  REPLY='unknown'
  return 0
}
