# Dependencies are sourced by scripts/setup.sh before these functions run:
# setup env/derive helpers, lib/llama.sh, shared output, and error_exit.

doctor_llama_environment() {
  local homebrew_state
  local homebrew_bin
  local homebrew_shellenv_line
  local has_cmake=false
  local has_git=false

  section "LLaMA Environment Check"

  llama_homebrew_state
  homebrew_state="$REPLY"

  if command -v cmake >/dev/null 2>&1; then
    has_cmake=true
  fi

  if command -v git >/dev/null 2>&1; then
    has_git=true
  fi

  blank_line
  out 'Capabilities:'
  blank_line

  if [ "$homebrew_state" = 'usable' ]; then
    out '  Homebrew:       OK'
  elif [ "$homebrew_state" = 'installed-not-in-path' ]; then
    out '  Homebrew:       Installed (not in PATH)'
  elif [ "$homebrew_state" = 'installed-not-usable' ]; then
    out '  Homebrew:       Installed (not writable)'
  else
    out '  Homebrew:       Not installed'
  fi

  if [ "$has_git" = true ]; then
    out '  git:            OK'
  else
    out '  git:            Missing'
  fi

  if [ "$has_cmake" = true ]; then
    out '  cmake:          OK'
  else
    out '  cmake:          Missing'
  fi

  blank_line
  out 'Recommended actions:'
  blank_line

  if [ "$homebrew_state" = 'installed-not-in-path' ]; then
    resolve_homebrew_bin_path || return 1
    homebrew_bin="$REPLY"
    resolve_homebrew_shellenv_line "$homebrew_bin"
    homebrew_shellenv_line="$REPLY"
    out '  - Fix Homebrew PATH:'
    out "      $homebrew_shellenv_line"
    out "      echo '$homebrew_shellenv_line' >> ~/.zprofile"
    blank_line
  elif [ "$homebrew_state" = 'installed-not-usable' ]; then
    out '  - Install Homebrew under the current user (recommended):'
    out '      https://brew.sh'
    blank_line
  elif [ "$homebrew_state" != 'usable' ]; then
    out '  - Install Homebrew (recommended):'
    out '      https://brew.sh'
    blank_line
  fi

  if [ "$has_git" != true ] || [ "$has_cmake" != true ]; then
    out '  - Install build tools for source build:'

    if [ "$has_git" != true ]; then
      out '      git is required'
    fi

    if [ "$has_cmake" != true ]; then
      out '      cmake is required'
    fi

    out '      On macOS: xcode-select --install'
    out '      If cmake is still missing: brew install cmake'
    blank_line
  fi

  return 0
}

resolve_configured_llama_bin() {
  local llama_bin_candidate="$1"
  local result
  local status

  result=""
  llama_capture_status resolve_llama_bin_path "$llama_bin_candidate"
  status=$LLAMA_LAST_STATUS

  if [ "$status" -eq 0 ]; then
    result="$REPLY"
  fi

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$status" -ne 0 ]; then
    return "$status"
  fi

  REPLY="$result"
  return
}

ensure_llama_bin_ready() {
  local fallback_candidate
  local initial_candidate
  local resolved_candidate
  local resolved_path
  local status

  if command -v llama-server >/dev/null 2>&1; then
    LLAMA_BIN="$(command -v llama-server)"
    return 0
  fi

  if [ -x "${LLAMA_BIN:-}" ]; then
    return
  fi

  if [ -n "${LLAMA_BIN:-}" ]; then
    initial_candidate="$LLAMA_BIN"
  else
    initial_candidate="$(default_host_llama_bin_path)"
  fi

  llama_capture_status resolve_configured_llama_bin "$initial_candidate"
  status=$LLAMA_LAST_STATUS

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$status" -ne 0 ]; then
    error_exit "llama-server setup aborted"
  fi

  resolved_path="$REPLY"
  LLAMA_BIN="$resolved_path"

  if [ ! -t 0 ] && [ ! -p /dev/stdin ]; then
    error_exit "llama-server binary not found or not executable: ${LLAMA_BIN:-}"
  fi

  derive_llama_bin_path
  fallback_candidate="$REPLY"
  configured_or_default 'LLAMA_BIN' "${LLAMA_BIN:-}" "$fallback_candidate"
  resolved_candidate="$REPLY"

  if ! llama_is_valid_binary "$resolved_candidate"; then
    section "LLaMA Server Configuration"
  fi

  llama_capture_status resolve_configured_llama_bin "$resolved_candidate"
  status=$LLAMA_LAST_STATUS

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$status" -ne 0 ]; then
    error_exit "llama-server setup aborted"
  fi

  resolved_path="$REPLY"
  LLAMA_BIN="$resolved_path"
  write_env_from_template
  source_env_file
}

select_requested_llama_install_mode() {
  local install_mode
  local status

  llama_capture_status select_llama_install_mode
  status=$LLAMA_LAST_STATUS

  if [ "$status" -eq 0 ]; then
    install_mode="$REPLY"
    return 0
  fi

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  return 1
}
