#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$BASE_DIR/lib/llama.sh"

echo ""
echo "---------------------------------"
echo "   ClawBox Dependency Reset"
echo "---------------------------------"
echo ""

confirm() {
  read -r -p "$1 [y/N]: " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  echo "→ $1"
}

success() {
  echo "✓ $1"
}

warn() {
  echo "⚠ $1"
}

# ---------------------------------
# Remove LaunchDaemon (system)
# ---------------------------------

SYSTEM_PLIST="/Library/LaunchDaemons/com.clawbox.llama.plist"

if [ -f "$SYSTEM_PLIST" ]; then
  log "Removing system LaunchDaemon..."

  if user_has_sudo; then
    if llama_maybe_sudo system launchctl print system/com.clawbox.llama >/dev/null 2>&1; then
      llama_maybe_sudo system launchctl bootout system "$SYSTEM_PLIST" || true
    fi

    llama_maybe_sudo system rm -f "$SYSTEM_PLIST"
    success "System LaunchDaemon removed"
  else
    warn "Skipping system LaunchDaemon removal without sudo access"
  fi
else
  log "No system LaunchDaemon found"
fi

# ---------------------------------
# Remove LaunchAgent (user)
# ---------------------------------

USER_PLIST="$HOME/Library/LaunchAgents/com.clawbox.llama.plist"

if [ -f "$USER_PLIST" ]; then
  log "Removing user LaunchAgent..."

  if launchctl print "gui/$(id -u)/com.clawbox.llama" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)" "$USER_PLIST" || true
  fi

  rm -f "$USER_PLIST"
  success "User LaunchAgent removed"
else
  log "No user LaunchAgent found"
fi

# ---------------------------------
# Remove wrapper + env (system)
# ---------------------------------

if [ -f "/usr/local/bin/clawbox-llama-wrapper.sh" ]; then
  log "Removing system wrapper..."
  if user_has_sudo; then
    llama_maybe_sudo system rm -f /usr/local/bin/clawbox-llama-wrapper.sh
    success "Wrapper removed"
  else
    warn "Skipping system wrapper removal without sudo access"
  fi
fi

if [ -f "/usr/local/etc/clawbox.env" ]; then
  log "Removing system env..."
  if user_has_sudo; then
    llama_maybe_sudo system rm -f /usr/local/etc/clawbox.env
    success "Env removed"
  else
    warn "Skipping system env removal without sudo access"
  fi
fi

# ---------------------------------
# Remove wrapper + env (user)
# ---------------------------------

USER_BASE="$HOME/Library/Application Support/ClawBox"

if [ -d "$USER_BASE" ]; then
  log "Removing user ClawBox support directory..."
  rm -rf "$USER_BASE"
  success "User support files removed"
fi

# ---------------------------------
# Optional: remove llama.cpp
# ---------------------------------

LLAMA_DIR="$HOME/ai/llama.cpp"

if [ -d "$LLAMA_DIR" ]; then
  echo ""
  warn "llama.cpp directory detected at:"
  echo "  $LLAMA_DIR"
  echo ""

  if confirm "Remove llama.cpp directory?"; then
    rm -rf "$LLAMA_DIR"
    success "llama.cpp removed"
  else
    log "Skipped removing llama.cpp"
  fi
fi

# ---------------------------------
# Done
# ---------------------------------

echo ""
echo "---------------------------------"
echo " Reset complete"
echo "---------------------------------"
echo ""

echo "Next steps:"
echo "- Re-run ./clawbox setup to test fresh install"
echo ""

if [ -x "$SCRIPT_DIR/dep-verify.sh" ]; then
  "$SCRIPT_DIR/dep-verify.sh"
else
  echo "⚠️  dep-verify.sh not found or not executable"
  echo ""
  exit 1
fi