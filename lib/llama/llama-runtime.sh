LLAMA_RUNTIME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$LLAMA_RUNTIME_LIB_DIR/../log-paths.sh"

default_host_llama_repo_dir() {
  [ -n "${HOME:-}" ] || return
  printf '%s/ai/llama.cpp\n' "$HOME"
}

default_host_llama_bin_path() {
  local repo_dir

  repo_dir="$(default_host_llama_repo_dir)"
  [ -n "$repo_dir" ] || return
  printf '%s/build/bin/llama-server\n' "$repo_dir"
}

llama_escape_env_value() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"

  printf '%s' "$value"
}

write_llama_runtime_env() {
  local output_path="$1"
  local key
  local value

  : > "$output_path"

  for key in LLAMA_BIN MODEL_PATH LLAMA_HOST LLAMA_PORT LLAMA_CTX LLAMA_EXTRA_ARGS; do
    value="${!key:-}"
    printf '%s="%s"\n' "$key" "$(llama_escape_env_value "$value")" >> "$output_path"
  done
}

llama_render_plist() {
  local output_path="$1"
  local wrapper_path="$2"
  local env_path="$3"
  local stdout_path="$4"
  local stderr_path="$5"

  cat > "$output_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>

  <key>Label</key>
  <string>com.clawbox.llama</string>

  <key>ProgramArguments</key>
  <array>
    <string>$wrapper_path</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>CLAWBOX_ENV_FILE</key>
    <string>$env_path</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>$stdout_path</string>

  <key>StandardErrorPath</key>
  <string>$stderr_path</string>

</dict>
</plist>
EOF
}

llama_user_uid() {
  if [ -n "${CLAWBOX_LLAMA_USER_UID:-}" ]; then
    printf '%s\n' "$CLAWBOX_LLAMA_USER_UID"
    return
  fi

  id -u
}

llama_wrapper_src() {
  printf '%s\n' "${CLAWBOX_LLAMA_WRAPPER_SRC:-$BASE_DIR/host/scripts/llama-wrapper.sh}"
}

llama_system_wrapper_dest() {
  printf '%s\n' "${CLAWBOX_LLAMA_WRAPPER_DEST:-/usr/local/bin/clawbox-llama-wrapper.sh}"
}

llama_system_env_dest() {
  printf '%s\n' "${CLAWBOX_LLAMA_ENV_DEST:-/usr/local/etc/clawbox.env}"
}

llama_system_plist_dest() {
  printf '%s\n' "${CLAWBOX_LLAMA_PLIST_DEST:-/Library/LaunchDaemons/com.clawbox.llama.plist}"
}

llama_system_stdout_log() {
  printf '%s\n' "${CLAWBOX_LLAMA_OUT_LOG:-$(clawbox_llama_system_stdout_log_default)}"
}

llama_system_stderr_log() {
  printf '%s\n' "${CLAWBOX_LLAMA_ERR_LOG:-$(clawbox_llama_system_stderr_log_default)}"
}

llama_user_wrapper_dest() {
  printf '%s\n' "${CLAWBOX_LLAMA_USER_WRAPPER_DEST:-$HOME/Library/Application Support/ClawBox/bin/clawbox-llama-wrapper.sh}"
}

llama_user_env_dest() {
  printf '%s\n' "${CLAWBOX_LLAMA_USER_ENV_DEST:-$HOME/Library/Application Support/ClawBox/clawbox.env}"
}

llama_user_plist_dest() {
  printf '%s\n' "${CLAWBOX_LLAMA_USER_PLIST_DEST:-$HOME/Library/LaunchAgents/com.clawbox.llama.plist}"
}

llama_user_stdout_log() {
  printf '%s\n' "${CLAWBOX_LLAMA_USER_OUT_LOG:-$(clawbox_llama_user_stdout_log_default)}"
}

llama_user_stderr_log() {
  printf '%s\n' "${CLAWBOX_LLAMA_USER_ERR_LOG:-$(clawbox_llama_user_stderr_log_default)}"
}

