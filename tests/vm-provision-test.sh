#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=/dev/null
. "$ROOT_DIR/tests/helpers/setup-harness.sh"

trap cleanup_temp_dir EXIT

TEMP_DIR="$(mktemp -d)"
VM_PROVISION_LAST_OUTPUT=''
VM_PROVISION_LAST_STATUS=0

setup_vm_provision_fixture() {
  local fixture_root="$TEMP_DIR/vm-provision-fixture"
  local script_path="$fixture_root/vm/vm-provision.sh"

  rm -rf "$fixture_root"
  mkdir -p "$fixture_root/vm" "$fixture_root/opt/homebrew/bin" "$fixture_root/opt/homebrew/opt/node@22/bin"

  cp "$ROOT_DIR/vm/vm-provision.sh" "$script_path"
  chmod +x "$script_path"

  sed -i '' \
    -e "s|BREW_BIN=\"/opt/homebrew/bin/brew\"|BREW_BIN=\"$fixture_root/opt/homebrew/bin/brew\"|" \
    -e "s|VM_AUTOMATION_PATH=\"/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin\"|VM_AUTOMATION_PATH=\"$fixture_root/opt/homebrew/bin:$fixture_root/opt/homebrew/sbin:$fixture_root/opt/homebrew/opt/node@22/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
    -e "s|\"/opt/homebrew/opt/node@22/bin/node\"|\"$fixture_root/opt/homebrew/opt/node@22/bin/node\"|" \
    -e "s|\"/opt/homebrew/bin/node\"|\"$fixture_root/opt/homebrew/bin/node\"|" \
    -e "s|\"/opt/homebrew/bin/openclaw\"|\"$fixture_root/opt/homebrew/bin/openclaw\"|" \
    "$script_path"

  cat > "$fixture_root/opt/homebrew/bin/brew" <<EOF
#!/bin/bash
case "\$1" in
  shellenv)
    printf ':'
    ;;
  list)
    exit 0
    ;;
  install)
    exit 0
    ;;
  link)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$fixture_root/opt/homebrew/bin/brew"

  cat > "$fixture_root/opt/homebrew/opt/node@22/bin/node" <<'EOF'
#!/bin/bash
if [ "${1:-}" = '-v' ]; then
  printf 'v22.0.0\n'
  exit 0
fi
exit 0
EOF
  chmod +x "$fixture_root/opt/homebrew/opt/node@22/bin/node"

  cat > "$fixture_root/opt/homebrew/bin/openclaw" <<'EOF'
#!/bin/bash
if [ "${1:-}" = '--version' ]; then
  printf 'openclaw 1.0.0\n'
  exit 0
fi

if [ "${1:-}" = 'gateway' ]; then
  printf 'gateway started\n'
  exit 0
fi

exit 0
EOF
  chmod +x "$fixture_root/opt/homebrew/bin/openclaw"

  REPLY="$fixture_root"
}

setup_vm_provision_mocks() {
  setup_mock_bin_dir

  write_mock_command curl '#!/bin/bash
exit 0
'

  write_mock_command npm '#!/bin/bash
if [ "${1:-}" = "list" ]; then
  exit 0
fi

if [ "${1:-}" = "install" ]; then
  exit 0
fi

exit 0
'
}

run_vm_provision() {
  local fixture_root="$1"
  local home_dir="$2"
  local stdin_input="${3:-}"
  local skip_gateway="${4:-false}"
  local path_prefix="$MOCK_BIN_DIR:$fixture_root/opt/homebrew/bin:$fixture_root/opt/homebrew/opt/node@22/bin:$ORIGINAL_PATH"

  if [ -n "$stdin_input" ]; then
    set +e
    VM_PROVISION_LAST_OUTPUT="$(HOME="$home_dir" PATH="$path_prefix" CLAWBOX_SKIP_GATEWAY_PROMPT="$skip_gateway" /bin/bash "$fixture_root/vm/vm-provision.sh" <<< "$stdin_input" 2>&1)"
    VM_PROVISION_LAST_STATUS=$?
    set -e
    return
  fi

  set +e
  VM_PROVISION_LAST_OUTPUT="$(HOME="$home_dir" PATH="$path_prefix" CLAWBOX_SKIP_GATEWAY_PROMPT="$skip_gateway" /bin/bash "$fixture_root/vm/vm-provision.sh" 2>&1)"
  VM_PROVISION_LAST_STATUS=$?
  set -e
}

