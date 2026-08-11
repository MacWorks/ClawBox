LAUNCHAGENT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$LAUNCHAGENT_LIB_DIR/output.sh"
source "$LAUNCHAGENT_LIB_DIR/log-paths.sh"

launchagent_init_paths() {
  LAUNCHAGENT_PATH="$HOME/Library/LaunchAgents/com.clawbox.startutmvm.plist"
  LAUNCHAGENT_WRAPPER_SRC="$BASE_DIR/host/scripts/start-utm-vm.sh"
  LAUNCHAGENT_WRAPPER_DEST="$HOME/Library/Application Support/ClawBox/bin/start-utm-vm.sh"
  LAUNCHAGENT_STDOUT_LOG="${CLAWBOX_VM_AUTOSTART_OUT_LOG:-$(clawbox_startutmvm_stdout_log_default)}"
  LAUNCHAGENT_STDERR_LOG="${CLAWBOX_VM_AUTOSTART_ERR_LOG:-$(clawbox_startutmvm_stderr_log_default)}"
  LAUNCHAGENT_STATE_FILE="${CLAWBOX_VM_AUTOSTART_STATE_FILE:-$HOME/Library/Application Support/ClawBox/state/start-utm-vm.status}"
}

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
      expected_count = (expected_host == "" ? 2 : 3)
      if (count != expected_count) exit 1
      if (args[0] != expected_wrapper) exit 1
      if (args[1] != expected_name) exit 1
      if (expected_host != "" && args[2] != expected_host) exit 1
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

  awk '
    /<key>KeepAlive<\/key>/ { in_keepalive=1; next }
    in_keepalive && /<\/dict>/ { exit }
    in_keepalive && /<key>SuccessfulExit<\/key>/ {
      getline
      if ($0 ~ /<false\/>/) found=1
    }
    END {
      if (!found) exit 1
    }
  ' "$LAUNCHAGENT_PATH" || return 1

  return 0
}

launchagent_service_domain() {
  printf 'gui/%s\n' "$(id -u)"
}

launchagent_service_target() {
  printf '%s/com.clawbox.startutmvm\n' "$(launchagent_service_domain)"
}

launchagent_service_loaded() {
  launchctl print "$(launchagent_service_target)" >/dev/null 2>&1
}

launchagent_runtime_operational() {
  [ -x "$LAUNCHAGENT_WRAPPER_DEST" ] || return 1
  [ -f "$LAUNCHAGENT_PATH" ] || return 1
  launchagent_plist_matches || return 1
  launchagent_service_loaded || return 1
}

launchagent_state_wait_attempts() {
  printf '%s\n' "${CLAWBOX_VM_AUTOSTART_SETUP_WAIT_ATTEMPTS:-45}"
}

launchagent_state_wait_interval() {
  printf '%s\n' "${CLAWBOX_VM_AUTOSTART_SETUP_WAIT_INTERVAL:-1}"
}

launchagent_read_start_state() {
  local line=''
  local key=''
  local value=''

  launchagent_init_paths
  LAUNCHAGENT_START_STATE=''
  LAUNCHAGENT_START_STATE_VM=''
  LAUNCHAGENT_START_STATE_HOST=''
  LAUNCHAGENT_START_STATE_DETAIL=''
  LAUNCHAGENT_START_STATE_TIME=''

  [ -f "$LAUNCHAGENT_STATE_FILE" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      state)
        LAUNCHAGENT_START_STATE="$value"
        ;;
      vm)
        LAUNCHAGENT_START_STATE_VM="$value"
        ;;
      host)
        LAUNCHAGENT_START_STATE_HOST="$value"
        ;;
      detail)
        LAUNCHAGENT_START_STATE_DETAIL="$value"
        ;;
      time)
        LAUNCHAGENT_START_STATE_TIME="$value"
        ;;
    esac
  done < "$LAUNCHAGENT_STATE_FILE"

  [ -n "$LAUNCHAGENT_START_STATE" ] || return 1
  [ "${LAUNCHAGENT_START_STATE_VM:-}" = "${VM_MACHINE_NAME:-}" ] || return 1
  return 0
}

launchagent_wait_for_start_state() {
  local attempts=1
  local max_attempts=''
  local interval=''

  max_attempts="$(launchagent_state_wait_attempts)"
  interval="$(launchagent_state_wait_interval)"

  while [ "$attempts" -le "$max_attempts" ]; do
    if launchagent_read_start_state; then
      case "$LAUNCHAGENT_START_STATE" in
        running)
          return 0
          ;;
        failed|skipped)
          return 1
          ;;
      esac
    fi

    attempts=$((attempts + 1))
    status_sleep "$interval" 'Waiting for VM startup service...'
  done

  return 1
}

