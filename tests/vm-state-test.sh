#!/bin/bash
set -euo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/.." && pwd)/tests/helpers/setup-harness.sh"
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/.." && pwd)/tests/helpers/timing.sh"

trap cleanup_temp_dir EXIT

TEMP_DIR="$(mktemp -d)"

prepare_vm_state_mocks() {
  local utmctl_output_file="$TEMP_DIR/utmctl-list.txt"
  local utmctl_ip_output_file="$TEMP_DIR/utmctl-ip-address.txt"
  local process_output_file="$TEMP_DIR/process-list.txt"

  setup_mock_bin_dir
  HOME="$TEMP_DIR/home"
  mkdir -p "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"
  export HOME

  write_mock_command utmctl '#!/bin/bash
if [ "$1" = "list" ]; then
  cat "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
elif [ "$1" = "ip-address" ]; then
  cat "$CLAWBOX_TEST_UTMCTL_IP_FILE"
fi'

  write_mock_command ps '#!/bin/bash
cat "$CLAWBOX_TEST_PROCESS_LIST_FILE"'

  write_mock_command ssh '#!/bin/bash
if [ -n "${CLAWBOX_TEST_SSH_STDERR:-}" ]; then
  printf "%s\n" "$CLAWBOX_TEST_SSH_STDERR" >&2
fi
exit "${CLAWBOX_TEST_SSH_EXIT_CODE:-255}"'

  write_mock_command arp '#!/bin/bash
if [ "${1:-}" = "-an" ]; then
  cat "$CLAWBOX_TEST_ARP_OUTPUT_FILE"
fi'

  CLAWBOX_UTMCTL_BIN="$MOCK_BIN_DIR/utmctl"
  CLAWBOX_PS_BIN="$MOCK_BIN_DIR/ps"
  CLAWBOX_TEST_UTMCTL_LIST_FILE="$utmctl_output_file"
  CLAWBOX_TEST_UTMCTL_IP_FILE="$utmctl_ip_output_file"
  CLAWBOX_TEST_PROCESS_LIST_FILE="$process_output_file"
  CLAWBOX_TEST_ARP_OUTPUT_FILE="$TEMP_DIR/arp-list.txt"
  CLAWBOX_TEST_SSH_EXIT_CODE=255
  CLAWBOX_TEST_SSH_STDERR=''
  : > "$CLAWBOX_TEST_UTMCTL_IP_FILE"
  : > "$CLAWBOX_TEST_ARP_OUTPUT_FILE"
  export CLAWBOX_UTMCTL_BIN CLAWBOX_PS_BIN CLAWBOX_TEST_UTMCTL_LIST_FILE CLAWBOX_TEST_UTMCTL_IP_FILE CLAWBOX_TEST_PROCESS_LIST_FILE CLAWBOX_TEST_ARP_OUTPUT_FILE CLAWBOX_TEST_SSH_EXIT_CODE CLAWBOX_TEST_SSH_STDERR
}

test_setup_vm_is_running_uses_resolved_utmctl() {
  prepare_vm_state_mocks

  printf 'Demo VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  load_setup_functions

  VM_MACHINE_NAME='Demo VM'

  if setup_vm_is_running_via_utmctl; then
    pass 'vm state uses resolved utmctl binary when PATH does not provide utmctl'
  else
    fail 'vm state should use resolved utmctl binary when PATH does not provide utmctl'
  fi

  assert_equals 'vm state marks utmctl-based detection as exact' "$VM_RUNNING_STATE_CONFIDENCE" 'exact'
}

test_start_vm_uses_selected_vm_name_with_utmctl() {
  local start_log="$TEMP_DIR/utmctl-start-name.log"

  prepare_vm_state_mocks

  write_mock_command utmctl '#!/bin/bash
printf "%s\n" "$*" >> "$CLAWBOX_TEST_UTMCTL_START_LOG"
exit 0'

  export CLAWBOX_TEST_UTMCTL_START_LOG="$start_log"

  load_setup_functions

  VM_MACHINE_NAME='macOS'

  if start_vm_with_utm; then
    pass 'vm startup succeeds when utmctl accepts the selected vm name'
  else
    fail 'vm startup should succeed when utmctl accepts the selected vm name'
  fi

  assert_contains 'start_vm passes the selected vm name to utmctl' "$(cat "$start_log")" 'start macOS'
}

test_selected_detected_vm_name_reaches_startup_path() {
  local started_vm_name=''

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y'

  ensure_vm_platform_ready() {
    VM_MACHINE_NAME='macOS'
    return 0
  }

  detect_vm_state() {
    REPLY='stopped'
    VM_RUNNING_STATE_CONFIDENCE='unknown'
    return 0
  }

  capture_vm_ip_discovery_baseline() {
    return 0
  }

  start_vm_with_utm() {
    started_vm_name="${VM_MACHINE_NAME:-}"
    return 1
  }

  wait_for_vm_running() {
    fail 'selected-vm startup path should not enter the long runtime wait after failed start'
    return 1
  }

  ensure_vm_platform_ready
  ensure_vm_connectivity_or_repair || true

  assert_equals 'selected detected vm name is preserved into the startup path' "$started_vm_name" 'macOS'
  if [ -n "$started_vm_name" ]; then
    pass 'startup path does not fall back to an empty vm name'
  else
    fail 'startup path should not fall back to an empty vm name'
  fi
}

test_start_vm_falls_back_to_applescript_after_utmctl_failure() {
  local osascript_log="$TEMP_DIR/osascript-start.log"
  local output

  prepare_vm_state_mocks

  write_mock_command utmctl '#!/bin/bash
printf "utmctl could not find a running UTM service\n" >&2
exit 1'

  write_mock_command osascript '#!/bin/bash
printf "%s\n" "$*" >> "$CLAWBOX_TEST_OSASCRIPT_LOG"
exit 0'

  CLAWBOX_OSASCRIPT_BIN="$MOCK_BIN_DIR/osascript"
  CLAWBOX_TEST_OSASCRIPT_LOG="$osascript_log"
  : > "$osascript_log"
  export CLAWBOX_OSASCRIPT_BIN CLAWBOX_TEST_OSASCRIPT_LOG

  load_setup_functions

  VM_MACHINE_NAME='macOS'

  output="$({ start_vm_with_utm || true; } 2>&1)"

  assert_contains 'vm startup reports the selected vm name when utmctl fails' "$output" 'macOS'
  assert_contains 'vm startup identifies utmctl as the failed start method' "$output" 'utmctl'
  assert_contains 'vm startup falls back to AppleScript after utmctl failure' "$(cat "$osascript_log")" 'UTM'
  assert_contains 'AppleScript fallback receives the selected vm name' "$(cat "$osascript_log")" 'macOS'
  assert_contains 'AppleScript fallback resolves the selected name to a VM object' "$(cat "$osascript_log")" 'every virtual machine whose name is my vmIdentifier'
  assert_contains 'AppleScript fallback starts the resolved VM object' "$(cat "$osascript_log")" 'start item 1 of matchingVMs'
}

test_start_vm_reports_each_failed_start_method() {
  local output

  prepare_vm_state_mocks

  write_mock_command utmctl '#!/bin/bash
printf "utmctl start failed\n" >&2
exit 1'

  write_mock_command osascript '#!/bin/bash
printf "AppleScript start failed\n" >&2
exit 1'

  CLAWBOX_OSASCRIPT_BIN="$MOCK_BIN_DIR/osascript"
  export CLAWBOX_OSASCRIPT_BIN

  load_setup_functions

  VM_MACHINE_NAME='macOS'

  output="$({ start_vm_with_utm || true; } 2>&1)"

  assert_contains 'vm startup failure identifies the selected vm name' "$output" 'macOS'
  assert_contains 'vm startup failure identifies utmctl failure' "$output" 'utmctl could not start VM'
  assert_contains 'vm startup failure identifies AppleScript failure' "$output" 'AppleScript could not activate UTM'
}

test_start_vm_reports_tcc_only_for_automation_denial() {
  local output

  prepare_vm_state_mocks

  write_mock_command utmctl '#!/bin/bash
exit 1'

  write_mock_command osascript '#!/bin/bash
printf "Not authorized to send Apple events to UTM. (-1743)\n" >&2
exit 1'

  CLAWBOX_OSASCRIPT_BIN="$MOCK_BIN_DIR/osascript"
  export CLAWBOX_OSASCRIPT_BIN

  load_setup_functions

  VM_MACHINE_NAME='macOS'

  output="$({ start_vm_with_utm || true; } 2>&1)"

  assert_contains 'automation denial reports TCC guidance' "$output" 'macOS blocked AppleScript automation for UTM.'
  assert_contains 'automation denial preserves the AppleScript error detail' "$output" 'Not authorized to send Apple events to UTM. (-1743)'
  assert_contains 'automation denial states that automatic vm start is blocked' "$output" 'Automatic VM start is blocked by macOS Automation permissions.'
  assert_contains 'automation denial states that clawbox cannot bypass tcc' "$output" 'ClawBox cannot bypass this macOS security control.'
  assert_contains 'automation denial prints the AppleScript verification command' "$output" "/usr/bin/osascript -e 'tell application \"UTM\" to get name of every virtual machine'"
  assert_contains 'automation denial prints the utmctl verification command' "$output" '/Applications/UTM.app/Contents/MacOS/utmctl list'
  assert_contains 'automation denial explains error minus 1743' "$output" 'Error -1743 means macOS is blocking automation.'
  assert_not_contains 'automation denial does not imply a generic vm startup failure' "$output" 'Failed to start VM.'
}