llama_mode_wrapper_dest() {
  case "$1" in
    system) llama_system_wrapper_dest ;;
    user) llama_user_wrapper_dest ;;
  esac
}

llama_mode_env_dest() {
  case "$1" in
    system) llama_system_env_dest ;;
    user) llama_user_env_dest ;;
  esac
}

llama_mode_plist_dest() {
  case "$1" in
    system) llama_system_plist_dest ;;
    user) llama_user_plist_dest ;;
  esac
}

llama_mode_stdout_log() {
  case "$1" in
    system) llama_system_stdout_log ;;
    user) llama_user_stdout_log ;;
  esac
}

llama_mode_stderr_log() {
  case "$1" in
    system) llama_system_stderr_log ;;
    user) llama_user_stderr_log ;;
  esac
}

llama_mode_domain() {
  case "$1" in
    system)
      printf 'system\n'
      ;;
    user)
      printf 'gui/%s\n' "$(llama_user_uid)"
      ;;
  esac
}

llama_mode_target() {
  printf '%s/com.clawbox.llama\n' "$(llama_mode_domain "$1")"
}

llama_mode_display_name() {
  case "$1" in
    system) printf 'LaunchDaemon\n' ;;
    user) printf 'LaunchAgent\n' ;;
  esac
}

llama_maybe_sudo() {
  local mode="$1"
  shift

  if [ "$mode" = 'system' ]; then
    sudo "$@"
  else
    "$@"
  fi
}

llama_prepare_system_logs() {
  local stdout_path="$1"
  local stderr_path="$2"

  clawbox_ensure_standard_log_dirs
  llama_maybe_sudo system mkdir -p "$(dirname "$stdout_path")"
  llama_maybe_sudo system touch "$stdout_path" "$stderr_path"
  llama_maybe_sudo system chmod 644 "$stdout_path" "$stderr_path"
}

llama_prepare_user_logs() {
  local stdout_path="$1"
  local stderr_path="$2"

  clawbox_ensure_standard_log_dirs
  mkdir -p "$(dirname "$stdout_path")"
  touch "$stdout_path" "$stderr_path"
  chmod 644 "$stdout_path" "$stderr_path"
}