launchagent_print_start_attempt_summary() {
  launchagent_init_paths

  if launchagent_read_start_state; then
    out "VM startup service state: $LAUNCHAGENT_START_STATE"
    if [ -n "${LAUNCHAGENT_START_STATE_DETAIL:-}" ]; then
      out "VM startup detail: $LAUNCHAGENT_START_STATE_DETAIL"
    fi
  else
    out 'VM startup service state: no completion state recorded.'
  fi

  out "VM startup stdout log: $LAUNCHAGENT_STDOUT_LOG"
  out "VM startup stderr log: $LAUNCHAGENT_STDERR_LOG"

  if [ -s "$LAUNCHAGENT_STDERR_LOG" ]; then
    out 'Recent VM startup stderr:'
    tail -n 8 "$LAUNCHAGENT_STDERR_LOG"
  elif [ -s "$LAUNCHAGENT_STDOUT_LOG" ]; then
    out 'Recent VM startup output:'
    tail -n 8 "$LAUNCHAGENT_STDOUT_LOG"
  fi
}

launchagent_bootout_service() {
  if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "$(launchagent_service_domain)" "$LAUNCHAGENT_PATH" >/dev/null 2>&1 || \
      launchctl bootout "$(launchagent_service_target)" >/dev/null 2>&1 || \
      launchctl unload "$LAUNCHAGENT_PATH" >/dev/null 2>&1 || true
  fi
}

launchagent_write_files() {
  mkdir -p "$HOME/Library/Application Support/ClawBox/bin"
  mkdir -p "$HOME/Library/Application Support/ClawBox/state"
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
EOF
  if [ -n "${VM_HOST:-}" ]; then
    cat >> "$LAUNCHAGENT_PATH" <<EOF
    <string>$VM_HOST</string>
EOF
  fi
  cat >> "$LAUNCHAGENT_PATH" <<EOF
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <dict>
      <key>SuccessfulExit</key>
      <false/>
    </dict>

  <key>StandardOutPath</key>
  <string>$LAUNCHAGENT_STDOUT_LOG</string>

  <key>StandardErrorPath</key>
  <string>$LAUNCHAGENT_STDERR_LOG</string>
</dict>
</plist>
EOF
}

launchagent_install_and_start() {
  launchagent_init_paths
  clawbox_ensure_standard_log_dirs

  if [ -z "${VM_MACHINE_NAME:-}" ]; then
    llama_fail "Missing VM_MACHINE_NAME for VM auto-start LaunchAgent"
    return 1
  fi

  launchagent_write_files
  rm -f "$LAUNCHAGENT_STATE_FILE"

  launchagent_bootout_service
  if ! launchctl bootstrap "$(launchagent_service_domain)" "$LAUNCHAGENT_PATH"; then
    VM_AUTOSTART_STATE='unverified'
    llama_fail "VM auto-start LaunchAgent could not be bootstrapped."
    return 1
  fi
  launchctl kickstart -k "$(launchagent_service_target)" >/dev/null 2>&1 || true

  if ! launchagent_runtime_operational; then
    VM_AUTOSTART_STATE='unverified'
    llama_fail "VM auto-start LaunchAgent was installed but could not be verified as loaded."
    return 1
  fi
}

launchagent_start_selected_vm_for_setup() {
  local saved_vm_host="${VM_HOST:-}"
  local status=0

  launchagent_init_paths

  if [ -z "${VM_MACHINE_NAME:-}" ]; then
    llama_fail 'Missing selected VM name for startup.'
    return 1
  fi

  VM_AUTOSTART_SETUP_TEMPORARY=true
  VM_HOST=''

  status_begin_compact 'Starting selected VM with ClawBox VM startup service...'
  if launchagent_install_and_start && launchagent_wait_for_start_state; then
    status_end 'Selected VM startup verified. ✓' 'progress'
    status=0
  else
    status=$?
    status_end 'Selected VM startup could not be verified.' 'warning'
    status=1
  fi

  VM_HOST="$saved_vm_host"
  return "$status"
}

launchagent_remove_runtime() {
  launchagent_init_paths
  if launchagent_service_loaded; then
    launchagent_bootout_service
  fi
  rm -f "$LAUNCHAGENT_PATH" "$LAUNCHAGENT_WRAPPER_DEST"
}