test_vm_provision_copies_config_and_skips_gateway_prompt_when_requested() {
  local fixture_root
  local home_dir="$TEMP_DIR/home-copy"
  local target_config="$home_dir/.openclaw/openclaw.json"
  local shellenv_count
  local node_path_count

  setup_vm_provision_fixture
  fixture_root="$REPLY"
  setup_vm_provision_mocks

  mkdir -p "$home_dir"

  cat > "$fixture_root/vm/openclaw.json" <<'EOF'
{"gateway":{"mode":"local"}}
EOF

  run_vm_provision "$fixture_root" "$home_dir" '' true

  assert_equals 'vm provision succeeds when gateway prompt is skipped' "$VM_PROVISION_LAST_STATUS" '0'
  assert_contains 'vm provision creates .zprofile when missing' "$VM_PROVISION_LAST_OUTPUT" "Created $home_dir/.zprofile"
  assert_contains 'vm provision copies the OpenClaw config when it is missing' "$VM_PROVISION_LAST_OUTPUT" "Copied OpenClaw config to $target_config"
  assert_contains 'vm provision reports host setup continuation when gateway prompt is skipped' "$VM_PROVISION_LAST_OUTPUT" 'Host setup will continue with runtime configuration.'

  if cmp -s "$fixture_root/vm/openclaw.json" "$target_config"; then
    pass 'vm provision copies the exact OpenClaw config contents'
  else
    fail 'vm provision should copy the exact OpenClaw config contents'
  fi

  shellenv_count="$(/usr/bin/grep -Fxc 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$home_dir/.zprofile")"
  node_path_count="$(/usr/bin/grep -Fxc 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' "$home_dir/.zprofile")"
  assert_equals 'vm provision writes one Homebrew shellenv line' "$shellenv_count" '1'
  assert_equals 'vm provision writes one Node PATH line' "$node_path_count" '1'
}

test_vm_provision_deduplicates_zprofile_entries() {
  local fixture_root
  local home_dir="$TEMP_DIR/home-dedup"
  local shellenv_count
  local node_path_count

  setup_vm_provision_fixture
  fixture_root="$REPLY"
  setup_vm_provision_mocks

  mkdir -p "$home_dir"
  cat > "$home_dir/.zprofile" <<'EOF'
eval "$(/opt/homebrew/bin/brew shellenv)"
eval "$(/opt/homebrew/bin/brew shellenv)"
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
EOF

  run_vm_provision "$fixture_root" "$home_dir" '' true

  assert_equals 'vm provision succeeds when deduplicating .zprofile entries' "$VM_PROVISION_LAST_STATUS" '0'
  assert_contains 'vm provision reports Homebrew shellenv deduplication' "$VM_PROVISION_LAST_OUTPUT" "Removed duplicate Homebrew shellenv line entries and kept one in $home_dir/.zprofile"
  assert_contains 'vm provision reports Node PATH deduplication' "$VM_PROVISION_LAST_OUTPUT" "Removed duplicate Node PATH line entries and kept one in $home_dir/.zprofile"

  shellenv_count="$(/usr/bin/grep -Fxc 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$home_dir/.zprofile")"
  node_path_count="$(/usr/bin/grep -Fxc 'export PATH="/opt/homebrew/opt/node@22/bin:$PATH"' "$home_dir/.zprofile")"
  assert_equals 'vm provision keeps one Homebrew shellenv line after deduplication' "$shellenv_count" '1'
  assert_equals 'vm provision keeps one Node PATH line after deduplication' "$node_path_count" '1'
}

test_vm_provision_prints_next_step_when_gateway_start_is_declined() {
  local fixture_root
  local home_dir="$TEMP_DIR/home-decline"

  setup_vm_provision_fixture
  fixture_root="$REPLY"
  setup_vm_provision_mocks

  mkdir -p "$home_dir"

  run_vm_provision "$fixture_root" "$home_dir" 'n'

  assert_equals 'vm provision succeeds when gateway start is declined' "$VM_PROVISION_LAST_STATUS" '0'
  assert_contains 'vm provision prints the next-step banner after declining gateway start' "$VM_PROVISION_LAST_OUTPUT" 'Next step:'
  assert_contains 'vm provision prints the runtime directory next step' "$VM_PROVISION_LAST_OUTPUT" "  cd $fixture_root/vm"
  assert_contains 'vm provision prints the gateway command next step' "$VM_PROVISION_LAST_OUTPUT" "  $fixture_root/opt/homebrew/bin/openclaw gateway"
  assert_not_contains 'vm provision does not start the gateway after declining' "$VM_PROVISION_LAST_OUTPUT" 'Starting OpenClaw gateway in the current terminal...'
}

test_vm_provision_starts_gateway_when_prompt_is_accepted() {
  local fixture_root
  local home_dir="$TEMP_DIR/home-accept"

  setup_vm_provision_fixture
  fixture_root="$REPLY"
  setup_vm_provision_mocks

  mkdir -p "$home_dir"

  run_vm_provision "$fixture_root" "$home_dir" 'y'

  assert_equals 'vm provision succeeds when gateway start is accepted' "$VM_PROVISION_LAST_STATUS" '0'
  assert_contains 'vm provision prints the gateway start banner when accepted' "$VM_PROVISION_LAST_OUTPUT" 'Starting OpenClaw gateway in the current terminal...'
  assert_contains 'vm provision executes the gateway command when accepted' "$VM_PROVISION_LAST_OUTPUT" 'gateway started'
  assert_not_contains 'vm provision does not fall back to next-step instructions after starting the gateway' "$VM_PROVISION_LAST_OUTPUT" 'Next step:'
}

printf 'Running vm provision tests\n'

run_test test_vm_provision_copies_config_and_skips_gateway_prompt_when_requested
run_test test_vm_provision_deduplicates_zprofile_entries
run_test test_vm_provision_prints_next_step_when_gateway_start_is_declined
run_test test_vm_provision_starts_gateway_when_prompt_is_accepted

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1