test_start_vm_does_not_misclassify_non_tcc_applescript_failure() {
  local output

  prepare_vm_state_mocks

  write_mock_command utmctl '#!/bin/bash
exit 1'

  write_mock_command osascript '#!/bin/bash
printf "UTM got an error: No virtual machine matches that name. (-1728)\n" >&2
exit 1'

  CLAWBOX_OSASCRIPT_BIN="$MOCK_BIN_DIR/osascript"
  export CLAWBOX_OSASCRIPT_BIN

  load_setup_functions

  VM_MACHINE_NAME='macOS'

  output="$({ start_vm_with_utm || true; } 2>&1)"

  assert_contains 'non-TCC AppleScript failure preserves the actual error' "$output" 'No virtual machine matches that name. (-1728)'
  assert_not_contains 'non-TCC AppleScript failure does not claim Automation denial' "$output" 'macOS blocked AppleScript automation for UTM.'
}

test_start_vm_not_found_prints_utmctl_registered_identities() {
  local output

  prepare_vm_state_mocks

  write_mock_command utmctl '#!/bin/bash
case "$1" in
  start)
    printf "Error: Virtual machine not found.\n" >&2
    exit 1
    ;;
  list)
    printf "UUID                                 Status   Name\n"
    printf "11111111-2222-3333-4444-555555555555 stopped  macOS Sequoia\n"
    ;;
esac'

  write_mock_command osascript '#!/bin/bash
printf "UTM got an error: No virtual machine matches that name. (-1728)\n" >&2
exit 1'

  CLAWBOX_OSASCRIPT_BIN="$MOCK_BIN_DIR/osascript"
  export CLAWBOX_OSASCRIPT_BIN

  load_setup_functions

  VM_MACHINE_NAME='macOS'

  output="$({ start_vm_with_utm || true; } 2>&1)"

  assert_contains 'utmctl not-found diagnostics show the requested identity' "$output" 'Requested UTM VM identity: macOS'
  assert_contains 'utmctl not-found diagnostics show registered UUIDs and names' "$output" '11111111-2222-3333-4444-555555555555 stopped  macOS Sequoia'
}

test_utm_package_discovery_uses_internal_display_name() {
  local documents_dir="$TEMP_DIR/utm-documents"
  local original_home="$HOME"
  local output

  mkdir -p "$documents_dir/macOS.utm"
  cat > "$documents_dir/macOS.utm/config.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Information</key>
  <dict>
    <key>Name</key>
    <string>macOS Sequoia</string>
    <key>UUID</key>
    <string>11111111-2222-3333-4444-555555555555</string>
  </dict>
</dict>
</plist>
EOF

  HOME="$TEMP_DIR/utm-home"
  mkdir -p "$HOME/Library/Containers/com.utmapp.UTM/Data"
  ln -s "$documents_dir" "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

  load_setup_functions
  output="$(list_detected_utm_vm_names)"

  HOME="$original_home"

  assert_equals 'utm package discovery uses the internal registered display name' "$output" 'macOS Sequoia'
}

test_detected_vm_selection_retains_package_path() {
  local documents_dir="$TEMP_DIR/selected-utm-home/Library/Containers/com.utmapp.UTM/Data/Documents"
  local original_home="$HOME"
  local selected_name=''
  local selected_path=''

  mkdir -p "$documents_dir/macOS.utm"
  cat > "$documents_dir/macOS.utm/config.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Information</key>
  <dict>
    <key>Name</key>
    <string>macOS</string>
  </dict>
</dict>
</plist>
EOF

  HOME="$TEMP_DIR/selected-utm-home"
  load_setup_functions
  prompt_yes_no() {
    REPLY='true'
  }

  resolve_vm_machine_name_value '' ''
  selected_name="$REPLY"
  selected_path="${VM_UTM_PATH:-}"
  HOME="$original_home"

  assert_equals 'detected vm selection retains the selected display name' "$selected_name" 'macOS'
  assert_equals 'detected vm selection retains the selected package path' "$selected_path" "$documents_dir/macOS.utm"
}

test_start_vm_opens_package_path_after_identity_methods_fail() {
  local open_log="$TEMP_DIR/utm-open-path.log"
  local start_count_file="$TEMP_DIR/utm-start-count.txt"
  local original_home="$HOME"
  local vm_path="$TEMP_DIR/start-utm-home/Library/Containers/com.utmapp.UTM/Data/Documents/macOS.utm"
  local output

  prepare_vm_state_mocks
  mkdir -p "$vm_path"
  cat > "$vm_path/config.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Information</key>
  <dict>
    <key>Name</key>
    <string>macOS</string>
  </dict>
</dict>
</plist>
EOF

  write_mock_command utmctl '#!/bin/bash
if [ "$1" = "start" ]; then
  count=0
  if [ -f "$CLAWBOX_TEST_UTM_START_COUNT" ]; then
    count="$(cat "$CLAWBOX_TEST_UTM_START_COUNT")"
  fi
  count=$((count + 1))
  printf "%s\n" "$count" > "$CLAWBOX_TEST_UTM_START_COUNT"
  if [ "$count" -eq 1 ]; then
    printf "Error: Virtual machine not found.\n" >&2
    exit 1
  fi
  exit 0
fi
if [ "$1" = "list" ]; then
  printf "UUID                                 Status   Name\n"
fi'

  write_mock_command osascript '#!/bin/bash
case "$*" in
  *activate*) exit 0 ;;
esac
printf "UTM got an error: No registered virtual machine matches. (-1728)\n" >&2
exit 1'

  write_mock_command open '#!/bin/bash
printf "%s\n" "$*" >> "$CLAWBOX_TEST_OPEN_LOG"
exit 0'

  CLAWBOX_OSASCRIPT_BIN="$MOCK_BIN_DIR/osascript"
  CLAWBOX_OPEN_BIN="$MOCK_BIN_DIR/open"
  CLAWBOX_TEST_OPEN_LOG="$open_log"
  CLAWBOX_TEST_UTM_START_COUNT="$start_count_file"
  export CLAWBOX_OSASCRIPT_BIN CLAWBOX_OPEN_BIN CLAWBOX_TEST_OPEN_LOG CLAWBOX_TEST_UTM_START_COUNT

  HOME="$TEMP_DIR/start-utm-home"
  load_setup_functions

  VM_MACHINE_NAME='macOS'
  VM_UTM_PATH=''

  output="$({ start_vm_with_utm || true; } 2>&1)"
  HOME="$original_home"

  assert_contains 'path fallback reports the attempted utm package path' "$output" "Attempting UTM package path: $vm_path"
  assert_equals 'path fallback opens the retained utm package path with UTM' "$(cat "$open_log")" "-a UTM $vm_path"
  assert_equals 'path fallback retries utmctl once after opening the package' "$(cat "$start_count_file")" '2'
}

test_start_vm_tcc_denial_opens_package_for_manual_start() {
  local open_log="$TEMP_DIR/utm-open-tcc.log"
  local output_file="$TEMP_DIR/utm-start-tcc-output.txt"
  local start_count_file="$TEMP_DIR/utm-start-tcc-count.txt"
  local vm_path="$TEMP_DIR/tcc-utm-home/Library/Containers/com.utmapp.UTM/Data/Documents/macOS.utm"
  local start_status=0

  prepare_vm_state_mocks
  mkdir -p "$vm_path"

  write_mock_command utmctl '#!/bin/bash
if [ "$1" = "start" ]; then
  count=0
  if [ -f "$CLAWBOX_TEST_UTM_START_COUNT" ]; then
    count="$(cat "$CLAWBOX_TEST_UTM_START_COUNT")"
  fi
  printf "%s\n" "$((count + 1))" > "$CLAWBOX_TEST_UTM_START_COUNT"
  printf "Error: Virtual machine not found.\n" >&2
  exit 1
fi
if [ "$1" = "list" ]; then
  printf "Error from event: The operation couldn’t be completed. (OSStatus error -1743.)\n"
  printf "UUID                                 Status   Name\n"
  exit 0
fi'

  write_mock_command osascript '#!/bin/bash
case "$*" in
  *activate*) exit 0 ;;