launchagent_detect_existing_runtime_state() {
  local existing_runtime=false
  local runtime_state=''

  if [ -f "$LAUNCHAGENT_PATH" ]; then
    existing_runtime=true
  elif [ -e "$LAUNCHAGENT_WRAPPER_DEST" ]; then
    existing_runtime=true
  elif launchagent_service_loaded; then
    existing_runtime=true
  fi

  if [ "$existing_runtime" = true ]; then
    if [ -f "$LAUNCHAGENT_PATH" ] && launchagent_plist_matches && launchagent_service_loaded; then
      runtime_state='loaded and matches the expected configuration'
    elif [ -f "$LAUNCHAGENT_PATH" ] && launchagent_plist_matches; then
      runtime_state='present on disk and matches the expected configuration'
    elif launchagent_service_loaded; then
      runtime_state='loaded but does not match the expected configuration'
    else
      runtime_state='present on disk but not loaded'
    fi
  fi

  printf '%s\n' "$existing_runtime"
  printf '%s\n' "$runtime_state"
  return 0
}

launchagent_detect_existing_runtime_state_with_status() {
  local state_file=''
  local pid=''
  local status=0

  state_file="$(mktemp "${TMPDIR:-/tmp}/clawbox-launchagent-state.XXXXXX")" || return 1

  status_begin_compact 'Checking host VM auto-start service...'
  launchagent_detect_existing_runtime_state >"$state_file" &
  pid="$!"

  if status_wait_for_pid_active "$pid" 'Checking host VM auto-start service...'; then
    status_end 'Checking host VM auto-start service... ✓' 'progress'
    status=0
  else
    status="$?"
    status_end 'Checking host VM auto-start service failed.' 'error'
  fi

  if [ -f "$state_file" ]; then
    {
      IFS= read -r REPLY || REPLY=false
      IFS= read -r LAUNCHAGENT_DETECTED_RUNTIME_STATE || LAUNCHAGENT_DETECTED_RUNTIME_STATE=''
    } <"$state_file"
  else
    REPLY=false
    LAUNCHAGENT_DETECTED_RUNTIME_STATE=''
  fi

  rm -f "$state_file"
  return "$status"
}

setup_launchagent() {
  local existing_runtime=false
  local runtime_choice=''
  local runtime_state=''

  launchagent_init_paths
  VM_AUTOSTART_STATE='unknown'

  clawbox_ensure_standard_log_dirs

  launchagent_detect_existing_runtime_state_with_status || return $?
  existing_runtime="$REPLY"
  runtime_state="$LAUNCHAGENT_DETECTED_RUNTIME_STATE"

  if [ "$existing_runtime" = true ] && [ "${VM_AUTOSTART_SETUP_TEMPORARY:-false}" != true ]; then
    blank_line
    out 'Existing host VM auto-start service detected.'

    out "  State: $runtime_state"
    out "  Plist: $(if [ -f "$LAUNCHAGENT_PATH" ]; then printf 'present'; else printf 'missing'; fi)"
    out "  Service: $(if launchagent_service_loaded; then printf 'loaded'; else printf 'not loaded'; fi)"
    out "  Wrapper: $(if [ -x "$LAUNCHAGENT_WRAPPER_DEST" ]; then printf 'installed'; else printf 'missing'; fi)"
    blank_line
    case "$runtime_state" in
      'loaded and matches the expected configuration'|'present on disk and matches the expected configuration')
        out '1) Keep and use the existing host VM auto-start service (recommended)'
        out '2) Reinstall/update host VM auto-start service'
        ;;
      *)
        warn 'The existing host VM auto-start service does not match this ClawBox version.'
        out 'Keeping it will preserve the old behavior; the latest reliability fixes will not be applied.'
        blank_line
        out '1) Keep the existing host VM auto-start service'
        out '2) Reinstall/update host VM auto-start service (recommended)'
        ;;
    esac
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
            if launchagent_runtime_operational; then
              VM_AUTOSTART_STATE='kept'
            else
              VM_AUTOSTART_STATE='unverified'
            fi
          else
            VM_AUTOSTART_STATE='skipped'
          fi
          return 0
          ;;
        2)
          break
          ;;
        3)
          launchagent_remove_runtime
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

  if [ ! -f "$LAUNCHAGENT_PATH" ] || [ "${VM_AUTOSTART_SETUP_TEMPORARY:-false}" = true ]; then
    prompt_yes_no 'Enable VM auto-start at login?' 'n'
    ENABLE_AUTOSTART="$REPLY"

    if ! is_yes "$ENABLE_AUTOSTART"; then
      launchagent_remove_runtime
      out 'LaunchAgent disabled and removed.'
      VM_AUTOSTART_STATE='disabled'
      VM_AUTOSTART_SETUP_TEMPORARY=false
      return 0
    fi
  fi

  if [ -z "${VM_MACHINE_NAME:-}" ] || [ -z "${VM_HOST:-}" ]; then
    llama_fail "Missing required VM configuration for auto-start LaunchAgent"
    return 1
  fi

  launchagent_install_and_start || return $?
  VM_AUTOSTART_STATE='enabled'
  VM_AUTOSTART_SETUP_TEMPORARY=false
  out "LaunchAgent installed."
}
