#!/bin/bash
set -euo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/.." && pwd)/tests/helpers/setup-harness.sh"

trap cleanup_temp_dir EXIT

TEMP_DIR="$(mktemp -d)"

prepare_vm_detection_mocks() {
  local utmctl_output_file="$TEMP_DIR/utmctl-list.txt"
  local process_output_file="$TEMP_DIR/process-list.txt"

  setup_mock_bin_dir

  write_mock_command utmctl '#!/bin/bash
if [ "$1" = "list" ]; then
  cat "$CLAWBOX_TEST_UTMCTL_LIST_FILE"
fi'

  write_mock_command ps '#!/bin/bash
cat "$CLAWBOX_TEST_PROCESS_LIST_FILE"'

  write_mock_command ssh '#!/bin/bash
exit "${CLAWBOX_TEST_SSH_EXIT_CODE:-255}"'

  CLAWBOX_UTMCTL_BIN="$MOCK_BIN_DIR/utmctl"
  CLAWBOX_PS_BIN="$MOCK_BIN_DIR/ps"
  CLAWBOX_TEST_UTMCTL_LIST_FILE="$utmctl_output_file"
  CLAWBOX_TEST_PROCESS_LIST_FILE="$process_output_file"
  CLAWBOX_TEST_SSH_EXIT_CODE=255
  export CLAWBOX_UTMCTL_BIN CLAWBOX_PS_BIN CLAWBOX_TEST_UTMCTL_LIST_FILE CLAWBOX_TEST_PROCESS_LIST_FILE CLAWBOX_TEST_SSH_EXIT_CODE
}

test_detected_vm_selection_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers 'y'

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    list_detected_utm_vm_names() {
      printf 'ReadyVM\n'
    }

    VM_MACHINE_NAME=''
    if ensure_vm_platform_ready; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
    printf 'VM_MACHINE_NAME:%s\n' "$VM_MACHINE_NAME"
  } 2>&1)"

  assert_contains 'detected vm flow succeeds' "$output" 'STATUS:0'
  assert_contains 'detected vm flow keeps automatic detection ux' "$output" 'Detected existing UTM VM:'
  assert_contains 'detected vm flow stores selected vm name' "$output" 'VM_MACHINE_NAME:ReadyVM'
}

test_vm_detection_permission_block_graceful_exit_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers '1'
    FDA_OPEN_ATTEMPTS=0
    HOME="$TEMP_DIR/permission-block-home"
    mkdir -p "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    ls() {
      return 1
    }

    open_full_disk_access_settings() {
      FDA_OPEN_ATTEMPTS=$((FDA_OPEN_ATTEMPTS + 1))
      return 0
    }

    if ensure_vm_platform_ready; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
    printf 'FDA_OPEN_ATTEMPTS:%s\n' "$FDA_OPEN_ATTEMPTS"
  } 2>&1)"

  assert_contains 'permission block flow shows vm detection section' "$output" ' > VM Detection'
  assert_contains 'permission block flow explains privacy block' "$output" 'UTM access is blocked by macOS privacy settings.'
  assert_contains 'permission block flow explains why guided detection cannot continue' "$output" 'ClawBox cannot continue with guided VM detection until macOS allows access to the UTM VM directory.'
  assert_contains 'permission block flow identifies the app that needs access' "$output" 'Grant Full Disk Access to the app running setup (Terminal, iTerm, or Visual Studio Code).'
  assert_contains 'permission block flow repeats the exact settings path' "$output" 'System Settings > Privacy & Security > Full Disk Access'
  assert_contains 'permission block flow attempts to open settings' "$output" 'Attempting to open the Full Disk Access settings pane...'
  assert_contains 'permission block flow tells the user what to do next' "$output" 'After granting Full Disk Access, re-run setup.'
  assert_contains 'permission block flow exits gracefully' "$output" 'STATUS:42'
  assert_contains 'permission block flow calls the settings opener once' "$output" 'FDA_OPEN_ATTEMPTS:1'
  assert_not_contains 'permission block flow skips vm platform checklist' "$output" 'macOS guest VMs ❌'
  assert_not_contains 'permission block flow skips onboarding steps' "$output" 'Next steps:'
}

