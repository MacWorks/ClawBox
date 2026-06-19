LAUNCHAGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$LAUNCHAGENT_LIB_DIR/output.sh"
source "$LAUNCHAGENT_LIB_DIR/log-paths.sh"

launchagent_plist_matches() {
  [ -f "$LAUNCHAGENT_PATH" ] || return 1

  grep -Fq '<string>com.clawbox.startutmvm</string>' "$LAUNCHAGENT_PATH" || return 1
  awk -v expected_wrapper="$LAUNCHAGENT_WRAPPER_DEST" \
    -v expected_name="$VM_MACHINE_NAME" \
    -v expected_host="$VM_HOST" '
    /<key>ProgramArguments<\/key>/ { in_args=1; next }
    in_args && /<\/array>/ { exit }
    in_args && /<string>/ {
      gsub(/.*<string>|<\/string>.*/, "", $0)
      args[count++] = $0
    }
    END {
      if (count != 3) exit 1
      if (args[0] != expected_wrapper) exit 1
      if (args[1] != expected_name) exit 1
      if (args[2] != expected_host) exit 1
    }
  ' "$LAUNCHAGENT_PATH" || return 1
  awk '
    /<key>RunAtLoad<\/key>/ {
      getline
      if ($0 ~ /<true\/>/) found=1
    }
    END {
      if (!found) exit 1
    }
  ' "$LAUNCHAGENT_PATH" || return 1

  if grep -Fq '<key>KeepAlive</key>' "$LAUNCHAGENT_PATH"; then
    return 1
  fi

  return 0
}

launchagent_service_target() {
  printf 'gui/%s/com.clawbox.startutmvm\n' "$(id -u)"
}

launchagent_service_loaded() {
  launchctl print "$(launchagent_service_target)" >/dev/null 2>&1
}

setup_launchagent() {
  LAUNCHAGENT_PATH="$HOME/Library/LaunchAgents/com.clawbox.startutmvm.plist"
  LAUNCHAGENT_WRAPPER_SRC="$BASE_DIR/host/scripts/start-utm-vm.sh"
  LAUNCHAGENT_WRAPPER_DEST="$HOME/Library/Application Support/ClawBox/bin/start-utm-vm.sh"
  LAUNCHAGENT_STDOUT_LOG="${CLAWBOX_VM_AUTOSTART_OUT_LOG:-$(clawbox_startutmvm_stdout_log_default)}"
  LAUNCHAGENT_STDERR_LOG="${CLAWBOX_VM_AUTOSTART_ERR_LOG:-$(clawbox_startutmvm_stderr_log_default)}"
  local existing_runtime=false
  local runtime_choice=''
  local runtime_state=''

  VM_AUTOSTART_STATE='unknown'

  clawbox_ensure_standard_log_dirs

  if [ -f "$LAUNCHAGENT_PATH" ] || [ -e "$LAUNCHAGENT_WRAPPER_DEST" ] || launchagent_service_loaded; then
    existing_runtime=true
  fi

  if [ "$existing_runtime" = true ]; then
    blank_line
    out 'Existing VM auto-start runtime service detected.'

    if [ -f "$LAUNCHAGENT_PATH" ] && launchagent_plist_matches && launchagent_service_loaded; then
      runtime_state='loaded and matches the expected configuration'
    elif [ -f "$LAUNCHAGENT_PATH" ] && launchagent_plist_matches; then
      runtime_state='present on disk and matches the expected configuration'
    elif launchagent_service_loaded; then
      runtime_state='loaded but does not match the expected configuration'
    else
      runtime_state='present on disk but not loaded'
    fi

    out "  State: $runtime_state"
    out "  Plist: $(if [ -f "$LAUNCHAGENT_PATH" ]; then printf 'present'; else printf 'missing'; fi)"
    out "  Service: $(if launchagent_service_loaded; then printf 'loaded'; else printf 'not loaded'; fi)"
    out "  Wrapper: $(if [ -x "$LAUNCHAGENT_WRAPPER_DEST" ]; then printf 'installed'; else printf 'missing'; fi)"
    blank_line
    out '1) Keep and use the existing runtime service (recommended)'
    out '2) Reinstall/update runtime service'
    out '3) Disable/remove runtime service'
    out '4) Skip runtime service management during setup'
    blank_line

    while true; do
      prompt_with_suffix 'Choose runtime service action' '[1-4]'
      runtime_choice="$REPLY"

      if [ -z "$runtime_choice" ]; then
        runtime_choice='1'
      fi

      case "$runtime_choice" in
        1|4)
          if [ "$runtime_choice" = '1' ]; then
            VM_AUTOSTART_STATE='kept'
          else
            VM_AUTOSTART_STATE='skipped'
          fi
          return 0
          ;;
        2)
          break
          ;;
        3)
          if launchagent_service_loaded; then
          launchctl unload "$LAUNCHAGENT_PATH" 2>/dev/null || true
          fi
          rm -f "$LAUNCHAGENT_PATH" "$LAUNCHAGENT_WRAPPER_DEST"
          out 'LaunchAgent disabled and removed.'
          VM_AUTOSTART_STATE='disabled'
          return 0
          ;;
        *)
          error 'Invalid input. Enter 1, 2, 3, or 4.'
          ;;
      esac
    done
  fi

  if [ ! -f "$LAUNCHAGENT_PATH" ]; then
    prompt_yes_no 'Enable VM auto-start at login?' 'n'
    ENABLE_AUTOSTART="$REPLY"

    if ! is_yes "$ENABLE_AUTOSTART"; then
      VM_AUTOSTART_STATE='disabled'
      return 0
    fi
  fi

  if [ -z "${VM_MACHINE_NAME:-}" ] || [ -z "${VM_HOST:-}" ]; then
    llama_fail "Missing required VM configuration for auto-start LaunchAgent"
    return 1
  fi

  mkdir -p "$HOME/Library/Application Support/ClawBox/bin"
  mkdir -p "$HOME/Library/LaunchAgents"
  mkdir -p "$(dirname "$LAUNCHAGENT_STDOUT_LOG")"
  install -m 755 "$LAUNCHAGENT_WRAPPER_SRC" "$LAUNCHAGENT_WRAPPER_DEST"
  touch "$LAUNCHAGENT_STDOUT_LOG" "$LAUNCHAGENT_STDERR_LOG"
  cat > "$LAUNCHAGENT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.clawbox.startutmvm</string>

    <key>ProgramArguments</key>
    <array>
    <string>$LAUNCHAGENT_WRAPPER_DEST</string>
    <string>$VM_MACHINE_NAME</string>
    <string>$VM_HOST</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

  <key>StandardOutPath</key>
  <string>$LAUNCHAGENT_STDOUT_LOG</string>

  <key>StandardErrorPath</key>
  <string>$LAUNCHAGENT_STDERR_LOG</string>
</dict>
</plist>
EOF
  launchctl unload "$LAUNCHAGENT_PATH" 2>/dev/null || true
  launchctl load "$LAUNCHAGENT_PATH"
  VM_AUTOSTART_STATE='enabled'
  out "LaunchAgent installed."
}