esac
printf "execution error: Not authorized to send Apple events to UTM. (-1743)\n" >&2
exit 1'

  write_mock_command open '#!/bin/bash
printf "%s\n" "$*" >> "$CLAWBOX_TEST_OPEN_LOG"
exit 0'

  CLAWBOX_OSASCRIPT_BIN="$MOCK_BIN_DIR/osascript"
  CLAWBOX_OPEN_BIN="$MOCK_BIN_DIR/open"
  CLAWBOX_TEST_OPEN_LOG="$open_log"
  CLAWBOX_TEST_UTM_START_COUNT="$start_count_file"
  export CLAWBOX_OSASCRIPT_BIN CLAWBOX_OPEN_BIN CLAWBOX_TEST_OPEN_LOG CLAWBOX_TEST_UTM_START_COUNT

  load_setup_functions

  VM_MACHINE_NAME='macOS'
  VM_UTM_PATH="$vm_path"

  start_vm_with_utm > "$output_file" 2>&1 || start_status=$?

  assert_equals 'tcc-blocked automated startup remains incomplete until manual confirmation' "$start_status" '1'
  assert_equals 'utmctl list automation denial marks automated UTM control as blocked' "${UTM_AUTOMATION_BLOCKED:-false}" 'true'
  assert_contains 'tcc-blocked startup reports utmctl AppleEvents denial' "$(cat "$output_file")" 'macOS blocked utmctl automation for UTM.'
  assert_contains 'tcc-blocked startup advises relaunching the requesting terminal app' "$(cat "$output_file")" 'Fully quit and reopen the terminal app after changing this permission.'
  assert_contains 'tcc-blocked startup advises a login refresh if relaunch is insufficient' "$(cat "$output_file")" 'If automation still fails, log out of macOS and log back in.'
  assert_equals 'tcc-blocked startup opens the known package with UTM' "$(cat "$open_log")" "-a UTM $vm_path"
  assert_equals 'tcc-blocked startup does not retry a known-blocked utmctl command' "$(cat "$start_count_file")" '1'
}

test_start_vm_skips_package_fallback_when_path_is_unknown() {
  local open_log="$TEMP_DIR/utm-open-unknown.log"
  local output

  prepare_vm_state_mocks

  write_mock_command utmctl '#!/bin/bash
if [ "$1" = "start" ]; then
  printf "Error: Virtual machine not found.\n" >&2
  exit 1
fi
if [ "$1" = "list" ]; then
  printf "UUID                                 Status   Name\n"
fi'

  write_mock_command osascript '#!/bin/bash
case "$*" in
  *activate*) exit 0 ;;
esac
printf "UTM got an error: No registered virtual machine matches. (-1728)\n" >&2
exit 1'

  write_mock_command open '#!/bin/bash
printf "%s\n" "$*" >> "$CLAWBOX_TEST_OPEN_LOG"
exit 0'

  CLAWBOX_OSASCRIPT_BIN="$MOCK_BIN_DIR/osascript"
  CLAWBOX_OPEN_BIN="$MOCK_BIN_DIR/open"
  CLAWBOX_TEST_OPEN_LOG="$open_log"
  export CLAWBOX_OSASCRIPT_BIN CLAWBOX_OPEN_BIN CLAWBOX_TEST_OPEN_LOG

  load_setup_functions
  resolve_detected_utm_vm_path() {
    return 1
  }

  VM_MACHINE_NAME='macOS'
  VM_UTM_PATH=''

  output="$({ start_vm_with_utm || true; } 2>&1)"

  assert_not_contains 'unknown package path does not report a path attempt' "$output" 'Attempting UTM package path:'
  if [ ! -f "$open_log" ]; then
    pass 'unknown package path does not invoke open'
  else
    fail 'unknown package path should not invoke open'
  fi
}

test_tcc_blocked_startup_can_continue_into_existing_readiness_flow() {
  local detect_calls=0
  local manual_wait_file="$TEMP_DIR/tcc-manual-wait-count.txt"
  local output_file="$TEMP_DIR/tcc-manual-continuation-output.txt"
  local status=0

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'y'
  printf '0\n' > "$manual_wait_file"

  detect_vm_state() {
    detect_calls=$((detect_calls + 1))
    if [ "$detect_calls" -eq 1 ]; then
      REPLY='stopped'
      VM_RUNNING_STATE_CONFIDENCE='unknown'
    else
      REPLY='booting'
      VM_RUNNING_STATE_CONFIDENCE='exact'
    fi
    return 0
  }

  capture_vm_ip_discovery_baseline() {
    return 0
  }

  start_vm_with_utm() {
    UTM_AUTOMATION_BLOCKED=true
    UTM_PACKAGE_OPENED=true
    return 1
  }

  wait_for_manual_vm_running() {
    local count
    count="$(cat "$manual_wait_file")"
    printf '%s\n' "$((count + 1))" > "$manual_wait_file"
    return 0
  }

  wait_for_vm_running() {
    fail 'manual UTM startup should not enter the long automated runtime wait'
    return 1
  }

  wait_for_known_vm_ssh_readiness() {
    REPLY='ready'
    return 0
  }

  ensure_vm_connectivity_or_repair > "$output_file" 2>&1 || status=$?

  assert_equals 'manual UTM startup confirmation can continue successfully' "$status" '0'
  assert_contains 'manual UTM startup explains the blocked automation state' "$(cat "$output_file")" 'macOS is blocking automated control of UTM.'
  assert_contains 'manual UTM startup explains that opening the package cannot start the VM' "$(cat "$output_file")" 'Opening the package can select the VM, but it cannot start the VM.'
  assert_contains 'manual UTM startup instructs the user to click Run or Play' "$(cat "$output_file")" 'Click the Run/Play button in UTM.'
  assert_contains 'manual UTM startup asks before resuming readiness checks' "$(cat "$output_file")" 'Once the VM is starting or running, continue? [Y/n]:'
  assert_equals 'manual UTM startup performs one bounded runtime verification' "$(cat "$manual_wait_file")" '1'
  assert_not_contains 'manual UTM startup does not emit a generic startup failure' "$(cat "$output_file")" 'Failed to start VM.'
}

test_manual_utm_start_reprompts_when_runtime_is_not_detected() {
  local detect_calls=0
  local manual_wait_file="$TEMP_DIR/manual-reprompt-wait-count.txt"
  local network_wait_file="$TEMP_DIR/manual-reprompt-network-count.txt"
  local output_file="$TEMP_DIR/manual-reprompt-output.txt"
  local status=0

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'y' '1'
  printf '0\n' > "$manual_wait_file"
  printf '0\n' > "$network_wait_file"

  detect_vm_state() {
    detect_calls=$((detect_calls + 1))
    if [ "$detect_calls" -eq 1 ]; then
      REPLY='stopped'
      VM_RUNNING_STATE_CONFIDENCE='unknown'
    else
      REPLY='booting'
      VM_RUNNING_STATE_CONFIDENCE='exact'
    fi
    return 0
  }

  capture_vm_ip_discovery_baseline() {
    return 0
  }

  start_vm_with_utm() {
    UTM_AUTOMATION_BLOCKED=true
    UTM_PACKAGE_OPENED=true
    return 1
  }

  wait_for_manual_vm_running() {
    local count
    count="$(cat "$manual_wait_file")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$manual_wait_file"
    [ "$count" -ge 2 ]
  }

  wait_for_known_vm_ssh_readiness() {
    local count
    count="$(cat "$network_wait_file")"
    printf '%s\n' "$((count + 1))" > "$network_wait_file"
    REPLY='ready'
    return 0
  }

  ensure_vm_connectivity_or_repair > "$output_file" 2>&1 || status=$?

  assert_equals 'manual startup retry succeeds after runtime appears on the second check' "$status" '0'
  assert_contains 'manual startup reports that the runtime was not detected' "$(cat "$output_file")" 'The VM is still not running.'
  assert_contains 'manual startup offers another runtime check' "$(cat "$output_file")" '1) I clicked Run/Play; check again'
  assert_contains 'manual startup offers to reopen UTM' "$(cat "$output_file")" '2) Open UTM again'
  assert_contains 'manual startup offers an explicit abort' "$(cat "$output_file")" '3) Abort setup'
  assert_equals 'manual startup performs the requested bounded recheck' "$(cat "$manual_wait_file")" '2'
  assert_equals 'network and ssh readiness starts only after runtime detection' "$(cat "$network_wait_file")" '1'
}