test_vm_detection_permission_block_manual_fallback_flow() {
  local output

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers '2' 'Manual VM'
    HOME="$TEMP_DIR/permission-block-manual-home"
    mkdir -p "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    ls() {
      return 1
    }

    if ensure_vm_platform_ready; then
      status=0
    else
      status=$?
    fi
    printf 'STATUS:%s\n' "$status"
    resolve_vm_machine_name_value '' 'FallbackVM'
    printf 'VM_MACHINE_NAME:%s\n' "$REPLY"
  } 2>&1)"

  assert_contains 'permission block manual flow returns success' "$output" 'STATUS:0'
  assert_contains 'permission block manual flow uses manual vm prompt' "$output" 'Enter VM name [FallbackVM]:'
  assert_contains 'permission block manual flow returns manual vm name' "$output" 'VM_MACHINE_NAME:Manual VM'
  assert_not_contains 'permission block manual flow skips automatic vm discovery ux' "$output" 'Detected UTM VMs:'
  assert_not_contains 'permission block manual flow skips onboarding steps' "$output" 'Next steps:'
}

test_manual_vm_configuration_uses_running_vm_repair_flow() {
  local output

  prepare_vm_detection_mocks
  printf 'usera 4242 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine\n' > "$CLAWBOX_TEST_PROCESS_LIST_FILE"
  : > "$CLAWBOX_TEST_UTMCTL_LIST_FILE"

  output="$({
    load_setup_functions
    install_prompt_stubs

    queue_prompt_answers '2' 'Shared VM' 'n'
    HOME="$TEMP_DIR/manual-vm-home"
    mkdir -p "$HOME/Library/Containers/com.utmapp.UTM/Data/Documents"

    uname() {
      printf 'arm64\n'
    }

    function [ {
      if test "$#" -eq 3 && test "$1" = '-d' && test "$2" = '/Applications/UTM.app' && test "$3" = ']'; then
        return 0
      fi

      if test "$#" -gt 0 && test "${!#}" = ']'; then
        set -- "${@:1:$(($# - 1))}"
      fi

      builtin test "$@"
    }

    ls() {
      return 1
    }

    if ensure_vm_platform_ready; then
      status=0
    else
      status=$?
    fi
    printf 'PLATFORM_STATUS:%s\n' "$status"

    resolve_vm_machine_name_value '' 'FallbackVM'
    VM_MACHINE_NAME="$REPLY"
    VM_HOST='vm-user@192.168.64.2'

    ensure_vm_connectivity_or_repair || true
  } 2>&1)"

  assert_contains 'manual vm path completes vm detection stage' "$output" 'PLATFORM_STATUS:0'
  assert_contains 'manual vm path keeps the selected vm name for later detection' "$output" 'Enter VM name [FallbackVM]:'
  assert_contains 'manual vm path reports unconfirmed vm identity instead of claiming the target is already running' "$output" 'A virtualization process is running on this Mac, but ClawBox could not confirm that it matches the configured VM.'
  assert_not_contains 'manual vm path does not use the unsupported probable-running wording' "$output" 'VM appears to already be running but is not yet reachable via SSH.'
  assert_not_contains 'manual vm path does not claim the vm is stopped in the cross-user scenario' "$output" 'VM is not running.'
  assert_not_contains 'manual vm path does not attempt startup in the cross-user scenario' "$output" 'Start the VM now?'
  assert_not_contains 'manual vm path does not report failed startup in the cross-user scenario' "$output" 'Failed to start VM.'
}

printf 'Running VM detection tests\n'

run_test test_detected_vm_selection_flow
run_test test_vm_detection_permission_block_graceful_exit_flow
run_test test_vm_detection_permission_block_manual_fallback_flow
run_test test_manual_vm_configuration_uses_running_vm_repair_flow

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