setup_llama_service_for_mode() {
  local mode="$1"
  local status=0
  local wrapper_src
  local wrapper_dest
  local env_dest
  local plist_dest
  local stdout_path
  local stderr_path
  local env_temp
  local plist_temp
  local wrapper_matches=false
  local env_matches=false
  local plist_matches=false
  local service_loaded=false
  local service_name
  local service_target
  local force_restart=false

  while true; do
    [ -n "${BASE_DIR:-}" ] || {
      llama_fail "BASE_DIR is not set"
      return 1
    }

    wrapper_src="$(llama_wrapper_src)"
    wrapper_dest="$(llama_mode_wrapper_dest "$mode")"
    env_dest="$(llama_mode_env_dest "$mode")"
    plist_dest="$(llama_mode_plist_dest "$mode")"
    stdout_path="$(llama_mode_stdout_log "$mode")"
    stderr_path="$(llama_mode_stderr_log "$mode")"
    service_name="$(llama_mode_display_name "$mode")"
    service_target="$(llama_mode_target "$mode")"
    wrapper_matches=false
    env_matches=false
    plist_matches=false
    service_loaded=false

    [ -f "$wrapper_src" ] || {
      llama_fail "Missing wrapper script: $wrapper_src"
      return 1
    }

    llama_require_value LLAMA_BIN || return 1
    llama_require_value MODEL_PATH || return 1
    llama_require_value LLAMA_HOST || return 1
    llama_require_value LLAMA_PORT || return 1
    llama_require_value LLAMA_CTX || return 1

    if [ ! -x "$LLAMA_BIN" ]; then
      llama_fail "llama binary not found or not executable: $LLAMA_BIN"
      return 1
    fi

    if [ ! -f "$MODEL_PATH" ]; then
      llama_fail "model not found: $MODEL_PATH"
      return 1
    fi

    llama_require_command launchctl || return 1
    llama_require_command curl || return 1

    if [ "$mode" = 'system' ] && ! user_has_sudo; then
      llama_fail "System-wide install requires admin privileges"
      return 1
    fi

    env_temp="$(mktemp)"
    plist_temp="$(mktemp)"

    write_llama_runtime_env "$env_temp"
    llama_render_plist "$plist_temp" "$wrapper_dest" "$env_dest" "$stdout_path" "$stderr_path"

    if [ -f "$wrapper_dest" ] && cmp -s "$wrapper_src" "$wrapper_dest"; then
      wrapper_matches=true
    fi

    if [ -f "$env_dest" ] && cmp -s "$env_temp" "$env_dest"; then
      env_matches=true
    fi

    if [ -f "$plist_dest" ] && cmp -s "$plist_temp" "$plist_dest"; then
      plist_matches=true
    fi

    if llama_service_loaded "$mode"; then
      service_loaded=true
    fi

    if [ "$mode" = 'system' ]; then
      llama_prepare_system_logs "$stdout_path" "$stderr_path"
    else
      llama_prepare_user_logs "$stdout_path" "$stderr_path"
    fi

    if [ "$wrapper_matches" = true ] && [ "$env_matches" = true ] && [ "$plist_matches" = true ] && [ "$service_loaded" = true ] && [ "$force_restart" = false ]; then
      step "Existing llama-server $service_name matches expected configuration"
    else
      llama_maybe_sudo "$mode" mkdir -p "$(dirname "$wrapper_dest")" "$(dirname "$env_dest")" "$(dirname "$plist_dest")"

      if [ "$wrapper_matches" = false ]; then
        step "Installing llama-server wrapper"
        llama_maybe_sudo "$mode" install -m 755 "$wrapper_src" "$wrapper_dest"
      fi

      if [ "$env_matches" = false ]; then
        step "Installing llama-server runtime environment"
        llama_maybe_sudo "$mode" install -m 644 "$env_temp" "$env_dest"
      fi

      if [ "$plist_matches" = false ]; then
        step "Installing llama-server $service_name"
        llama_maybe_sudo "$mode" install -m 644 "$plist_temp" "$plist_dest"
        if [ "$mode" = 'system' ]; then
          llama_maybe_sudo "$mode" chown root:wheel "$plist_dest"
        fi
      fi
    fi

    rm -f "$env_temp" "$plist_temp"

    if [ "$wrapper_matches" = false ] || [ "$env_matches" = false ] || [ "$plist_matches" = false ] || [ "$service_loaded" = false ] || [ "$force_restart" = true ]; then
      LLAMA_SERVICE_CHANGED=true
      step "Starting llama-server $service_name"
      if [ "$service_loaded" = true ]; then
        llama_maybe_sudo "$mode" launchctl bootout "$(llama_mode_domain "$mode")" "$plist_dest" >/dev/null 2>&1 || true
      fi
      llama_maybe_sudo "$mode" launchctl bootstrap "$(llama_mode_domain "$mode")" "$plist_dest"
      llama_maybe_sudo "$mode" launchctl kickstart -k "$service_target" >/dev/null 2>&1 || true
    fi

    if ! llama_service_loaded "$mode"; then
      llama_fail "$service_name not loaded: $service_target"
      return 1
    fi

    LLAMA_ACTIVE_MODE="$mode"
    LLAMA_ACTIVE_SERVICE_TARGET="$service_target"
    LLAMA_ACTIVE_PLIST_DEST="$plist_dest"

    llama_capture_status llama_verify_service_health
    status=$LLAMA_LAST_STATUS

    case "$status" in
      0)
        return 0
        ;;
      "$LLAMA_EXIT_RETRY")
        force_restart=true
        ;;
      "$LLAMA_EXIT_CHANGE_PORT")
        force_restart=true
        ;;
      "$LLAMA_EXIT_GRACEFUL")
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
      *)
        return "$status"
        ;;
    esac
  done
}

setup_system_llama_service() {
  setup_llama_service_for_mode system
}

setup_user_llama_service() {
  setup_llama_service_for_mode user
}