test_manual_utm_start_abort_never_enters_network_readiness() {
  local network_wait_file="$TEMP_DIR/manual-abort-network-count.txt"
  local output_file="$TEMP_DIR/manual-abort-output.txt"

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'y' '3'
  printf '0\n' > "$network_wait_file"

  detect_vm_state() {
    REPLY='stopped'
    VM_RUNNING_STATE_CONFIDENCE='unknown'
    return 0
  }

  capture_vm_ip_discovery_baseline() {
    return 0
  }

  start_vm_with_utm() {
    UTM_AUTOMATION_BLOCKED=true
    UTM_PACKAGE_OPENED=true
    return 1
  }

  wait_for_manual_vm_running() {
    return 1
  }

  wait_for_known_vm_ssh_readiness() {
    printf '1\n' > "$network_wait_file"
    return 1
  }

  ensure_vm_connectivity_or_repair > "$output_file" 2>&1 || true

  assert_contains 'manual startup abort reports that runtime was not detected' "$(cat "$output_file")" 'The VM is still not running.'
  assert_equals 'manual startup abort does not enter network or ssh readiness' "$(cat "$network_wait_file")" '0'
}

test_non_tcc_startup_failure_does_not_offer_manual_continuation() {
  local output_file="$TEMP_DIR/non-tcc-start-failure-output.txt"

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y'

  detect_vm_state() {
    REPLY='stopped'
    VM_RUNNING_STATE_CONFIDENCE='unknown'
    return 0
  }

  capture_vm_ip_discovery_baseline() {
    return 0
  }

  start_vm_with_utm() {
    UTM_AUTOMATION_BLOCKED=false
    UTM_PACKAGE_OPENED=false
    return 1
  }

  ensure_vm_connectivity_or_repair > "$output_file" 2>&1 || true

  assert_contains 'generic automated startup failure still fails clearly' "$(cat "$output_file")" 'Failed to start VM.'
  assert_not_contains 'generic automated startup failure does not claim TCC blocking' "$(cat "$output_file")" 'macOS is blocking automated control of UTM.'
  assert_not_contains 'generic automated startup failure does not offer manual TCC continuation' "$(cat "$output_file")" 'Once the VM is starting or running, continue?'
}

test_detect_vm_state_uses_cross_user_virtualization_fallback() {
  prepare_vm_state_mocks

  load_setup_functions

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  : > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  printf 'usera 4242 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine\n' > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  VM_RECENTLY_STARTED=false
  detect_vm_state
  assert_equals 'detect_vm_state reports running-no-ssh for a VM already running under another macOS user' "$REPLY" 'running-no-ssh'
  assert_equals 'detect_vm_state marks cross-user virtualization fallback as generic' "$VM_RUNNING_STATE_CONFIDENCE" 'generic'
}

test_detect_vm_state_distinguishes_running_from_stopped() {
  prepare_vm_state_mocks

  load_setup_functions

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  : > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  printf 'usera 4242 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine\n' > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  VM_RECENTLY_STARTED=false
  detect_vm_state
  assert_equals 'detect_vm_state reports running-no-ssh when VM is running without SSH' "$REPLY" 'running-no-ssh'

  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  detect_vm_state
  assert_equals 'detect_vm_state reports stopped only when VM is not running' "$REPLY" 'stopped'
}

test_detect_vm_state_does_not_treat_open_utm_app_as_running() {
  prepare_vm_state_mocks

  load_setup_functions

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  : > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  printf 'usera 4242 /Applications/UTM.app/Contents/MacOS/UTM\n' > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  VM_RECENTLY_STARTED=false
  detect_vm_state
  assert_equals 'detect_vm_state does not treat the UTM app process alone as proof that the vm is running' "$REPLY" 'stopped'
}

test_ensure_vm_connectivity_reports_running_without_ssh() {
  local output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'n'

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  : > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  printf 'usera 4242 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine\n' > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'connectivity repair warns that the configured VM could not be confirmed from generic virtualization evidence' "$output" 'A virtualization process is running on this Mac, but ClawBox could not confirm that it matches the configured VM.'
  assert_contains 'connectivity repair still offers SSH bootstrap flow' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
  assert_not_contains 'connectivity repair does not claim the VM is stopped when it is running' "$output" 'VM is not running.'
  assert_not_contains 'connectivity repair does not attempt a second startup when another user already has the VM running' "$output" 'Start the VM now?'
  assert_not_contains 'connectivity repair does not print failed startup when another user already has the VM running' "$output" 'Failed to start VM.'
  assert_not_contains 'connectivity repair does not use the unsupported probable-running wording' "$output" 'VM appears to already be running but is not yet reachable via SSH.'
}

test_ensure_vm_connectivity_fails_fast_for_invalid_target() {
  local output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@bad-target'
  : > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  printf 'usera 4242 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine\n' > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  CLAWBOX_TEST_SSH_STDERR='ssh: Could not resolve hostname bad-target: nodename nor servname provided, or not known'

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'invalid-target flow reports the current vm address is invalid' "$output" 'A virtualization process is running on this Mac, but the current VM address is invalid.'
  assert_contains 'invalid-target flow points to vm ip correction' "$output" '- The VM IP address is incorrect'
  assert_not_contains 'invalid-target flow does not offer automatic ssh bootstrap' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
  assert_not_contains 'invalid-target flow does not use the unsupported probable-running wording' "$output" 'VM appears to already be running but is not yet reachable via SSH.'
}

test_ensure_vm_connectivity_distinguishes_ssh_timeout_for_running_vm() {
  local output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  CLAWBOX_TEST_SSH_STDERR='ssh: connect to host 192.168.64.2 port 22: Operation timed out'

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'timeout flow reports ssh timeout for a running vm' "$output" 'VM is booting or running, but SSH timed out.'
  assert_contains 'timeout flow explains that the vm may still be booting' "$output" '- VM is still booting'
  assert_not_contains 'timeout flow does not offer automatic ssh bootstrap while the host is timing out' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
}

test_ensure_vm_connectivity_distinguishes_ssh_refusal() {
  local output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  CLAWBOX_TEST_SSH_STDERR='ssh: connect to host 192.168.64.2 port 22: Connection refused'
  queue_prompt_answers 'n'

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'ssh-refused flow reports the port refusal clearly' "$output" 'VM is running, but SSH on port 22 is refusing connections.'
  assert_contains 'ssh-refused flow explains the likely onboarding issue' "$output" 'Remote Login may not yet be enabled inside the VM.'
  assert_contains 'ssh-refused flow points to the guest settings path in a single enablement line' "$output" 'In the VM, enable: '
  assert_contains 'ssh-refused flow points to the guest settings path' "$output" 'System Settings > Sharing > Remote Login'
  assert_contains 'ssh-refused flow asks for confirmation before retrying with a yes default' "$output" 'Is Remote Login now enabled? [Y/n]:'
  assert_contains 'ssh-refused flow falls back to manual setup after declining the retry' "$output" ' > Manual SSH Setup'
  assert_not_contains 'ssh-refused flow does not offer automatic ssh bootstrap before remote login is enabled' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
}

test_ensure_vm_connectivity_classifies_missing_key_auth_without_failure_framing() {
  local output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'n'

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  CLAWBOX_TEST_SSH_STDERR='Permission denied (publickey,password).'

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'ssh auth-required flow states connectivity is working' "$output" 'SSH connectivity is working.'
  assert_contains 'ssh auth-required flow states key auth could not be confirmed yet' "$output" 'Passwordless SSH authentication could not be confirmed yet.'
  assert_contains 'ssh auth-required flow still offers bootstrap prompt' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
  assert_not_contains 'ssh auth-required flow does not use possible-causes failure framing' "$output" 'Possible causes:'
  assert_not_contains 'ssh auth-required flow does not list ssh keys as a possible cause bullet' "$output" '- SSH keys are not configured'
}

test_ensure_vm_connectivity_treats_batch_auth_success_as_ready() {
  local output
  local status=0

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  classify_vm_ssh_connectivity() {
    REPLY='ready'
    return 0
  }

  output="$({
    if ensure_vm_connectivity_or_repair; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
  } 2>&1)"

  if printf '%s' "$output" | grep -Fq 'STATUS:0'; then
    pass 'batch auth success is treated as ready and continues without bootstrap'
  else
    fail 'batch auth success should be treated as ready and continue without bootstrap'
  fi

  assert_contains 'batch auth success reports that key auth is already configured' "$output" 'SSH key-based authentication is already configured.'
  assert_not_contains 'batch auth success does not prompt for bootstrap' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
  assert_not_contains 'batch auth success does not claim passwordless auth is unconfirmed' "$output" 'Passwordless SSH authentication could not be confirmed yet.'
}

test_ensure_vm_connectivity_skips_bootstrap_when_key_auth_is_ready() {
  local output
  local status=0

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  CLAWBOX_TEST_SSH_EXIT_CODE=0
  CLAWBOX_TEST_SSH_STDERR=''

  output="$({
    if ensure_vm_connectivity_or_repair; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
  } 2>&1)"

  if printf '%s' "$output" | grep -Fq 'STATUS:0'; then
    pass 'ready ssh auth flow continues automatically without bootstrap'
  else
    fail 'ready ssh auth flow should continue automatically without bootstrap'
  fi

  assert_not_contains 'ready ssh auth flow does not prompt for bootstrap again' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
}

