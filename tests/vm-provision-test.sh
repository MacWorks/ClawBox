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
  cp -R "$ROOT_DIR/vm/qualification" "$fixture_root/vm/qualification"
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
if [ "${1:-}" = '-' ]; then
  cat >/dev/null
  printf 'fixture-checksum'
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
  assert_contains 'vm provision installs qualification suite' "$VM_PROVISION_LAST_OUTPUT" "Installed qualification suite at $home_dir/.openclaw/workspace/.clawbox/qualification"
  assert_contains 'vm provision reports return-to-host ownership boundary' "$VM_PROVISION_LAST_OUTPUT" 'Return to the ClawBox setup process on the host to finish configuration and start OpenClaw.'
  assert_not_contains 'vm provision does not prompt to start OpenClaw' "$VM_PROVISION_LAST_OUTPUT" 'Start OpenClaw gateway now?'
  assert_not_contains 'vm provision does not print a manual gateway command' "$VM_PROVISION_LAST_OUTPUT" 'openclaw gateway'

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

test_vm_provision_installs_qualification_suite_idempotently() {
  local fixture_root
  local home_dir="$TEMP_DIR/home-qualification"
  local target_dir="$home_dir/.openclaw/workspace/.clawbox/qualification"
  local current_dir="$target_dir/current"
  local runs_dir="$target_dir/runs"
  local unrelated_file="$home_dir/.openclaw/workspace/notes.txt"
  local old_run_a="$runs_dir/old-run-a/sentinel.txt"
  local old_run_b="$runs_dir/old-run-b/sentinel.txt"

  setup_vm_provision_fixture
  fixture_root="$REPLY"
  setup_vm_provision_mocks

  mkdir -p "$(dirname "$unrelated_file")"
  printf 'keep me\n' > "$unrelated_file"
  mkdir -p "$(dirname "$old_run_a")" "$(dirname "$old_run_b")"
  printf 'keep-a\n' > "$old_run_a"
  printf 'keep-b\n' > "$old_run_b"

  run_vm_provision "$fixture_root" "$home_dir" '' true

  assert_equals 'vm provision qualification install succeeds' "$VM_PROVISION_LAST_STATUS" '0'
  assert_contains 'vm provision qualification install reports target' "$VM_PROVISION_LAST_OUTPUT" "Installed qualification suite at $target_dir"
  if [ -f "$current_dir/runner.sh" ] && [ -f "$current_dir/.clawbox-manifest.json" ]; then
    pass 'vm provision qualification install writes runner and manifest'
  else
    fail 'vm provision qualification install should write runner and manifest'
  fi
  if [ -x "$current_dir/runner.sh" ]; then
    pass 'vm provision qualification install makes runner executable'
  else
    fail 'vm provision qualification install should make runner executable'
  fi
  for scenario in \
    "$current_dir/scenarios/01-tool-reliability.sh" \
    "$current_dir/scenarios/02-tool-workflows.sh" \
    "$current_dir/scenarios/03-code-repair.sh"
  do
    if [ -x "$scenario" ]; then
      pass "vm provision qualification install makes scenario executable: ${scenario##*/}"
    else
      fail "vm provision qualification install should make scenario executable: ${scenario##*/}"
    fi
  done
  if [ ! -x "$current_dir/lib/helpers.sh" ]; then
    pass 'vm provision qualification install keeps helper library source-only'
  else
    fail 'vm provision qualification install should keep helper library source-only'
  fi
  if [ "$(cat "$unrelated_file")" = 'keep me' ]; then
    pass 'vm provision qualification install preserves unrelated workspace files'
  else
    fail 'vm provision qualification install should preserve unrelated workspace files'
  fi
  assert_equals 'vm provision qualification install preserves first historical run' "$(cat "$old_run_a")" 'keep-a'
  assert_equals 'vm provision qualification install preserves second historical run' "$(cat "$old_run_b")" 'keep-b'

  printf '{"schemaVersion":"1","suiteVersion":"1","checksum":"stale"}\n' > "$current_dir/.clawbox-manifest.json"
  printf '\n# stale update marker\n' >> "$fixture_root/vm/qualification/runner.sh"
  run_vm_provision "$fixture_root" "$home_dir" '' true
  assert_equals 'vm provision stale qualification update succeeds' "$VM_PROVISION_LAST_STATUS" '0'
  assert_contains 'vm provision stale qualification update reinstalls runtime code' "$VM_PROVISION_LAST_OUTPUT" "Installed qualification suite at $target_dir"
  assert_contains 'vm provision stale qualification update writes new runtime runner' "$(cat "$current_dir/runner.sh")" 'stale update marker'
  assert_equals 'vm provision stale qualification update preserves first historical run' "$(cat "$old_run_a")" 'keep-a'
  assert_equals 'vm provision stale qualification update preserves second historical run' "$(cat "$old_run_b")" 'keep-b'

  run_vm_provision "$fixture_root" "$home_dir" '' true
  assert_contains 'vm provision qualification install is idempotent' "$VM_PROVISION_LAST_OUTPUT" "Qualification suite already current at $target_dir"
  assert_equals 'vm provision idempotent path preserves first historical run' "$(cat "$old_run_a")" 'keep-a'
  assert_equals 'vm provision idempotent path preserves second historical run' "$(cat "$old_run_b")" 'keep-b'
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

test_vm_provision_prints_return_to_host_instruction() {
  local fixture_root
  local home_dir="$TEMP_DIR/home-return"

  setup_vm_provision_fixture
  fixture_root="$REPLY"
  setup_vm_provision_mocks

  mkdir -p "$home_dir"

  run_vm_provision "$fixture_root" "$home_dir" ''

  assert_equals 'vm provision succeeds without gateway prompt input' "$VM_PROVISION_LAST_STATUS" '0'
  assert_contains 'vm provision prints completion banner' "$VM_PROVISION_LAST_OUTPUT" 'VM provisioning complete.'
  assert_contains 'vm provision directs user back to host setup' "$VM_PROVISION_LAST_OUTPUT" 'Return to the ClawBox setup process on the host to finish configuration and start OpenClaw.'
  assert_contains 'vm provision visually separates completion from host handoff' "$VM_PROVISION_LAST_OUTPUT" $'VM provisioning complete.\n\nReturn to the ClawBox setup process on the host to finish configuration and start OpenClaw.'
  assert_not_contains 'vm provision does not print the old next-step banner' "$VM_PROVISION_LAST_OUTPUT" 'Next step:'
  assert_not_contains 'vm provision does not print manual gateway instructions' "$VM_PROVISION_LAST_OUTPUT" "$fixture_root/opt/homebrew/bin/openclaw gateway"
}

test_vm_provision_never_starts_foreground_gateway() {
  local fixture_root
  local home_dir="$TEMP_DIR/home-no-gateway"

  setup_vm_provision_fixture
  fixture_root="$REPLY"
  setup_vm_provision_mocks

  mkdir -p "$home_dir"

  run_vm_provision "$fixture_root" "$home_dir" 'y'

  assert_equals 'vm provision succeeds even if obsolete prompt input is present' "$VM_PROVISION_LAST_STATUS" '0'
  assert_not_contains 'vm provision never prints gateway start banner' "$VM_PROVISION_LAST_OUTPUT" 'Starting OpenClaw gateway in the current terminal...'
  assert_not_contains 'vm provision never executes the foreground gateway command' "$VM_PROVISION_LAST_OUTPUT" 'gateway started'
  assert_contains 'vm provision still directs user back to host setup' "$VM_PROVISION_LAST_OUTPUT" 'Return to the ClawBox setup process on the host to finish configuration and start OpenClaw.'
}

printf 'Running vm provision tests\n'

run_test test_vm_provision_copies_config_and_skips_gateway_prompt_when_requested
run_test test_vm_provision_installs_qualification_suite_idempotently
run_test test_vm_provision_deduplicates_zprofile_entries
run_test test_vm_provision_prints_return_to_host_instruction
run_test test_vm_provision_never_starts_foreground_gateway

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
