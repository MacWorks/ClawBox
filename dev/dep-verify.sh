#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$BASE_DIR/lib/llama.sh"

echo ""
echo "---------------------------------"
echo "   ClawBox Clean State Check"
echo "---------------------------------"
echo ""

failures=0

check_fail() {
  echo "✗ $1"
  failures=$((failures + 1))
}

check_pass() {
  echo "✓ $1"
}

check_info() {
  echo "• $1"
}

# ---------------------------------
# Process check
# ---------------------------------

if pgrep -fl "llama-server" >/dev/null 2>&1; then
  check_fail "llama-server process is still running"
  pgrep -fl "llama-server"
else
  check_pass "No llama-server process running"
fi

# ---------------------------------
# Port check (11434 default)
# ---------------------------------

if lsof -i :11434 >/dev/null 2>&1; then
  check_fail "Port 11434 is in use"
  lsof -i :11434
else
  check_pass "Port 11434 is free"
fi

# ---------------------------------
# LaunchDaemon check
# ---------------------------------

if user_has_sudo; then
  blank_line
  printf '%s\n' 'Administrator privileges may be required' >&2
  blank_line
  sudo -v
  blank_line
fi

if user_has_sudo; then
  if llama_maybe_sudo system launchctl print system/com.clawbox.llama >/dev/null 2>&1; then
    check_fail "System LaunchDaemon is still loaded"
  else
    check_pass "System LaunchDaemon not loaded"
  fi
else
  check_info "System LaunchDaemon check skipped without sudo access"
fi

if user_has_sudo; then
  if [ -f "/Library/LaunchDaemons/com.clawbox.llama.plist" ]; then
    check_fail "System LaunchDaemon plist still exists"
  else
    check_pass "System LaunchDaemon plist removed"
  fi
else
  check_info "System LaunchDaemon plist check skipped without sudo access"
fi

# ---------------------------------
# LaunchAgent check (user)
# ---------------------------------

if launchctl print "gui/$(id -u)/com.clawbox.llama" >/dev/null 2>&1; then
  check_fail "User LaunchAgent is still loaded"
else
  check_pass "User LaunchAgent not loaded"
fi

if [ -f "$HOME/Library/LaunchAgents/com.clawbox.llama.plist" ]; then
  check_fail "User LaunchAgent plist still exists"
else
  check_pass "User LaunchAgent plist removed"
fi

# ---------------------------------
# File checks
# ---------------------------------

[ -f "/usr/local/bin/clawbox-llama-wrapper.sh" ] \
  && check_fail "System wrapper still exists" \
  || check_pass "System wrapper removed"

[ -f "/usr/local/etc/clawbox.env" ] \
  && check_fail "System env file still exists" \
  || check_pass "System env file removed"

# ---------------------------------
# Summary
# ---------------------------------

echo ""

if [ "$failures" -eq 0 ]; then
  echo "✓ CLEAN STATE CONFIRMED"
  echo ""
  echo ""
  exit 0
else
  echo "✗ CLEAN STATE FAILED ($failures issues)"
  echo ""
  echo "Run ./dev/dep-remove.sh to clean up."
  echo ""
  echo ""
  exit 1
fi