test_ensure_vm_connectivity_emits_single_ssh_bootstrap_success_line() {
  local output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y'

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  CLAWBOX_TEST_SSH_STDERR='Permission denied (publickey,password).'

  attempt_ssh_access_bootstrap() {
    success 'SSH access configured successfully.'
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_equals 'ssh bootstrap success line is emitted exactly once' "$(printf '%s' "$output" | grep -F -c 'SSH access configured successfully.')" '1'
}

test_ensure_vm_connectivity_retries_ssh_after_remote_login_confirmation() {
  local output
  local ssh_wait_count_file
  local classify_calls=0

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'y'
  ssh_wait_count_file="$TEMP_DIR/ssh-wait-calls.txt"
  : > "$ssh_wait_count_file"

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  classify_vm_ssh_connectivity() {
    classify_calls=$((classify_calls + 1))

    if [ "$classify_calls" -eq 1 ]; then
      REPLY='ssh-refused'
    else
      REPLY='ssh-auth-required'
    fi

    return 0
  }

  wait_for_vm_ssh_service() {
    printf 'call\n' >> "$ssh_wait_count_file"
    REPLY='ready'
    return 0
  }

  attempt_ssh_access_bootstrap() {
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'remote login retry flow prompts for remote login confirmation' "$output" 'Is Remote Login now enabled? [Y/n]:'
  assert_equals 'remote login retry flow retries only the ssh readiness stage once' "$(wc -l < "$ssh_wait_count_file" | tr -d '[:space:]')" '1'
  assert_contains 'remote login retry flow continues into ssh bootstrap after confirmation' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
  assert_not_contains 'remote login retry flow does not emit contradictory generic ssh failure messaging after readiness succeeds' "$output" 'VM is running but is not yet reachable via SSH.'
  assert_not_contains 'remote login retry flow does not dump manual setup after a successful retry confirmation' "$output" ' > Manual SSH Setup'
}

test_remote_login_confirmation_allows_one_bounded_refusal_retry() {
  local output
  local ssh_wait_count_file

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'y'
  ssh_wait_count_file="$TEMP_DIR/remote-login-refused-waits.txt"
  : > "$ssh_wait_count_file"

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.7'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  classify_vm_ssh_connectivity() {
    REPLY='ssh-refused'
    return 0
  }

  wait_for_vm_ssh_service() {
    printf 'call\n' >> "$ssh_wait_count_file"
    REPLY='ssh-refused'
    return 1
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_equals 'remote login refusal retry remains bounded to two readiness waits' "$(wc -l < "$ssh_wait_count_file" | tr -d '[:space:]')" '2'
  assert_contains 'remote login refusal retry explains that ssh is still refusing connections' "$output" 'SSH is still refusing connections on port 22.'
  assert_contains 'remote login refusal retry asks before the final bounded retry' "$output" 'Retry after confirming Remote Login is enabled? [Y/n]:'
  assert_contains 'remote login refusal retry explains the required action before manual fallback' "$output" 'Verify Remote Login is enabled for the VM user, then re-run setup.'
  assert_contains 'remote login refusal retry preserves manual ssh fallback' "$output" ' > Manual SSH Setup'
}

test_remote_login_retry_hostkey_failure_prints_known_hosts_remediation() {
  local output
  local classify_calls=0

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'y' 'y'

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.7'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  classify_vm_ssh_connectivity() {
    classify_calls=$((classify_calls + 1))
    if [ "$classify_calls" -eq 1 ]; then
      REPLY='ssh-refused'
    elif [ "$classify_calls" -eq 2 ]; then
      REPLY='ssh-hostkey-changed'
    else
      REPLY='ssh-auth-required'
    fi
    return 0
  }

  wait_for_vm_ssh_service() {
    REPLY='ready'
    return 0
  }

  attempt_ssh_access_bootstrap() {
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'remote login changed-host-key transition reports stale key blocking' "$output" 'SSH reports that the VM host key changed.'
  assert_contains 'remote login hostkey transition prints stale known hosts remediation' "$output" 'ssh-keygen -R 192.168.64.7'
  assert_contains 'remote login changed-host-key transition offers a bounded readiness retry' "$output" 'Retry SSH after completing this step? [Y/n]:'
  assert_not_contains 'remote login changed-host-key transition does not immediately dump manual setup' "$output" ' > Manual SSH Setup'
}

test_ssh_classifier_distinguishes_first_contact_from_changed_host_key() {
  local original_home="$HOME"

  prepare_vm_state_mocks
  HOME="$TEMP_DIR/hostkey-home"
  mkdir -p "$HOME"

  load_setup_functions

  VM_HOST='vm-user@192.168.64.7'
  CLAWBOX_TEST_SSH_STDERR='Host key verification failed.'
  probe_ssh_batch_auth_target "$VM_HOST"
  assert_equals 'missing known_hosts classifies generic verification failure as first contact' "$REPLY" 'ssh-hostkey-unknown'

  CLAWBOX_TEST_SSH_STDERR='WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!'
  probe_ssh_batch_auth_target "$VM_HOST"
  assert_equals 'changed host identification is classified as a stale host key' "$REPLY" 'ssh-hostkey-changed'

  CLAWBOX_TEST_SSH_STDERR='No ED25519 host key is known for 192.168.64.7 and you have requested strict checking. Host key verification failed.'
  probe_ssh_batch_auth_target "$VM_HOST"
  assert_equals 'explicit strict host key checking failure remains distinct' "$REPLY" 'ssh-hostkey-strict'

  HOME="$original_home"
}

test_first_contact_host_key_guidance_retries_without_manual_setup_dump() {
  local output
  local classify_calls=0
  local trust_attempt_file="$TEMP_DIR/hostkey-trust-attempted.txt"

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'y'

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.7'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  : > "$trust_attempt_file"

  classify_vm_ssh_connectivity() {
    classify_calls=$((classify_calls + 1))
    if [ "$classify_calls" -eq 1 ]; then
      REPLY='ssh-hostkey-unknown'
    else
      REPLY='ready'
    fi
    return 0
  }

  accept_new_vm_ssh_host_key() {
    printf 'called\n' >> "$trust_attempt_file"
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'first-contact host key guidance explains that trust has not been established' "$output" 'SSH has not trusted this VM host key yet.'
  assert_contains 'first-contact host key guidance offers automated accept-new trust' "$output" 'Trust this VM host key now? [Y/n]:'
  assert_equals 'first-contact host key confirmation invokes accept-new once' "$(wc -l < "$trust_attempt_file" | tr -d '[:space:]')" '1'
  assert_not_contains 'first-contact host key recovery does not dump full manual setup after a successful retry' "$output" ' > Manual SSH Setup'
}

test_accept_new_host_key_uses_bounded_safe_ssh_options() {
  local ssh_log="$TEMP_DIR/accept-new-ssh.log"
  local original_home="$HOME"

  prepare_vm_state_mocks

  write_mock_command ssh '#!/bin/bash
printf "%s\n" "$*" >> "$CLAWBOX_TEST_ACCEPT_NEW_SSH_LOG"
exit 255'

  CLAWBOX_TEST_ACCEPT_NEW_SSH_LOG="$ssh_log"
  export CLAWBOX_TEST_ACCEPT_NEW_SSH_LOG

  load_setup_functions

  HOME="$TEMP_DIR/accept-new-home"
  VM_HOST='vm-user@192.168.64.7'
  accept_new_vm_ssh_host_key || true
  HOME="$original_home"

  assert_contains 'accept-new host key helper uses accept-new policy' "$(cat "$ssh_log")" 'StrictHostKeyChecking=accept-new'
  assert_contains 'accept-new host key helper keeps batch authentication noninteractive' "$(cat "$ssh_log")" 'BatchMode=yes'
  assert_contains 'accept-new host key helper uses the configured vm target' "$(cat "$ssh_log")" "vm-user@192.168.64.7 echo ok"
}

test_vm_ssh_classifier_helper_is_available_for_vm_repair() {
  prepare_vm_state_mocks

  load_setup_functions

  if command -v classify_vm_ssh_connectivity >/dev/null 2>&1; then
    pass 'vm repair runtime helper classify_vm_ssh_connectivity is available after setup sources vm libraries'
  else
    fail 'vm repair runtime helper classify_vm_ssh_connectivity should be available after setup sources vm libraries'
  fi
}

test_classify_vm_ssh_connectivity_promotes_auth_required_when_batch_auth_succeeds() {
  prepare_vm_state_mocks

  load_setup_functions

  VM_HOST='vm-user@192.168.64.2'

  probe_vm_ssh_endpoint() {
    REPLY='ssh-auth-required'
    return 0
  }

  probe_ssh_batch_auth_target() {
    REPLY='ready'
    return 0
  }

  classify_vm_ssh_connectivity
  assert_equals 'ssh connectivity classifier promotes auth-required to ready when batch auth succeeds' "$REPLY" 'ready'
}

test_copy_ssh_key_to_vm_treats_all_keys_skipped_as_success_when_auth_works() {
  prepare_vm_state_mocks

  load_setup_functions

  VM_HOST='vm-user@192.168.64.2'

  ssh-copy-id() {
    printf '%s\n' 'All keys were skipped because they already exist on the remote system.' >&2
    return 1
  }

  ssh_onboarding_check() {
    return 0
  }

  if copy_ssh_key_to_vm; then
    pass 'copy ssh key treats all-keys-skipped as success when key auth already works'
  else
    fail 'copy ssh key should treat all-keys-skipped as success when key auth already works'
  fi

  assert_equals 'copy ssh key records skipped-key non-zero exit status for diagnostics' "$VM_SSH_COPY_ID_STATUS" '1'
  assert_contains 'copy ssh key records skipped-key diagnostic output' "$VM_SSH_COPY_ID_OUTPUT" 'All keys were skipped because they already exist on the remote system.'
}

test_copy_ssh_key_to_vm_keeps_failure_when_all_keys_skipped_but_auth_fails() {
  prepare_vm_state_mocks

  load_setup_functions

  VM_HOST='vm-user@192.168.64.2'

  ssh-copy-id() {
    printf '%s\n' 'All keys were skipped because they already exist on the remote system.' >&2
    return 1
  }

  ssh_onboarding_check() {
    return 1
  }

  if copy_ssh_key_to_vm; then
    fail 'copy ssh key should fail when all keys are skipped but batch auth still fails'
  else
    pass 'copy ssh key fails when all keys are skipped but batch auth still fails'
  fi
}

test_ensure_vm_connectivity_ssh_refusal_path_does_not_emit_missing_classifier_errors() {
  local output
  local classify_calls=0

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'n'

  VM_MACHINE_NAME='Shared VM'
  VM_HOST='vm-user@192.168.64.2'
  printf 'Shared VM running\n' > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
  : > "$CLAWBOX_TEST_PROCESS_LIST_FILE"

  classify_vm_ssh_connectivity() {
    classify_calls=$((classify_calls + 1))

    if [ "$classify_calls" -eq 1 ]; then
      REPLY='ssh-refused'
    else
      REPLY='ssh-auth-required'
    fi

    return 0
  }

  wait_for_vm_ssh_service() {
    REPLY='ready'
    return 0
  }

  attempt_ssh_access_bootstrap() {
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'ssh refusal path still prompts for remote login confirmation' "$output" 'Is Remote Login now enabled? [Y/n]:'
  assert_contains 'ssh refusal path still transitions to ssh bootstrap choice after classification' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
  assert_not_contains 'ssh refusal path does not emit missing classify helper runtime errors' "$output" 'classify_vm_ssh_connectivity: command not found'
}

test_ensure_vm_connectivity_recovers_vm_ip_after_startup() {
  local output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' 'y'

  VM_MACHINE_NAME='Shared VM'
  VM_USER='vm-user'
  VM_IP='192.168.64.7'
  VM_HOST='vm-user@192.168.64.7'
  FIREWALL_SHARED_SUBNET='192.168.64.0/24'
  printf '? (192.168.64.6) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [ethernet]\n' > "$CLAWBOX_TEST_ARP_OUTPUT_FILE"

  detect_vm_state() {
    REPLY='running-no-ssh'
    VM_RUNNING_STATE_CONFIDENCE='exact'
    return 0
  }

  write_env_from_template() { :; }
  source_env_file() { :; }

  probe_vm_ssh_endpoint() {
    if [ "$VM_HOST" = 'vm-user@192.168.64.7' ]; then
      REPLY='unreachable'
    else
      REPLY='ssh-auth-required'
    fi
    return 0
  }

  probe_ssh_target_endpoint() {
    if [ "$1" = 'vm-user@192.168.64.6' ]; then
      REPLY='ssh-refused'
    else
      REPLY='unreachable'
    fi
    return 0
  }

  attempt_ssh_access_bootstrap() {
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'vm ip recovery reports discovery progress' "$output" 'Attempting VM IP discovery...'
  assert_contains 'vm ip recovery reports the detected likely address' "$output" 'Detected likely VM address: 192.168.64.6'
}

test_discover_vm_ip_candidates_excludes_ips_already_proven_unreachable() {
  prepare_vm_state_mocks

  load_setup_functions

  VM_MACHINE_NAME='Shared VM'
  VM_USER='vm-user'
  VM_IP='192.168.64.7'
  VM_HOST='vm-user@192.168.64.7'
  FIREWALL_SHARED_SUBNET='192.168.64.0/24'
  printf '? (192.168.64.7) at aa:bb:cc:dd:ee:01 on bridge100 ifscope [ethernet]\n? (192.168.64.8) at aa:bb:cc:dd:ee:02 on bridge100 ifscope [ethernet]\n' > "$CLAWBOX_TEST_ARP_OUTPUT_FILE"

  CLAWBOX_TEST_SSH_STDERR='ssh: connect to host 192.168.64.7 port 22: No route to host'
  probe_ssh_target_endpoint 'vm-user@192.168.64.7' >/dev/null 2>&1 || true

  VM_IP='192.168.64.6'
  VM_HOST='vm-user@192.168.64.6'

  probe_ssh_target_endpoint() {
    if [ "$1" = 'vm-user@192.168.64.8' ]; then
      REPLY='ssh-auth-required'
    else
      REPLY='unreachable'
    fi
    return 0
  }

  if discover_vm_ip_candidates; then
    pass 'vm ip discovery excludes addresses already proven unreachable in this onboarding run'
  else
    fail 'vm ip discovery should exclude addresses already proven unreachable in this onboarding run'
  fi

  assert_equals 'vm ip discovery does not re-add the previously unreachable vm ip address' "$REPLY" '192.168.64.8'
}

test_wait_for_vm_network_succeeds_within_network_specific_budget() {
  local probe_attempts=0

  prepare_vm_state_mocks

  load_setup_functions

  sleep() {
    return 0
  }

  probe_vm_network_endpoint() {
    probe_attempts=$((probe_attempts + 1))

    if [ "$probe_attempts" -lt 10 ]; then
      REPLY='unreachable'
    else
      REPLY='ssh-auth-required'
    fi

    return 0
  }

  if wait_for_vm_network; then
    pass 'wait_for_vm_network succeeds when readiness appears within the dedicated network budget'
  else
    fail 'wait_for_vm_network should succeed when readiness appears within the dedicated network budget'
  fi

  assert_equals 'wait_for_vm_network returns the readiness probe state after a delayed success' "$REPLY" 'ssh-auth-required'
  assert_equals 'wait_for_vm_network remains bounded to the dedicated network poll window' "$probe_attempts" '10'
}

test_wait_for_vm_network_uses_bounded_tcp_probe_timing() {
  local elapsed_ms=0
  local probe_calls=0
  local probe_args=''

  prepare_vm_state_mocks

  write_mock_command perl '#!/bin/bash
host_arg="${@: -2:1}"
timeout_arg="${@: -1}"
printf "%s %s\n" "$host_arg" "$timeout_arg" >> "$CLAWBOX_TEST_NETWORK_PROBE_ARGS_FILE"
sleep "${CLAWBOX_TEST_NETWORK_PROBE_DELAY:-0}"
printf "%s\n" "${CLAWBOX_TEST_NETWORK_PROBE_STDERR:-timed out}" >&2
exit "${CLAWBOX_TEST_NETWORK_PROBE_EXIT_CODE:-1}"'

  CLAWBOX_TEST_NETWORK_PROBE_ARGS_FILE="$TEMP_DIR/network-probe-args.txt"
  CLAWBOX_TEST_NETWORK_PROBE_DELAY='0.05'
  CLAWBOX_TEST_NETWORK_PROBE_STDERR='timed out'
  CLAWBOX_TEST_NETWORK_PROBE_EXIT_CODE=1
  export CLAWBOX_TEST_NETWORK_PROBE_ARGS_FILE CLAWBOX_TEST_NETWORK_PROBE_DELAY CLAWBOX_TEST_NETWORK_PROBE_STDERR CLAWBOX_TEST_NETWORK_PROBE_EXIT_CODE

  load_setup_functions

  VM_HOST='vm-user@192.168.64.2'
  CLAWBOX_VM_NETWORK_WAIT_MAX_ATTEMPTS=4
  CLAWBOX_VM_NETWORK_WAIT_INTERVAL_SECONDS=0
  CLAWBOX_VM_NETWORK_CONNECT_TIMEOUT='0.05'
  export CLAWBOX_VM_NETWORK_WAIT_MAX_ATTEMPTS CLAWBOX_VM_NETWORK_WAIT_INTERVAL_SECONDS CLAWBOX_VM_NETWORK_CONNECT_TIMEOUT

  if time_command_ms elapsed_ms wait_for_vm_network; then
    fail 'wait_for_vm_network should time out when the bounded TCP probe never connects'
  else
    pass 'wait_for_vm_network fails when the bounded TCP probe never connects'
  fi

  probe_calls="$(grep -F -c '192.168.64.2 0.05' "$CLAWBOX_TEST_NETWORK_PROBE_ARGS_FILE")"
  probe_args="$(cat "$CLAWBOX_TEST_NETWORK_PROBE_ARGS_FILE")"

  assert_equals 'wait_for_vm_network completes the full configured bounded window before failing' "$probe_calls" '4'
  assert_contains 'wait_for_vm_network passes the configured network probe timeout to the TCP probe' "$probe_args" '192.168.64.2 0.05'
  assert_equals 'wait_for_vm_network reports network timeout after exhausting the bounded TCP probe budget' "$REPLY" 'ssh-timeout'
  assert_duration_under_ms 'wait_for_vm_network cadence is not dominated by the older multi-second SSH probe timeout' "$elapsed_ms" '500'
}

test_vm_onboarding_wait_defaults_increase_spinner_cadence() {
  prepare_vm_state_mocks

  unset CLAWBOX_VM_WAIT_INTERVAL_SECONDS
  unset CLAWBOX_VM_NETWORK_WAIT_INTERVAL_SECONDS
  unset CLAWBOX_VM_RUNTIME_WAIT_MAX_ATTEMPTS
  unset CLAWBOX_VM_NETWORK_WAIT_MAX_ATTEMPTS
  unset CLAWBOX_VM_SSH_WAIT_MAX_ATTEMPTS

  load_setup_functions

  assert_equals 'vm wait interval defaults to the faster redraw cadence' "$(vm_onboarding_wait_interval)" '0.075'
  assert_equals 'vm network wait interval uses the dedicated two-second poll cadence' "$(vm_network_wait_interval)" '2'
  assert_equals 'vm runtime wait keeps the existing total bounded window' "$(vm_runtime_wait_max_attempts)" '267'
  assert_equals 'vm network wait keeps a dedicated 30-second bounded window' "$(vm_network_wait_max_attempts)" '15'
  assert_equals 'vm ssh wait keeps the existing total bounded window' "$(vm_ssh_wait_max_attempts)" '200'
}

test_wait_for_known_vm_ssh_readiness_distinguishes_network_ready_from_ssh_auth_failure() {
  prepare_vm_state_mocks

  load_setup_functions

  wait_for_vm_network() {
    REPLY='ready'
    return 0
  }

  wait_for_vm_ssh_service() {
    REPLY='ssh-auth-required'
    return 0
  }

  if wait_for_known_vm_ssh_readiness; then
    fail 'known vm ssh readiness should not report ready when ssh requires authentication'
  else
    pass 'known vm ssh readiness keeps network-ready separate from ssh auth-required state'
  fi

  assert_equals 'known vm ssh readiness reports ssh-auth-required after network readiness succeeds' "$REPLY" 'ssh-auth-required'
}

test_ensure_vm_connectivity_does_not_repeat_boot_wait_after_failed_startup_readiness() {
  local detect_calls=0
  local readiness_wait_calls=0

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' '4'

  detect_vm_state() {
    detect_calls=$((detect_calls + 1))

    if [ "$detect_calls" -eq 1 ]; then
      REPLY='stopped'
      VM_RUNNING_STATE_CONFIDENCE='unknown'
    else
      REPLY='booting'
      VM_RUNNING_STATE_CONFIDENCE='exact'
    fi

    return 0
  }

  start_vm_with_utm() {
    return 0
  }

  wait_for_vm_running() {
    return 0
  }

  wait_for_known_vm_ssh_readiness() {
    readiness_wait_calls=$((readiness_wait_calls + 1))
    REPLY='ssh-timeout'
    return 1
  }

  probe_vm_ssh_endpoint() {
    REPLY='ssh-timeout'
    return 0
  }

  ensure_vm_connectivity_or_repair || true

  assert_equals 'connectivity repair does not repeat the boot readiness wait after a failed startup wait' "$readiness_wait_calls" '1'
}

test_ensure_vm_connectivity_classifies_network_stage_failure_once() {
  local detect_calls=0
  local output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y'

  detect_vm_state() {
    detect_calls=$((detect_calls + 1))

    if [ "$detect_calls" -eq 1 ]; then
      REPLY='stopped'
      VM_RUNNING_STATE_CONFIDENCE='unknown'
    else
      REPLY='booting'
      VM_RUNNING_STATE_CONFIDENCE='exact'
    fi

    return 0
  }

  start_vm_with_utm() {
    return 0
  }

  wait_for_vm_running() {
    return 0
  }

  CLAWBOX_VM_NETWORK_WAIT_MAX_ATTEMPTS=2
  CLAWBOX_VM_WAIT_INTERVAL_SECONDS=0
  export CLAWBOX_VM_NETWORK_WAIT_MAX_ATTEMPTS CLAWBOX_VM_WAIT_INTERVAL_SECONDS

  probe_vm_network_endpoint() {
    REPLY='ssh-timeout'
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'network-stage failure reports the network classification' "$output" 'VM network was not detected within the expected time window.'
  assert_not_contains 'network-stage failure does not fall through to ssh timeout wording' "$output" 'VM is booting or running, but SSH timed out.'
  assert_not_contains 'network-stage failure does not offer ssh bootstrap' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
}

test_startup_network_timeout_offers_bounded_recovery() {
  local detect_calls=0
  local output
  local network_attempt_file

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' '2' '192.168.64.9'
  network_attempt_file="$TEMP_DIR/startup-recovery-network-attempts.txt"
  : > "$network_attempt_file"

  detect_vm_state() {
    detect_calls=$((detect_calls + 1))

    if [ "$detect_calls" -eq 1 ]; then
      REPLY='stopped'
      VM_RUNNING_STATE_CONFIDENCE='unknown'
    else
      REPLY='booting'
      VM_RUNNING_STATE_CONFIDENCE='exact'
    fi

    return 0
  }

  start_vm_with_utm() {
    return 0
  }

  wait_for_vm_running() {
    return 0
  }

  wait_for_vm_network() {
    local attempt_count

    printf 'attempt\n' >> "$network_attempt_file"
    attempt_count="$(wc -l < "$network_attempt_file" | tr -d '[:space:]')"

    status_begin 'Waiting for VM network...'
    status_tick 'Waiting for VM network...'

    if [ "$attempt_count" -eq 1 ]; then
      REPLY='ssh-timeout'
      status_end 'VM network was not detected within the expected time window.'
      return 1
    fi

    REPLY='ssh-auth-required'
    status_end 'VM network detected.'
    return 0
  }

  wait_for_vm_ssh_after_network_ready() {
    REPLY='ssh-refused'
    return 1
  }

  attempt_ssh_access_bootstrap() {
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  assert_contains 'startup recovery flow reports the bounded network timeout' "$output" 'VM network was not detected within the expected time window.'
  assert_contains 'startup recovery flow offers network retry first' "$output" '1) Retry VM network detection'
  assert_contains 'startup recovery flow offers manual ip replacement second' "$output" '2) Enter a different IP address'
  assert_contains 'startup recovery flow offers vm ip discovery' "$output" '3) Attempt VM IP discovery'
  assert_contains 'startup recovery flow offers continue waiting fourth' "$output" '4) Continue waiting'
  assert_contains 'startup recovery flow offers abort fifth' "$output" '5) Abort setup'
  assert_not_contains 'startup recovery flow accepts manual ip input without invalid-selection churn' "$output" 'Invalid selection. Enter a number between 1 and 5.'
  assert_equals 'startup recovery flow retries only within the bounded recovery menu' "$(wc -l < "$network_attempt_file" | tr -d '[:space:]')" '1'
  assert_contains 'startup recovery flow continues into ssh refusal onboarding after manual ip replacement' "$output" 'Using entered VM address: 192.168.64.9'
  assert_contains 'startup recovery flow reaches the ssh refusal prompt after manual ip replacement' "$output" 'Is Remote Login now enabled? [Y/n]:'
  assert_contains 'startup recovery flow keeps recovery output visually separated' "$output" 'VM network was not detected within the expected time window.'
}

test_startup_network_timeout_recovery_stays_bounded() {
  local detect_calls=0
  local output
  local network_attempt_file

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' '4' '4'
  network_attempt_file="$TEMP_DIR/startup-recovery-bounded-attempts.txt"
  : > "$network_attempt_file"

  detect_vm_state() {
    detect_calls=$((detect_calls + 1))

    if [ "$detect_calls" -eq 1 ]; then
      REPLY='stopped'
      VM_RUNNING_STATE_CONFIDENCE='unknown'
    else
      REPLY='booting'
      VM_RUNNING_STATE_CONFIDENCE='exact'
    fi

    return 0
  }

  start_vm_with_utm() {
    return 0
  }

  wait_for_vm_running() {
    return 0
  }

  wait_for_vm_network() {
    printf 'attempt\n' >> "$network_attempt_file"
    status_begin 'Waiting for VM network...'
    status_tick 'Waiting for VM network...'
    REPLY='ssh-timeout'
    status_end 'VM network was not detected within the expected time window.'
    return 1
  }

  CLAWBOX_VM_STARTUP_RECOVERY_MAX_ATTEMPTS=2
  export CLAWBOX_VM_STARTUP_RECOVERY_MAX_ATTEMPTS

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"

  if [ "$(wc -l < "$network_attempt_file" | tr -d '[:space:]')" -le 3 ]; then
    pass 'startup recovery flow remains bounded after repeated continue waiting choices'
  else
    fail 'startup recovery flow remains bounded after repeated continue waiting choices'
  fi

  if [ "$(printf '%s' "$output" | grep -F -c 'VM network was not detected within the expected time window.')" -le 3 ]; then
    pass 'startup recovery flow emits one timeout result per bounded attempt'
  else
    fail 'startup recovery flow emits one timeout result per bounded attempt'
  fi
  assert_not_contains 'startup recovery flow does not offer ssh bootstrap after exhausting the bounded recovery menu' "$output" 'Attempt to configure SSH access automatically? [Y/n]:'
}

test_recovered_vm_ip_transitions_directly_to_ssh_stage() {
  local detect_calls=0
  local output
  local network_wait_file
  local post_recovery_output

  prepare_vm_state_mocks

  load_setup_functions
  install_prompt_stubs
  queue_prompt_answers 'y' '3' 'n'
  network_wait_file="$TEMP_DIR/recovered-ip-network-waits.txt"
  : > "$network_wait_file"

  detect_vm_state() {
    detect_calls=$((detect_calls + 1))

    if [ "$detect_calls" -eq 1 ]; then
      REPLY='stopped'
      VM_RUNNING_STATE_CONFIDENCE='unknown'
    else
      REPLY='booting'
      VM_RUNNING_STATE_CONFIDENCE='exact'
    fi

    return 0
  }

  start_vm_with_utm() {
    return 0
  }

  wait_for_vm_running() {
    return 0
  }

  wait_for_vm_network() {
    local attempt_count

    printf 'attempt\n' >> "$network_wait_file"
    attempt_count="$(wc -l < "$network_wait_file" | tr -d '[:space:]')"

    if [ "$attempt_count" -eq 1 ]; then
      REPLY='ssh-timeout'
      return 1
    fi

    fail 'recovered vm ip flow should not return to vm network polling after ip recovery'
    REPLY='ssh-timeout'
    return 1
  }

  offer_vm_ip_recovery() {
    update_vm_ip_selection '192.168.64.6'
    success 'Using detected VM address: 192.168.64.6'
    return 0
  }

  probe_vm_ssh_endpoint() {
    if [ "$VM_HOST" = 'vm-user@192.168.64.6' ]; then
      REPLY='ssh-refused'
    else
      REPLY='ssh-timeout'
    fi
    return 0
  }

  output="$({ ensure_vm_connectivity_or_repair || true; } 2>&1)"
  post_recovery_output="${output#*Using detected VM address: 192.168.64.6}"

  assert_equals 'recovered vm ip flow only uses vm network polling for the initial pre-recovery timeout' "$(wc -l < "$network_wait_file" | tr -d '[:space:]')" '1'
  assert_contains 'recovered vm ip flow keeps the recovered ip selection' "$output" 'Using detected VM address: 192.168.64.6'
  assert_contains 'recovered vm ip flow transitions directly into ssh refusal onboarding' "$output" 'Is Remote Login now enabled? [Y/n]:'
  assert_not_contains 'recovered vm ip flow does not print a second vm network wait after ip recovery' "$post_recovery_output" 'Waiting for VM network...'
}

test_discover_vm_ip_candidates_prefers_utmctl_guest_ip_metadata() {
  prepare_vm_state_mocks

  load_setup_functions

  VM_MACHINE_NAME='Shared VM'
  VM_USER='vm-user'
  VM_IP='192.168.64.7'
  printf '192.168.64.9\nfe80::1\n' > "$CLAWBOX_TEST_UTMCTL_IP_FILE"

  probe_ssh_target_endpoint() {
    if [ "$1" = 'vm-user@192.168.64.9' ]; then
      REPLY='ssh-auth-required'
    else
      REPLY='unreachable'
    fi
    return 0
  }

  if discover_vm_ip_candidates; then
    pass 'vm ip discovery can use utmctl guest IP metadata before subnet heuristics'
  else
    fail 'vm ip discovery should use utmctl guest IP metadata before subnet heuristics'
  fi

  assert_equals 'utmctl guest IP discovery returns the authoritative IPv4 address first' "$REPLY" '192.168.64.9'
}

printf 'Running VM state tests\n'

test_setup_vm_is_running_uses_resolved_utmctl
test_start_vm_uses_selected_vm_name_with_utmctl
test_selected_detected_vm_name_reaches_startup_path
test_start_vm_falls_back_to_applescript_after_utmctl_failure
test_start_vm_reports_each_failed_start_method
test_start_vm_reports_tcc_only_for_automation_denial
test_start_vm_does_not_misclassify_non_tcc_applescript_failure
test_start_vm_not_found_prints_utmctl_registered_identities
test_utm_package_discovery_uses_internal_display_name
test_detected_vm_selection_retains_package_path
test_start_vm_opens_package_path_after_identity_methods_fail
test_start_vm_tcc_denial_opens_package_for_manual_start
test_start_vm_skips_package_fallback_when_path_is_unknown
test_tcc_blocked_startup_can_continue_into_existing_readiness_flow
test_manual_utm_start_reprompts_when_runtime_is_not_detected
test_manual_utm_start_abort_never_enters_network_readiness
test_non_tcc_startup_failure_does_not_offer_manual_continuation
test_detect_vm_state_uses_cross_user_virtualization_fallback
test_detect_vm_state_distinguishes_running_from_stopped
test_detect_vm_state_does_not_treat_open_utm_app_as_running
test_ensure_vm_connectivity_reports_running_without_ssh
test_ensure_vm_connectivity_fails_fast_for_invalid_target
test_ensure_vm_connectivity_distinguishes_ssh_timeout_for_running_vm
test_ensure_vm_connectivity_distinguishes_ssh_refusal
test_ensure_vm_connectivity_classifies_missing_key_auth_without_failure_framing
test_ensure_vm_connectivity_skips_bootstrap_when_key_auth_is_ready
test_ensure_vm_connectivity_emits_single_ssh_bootstrap_success_line
test_ensure_vm_connectivity_retries_ssh_after_remote_login_confirmation
test_remote_login_confirmation_allows_one_bounded_refusal_retry
test_remote_login_retry_hostkey_failure_prints_known_hosts_remediation
test_ssh_classifier_distinguishes_first_contact_from_changed_host_key
test_first_contact_host_key_guidance_retries_without_manual_setup_dump
test_accept_new_host_key_uses_bounded_safe_ssh_options
test_vm_ssh_classifier_helper_is_available_for_vm_repair
test_ensure_vm_connectivity_ssh_refusal_path_does_not_emit_missing_classifier_errors
test_ensure_vm_connectivity_recovers_vm_ip_after_startup
test_wait_for_vm_network_succeeds_within_network_specific_budget
test_ensure_vm_connectivity_treats_batch_auth_success_as_ready
test_classify_vm_ssh_connectivity_promotes_auth_required_when_batch_auth_succeeds
test_copy_ssh_key_to_vm_treats_all_keys_skipped_as_success_when_auth_works
test_copy_ssh_key_to_vm_keeps_failure_when_all_keys_skipped_but_auth_fails
test_ensure_vm_connectivity_does_not_repeat_boot_wait_after_failed_startup_readiness
test_ensure_vm_connectivity_classifies_network_stage_failure_once
test_startup_network_timeout_offers_bounded_recovery
test_startup_network_timeout_recovery_stays_bounded
test_recovered_vm_ip_transitions_directly_to_ssh_stage
test_wait_for_vm_network_uses_bounded_tcp_probe_timing
test_vm_onboarding_wait_defaults_increase_spinner_cadence
test_wait_for_known_vm_ssh_readiness_distinguishes_network_ready_from_ssh_auth_failure
test_discover_vm_ip_candidates_prefers_utmctl_guest_ip_metadata
test_discover_vm_ip_candidates_excludes_ips_already_proven_unreachable

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
