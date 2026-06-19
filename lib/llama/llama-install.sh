select_llama_install_mode() {
  local detected_mode
  local choice
  local status

  llama_capture_status detect_existing_llama_install_mode
  status=$LLAMA_LAST_STATUS

  if [ "$status" -eq 0 ]; then
    detected_mode="$REPLY"
  else
    detected_mode=''
  fi

  if [ -n "$detected_mode" ]; then
    REPLY="$detected_mode"
    return 0
  fi

  if user_has_sudo; then
    while true; do
      err 'Choose how llama-server should run on this Mac:'
      err_blank_line
      err '1) System-wide (recommended)'
      err '   - Requires admin privileges'
      err '   - Runs as LaunchDaemon'
      err '   - Available to all users'
      err '   - Starts at boot'
      err_blank_line
      err '2) User-only'
      err '   - No admin required'
      err '   - Runs as LaunchAgent'
      err '   - Only runs when this user is logged in'
      err_blank_line

      choice="$(llama_read_choice 'Choose [1-2]:')"
      if [ -z "$choice" ]; then
        choice='1'
      fi

      case "$choice" in
        1)
          REPLY='system'
          return 0
          ;;
        2)
          REPLY='user'
          return 0
          ;;
      esac
    done
  fi

  while true; do
    err 'Choose how llama-server should run on this Mac:'
    warn 'This account does not have admin (sudo) privileges.'
    err '1) Run for this user only (recommended)'
    err '   - Starts when you log in'
    err '   - No admin access required'
    err_blank_line
    err '2) Exit and rerun under an admin account'
    err '   - Required for system-wide install'
    err_blank_line

    choice="$(llama_read_choice 'Choose [1-2]:')"
    if [ -z "$choice" ]; then
      choice='1'
    fi

    case "$choice" in
      1)
        REPLY='user'
        return 0
        ;;
      2)
        return "$LLAMA_EXIT_GRACEFUL"
        ;;
    esac
  done
}

llama_can_build_from_source() {
  command -v cmake >/dev/null 2>&1 && command -v git >/dev/null 2>&1
}

LLAMA_HOMEBREW_CACHE_READY=false
LLAMA_HOMEBREW_CACHE_STATE=''
LLAMA_HOMEBREW_CACHE_BIN=''
LLAMA_HOMEBREW_DETECTION_ANNOUNCED=false

llama_reset_homebrew_cache() {
  LLAMA_HOMEBREW_CACHE_READY=false
  LLAMA_HOMEBREW_CACHE_STATE=''
  LLAMA_HOMEBREW_CACHE_BIN=''
}

llama_announce_homebrew_detection_once() {
  if [ "${LLAMA_HOMEBREW_DETECTION_ANNOUNCED:-false}" = true ]; then
    return 0
  fi

  err 'Detecting Homebrew installation...'
  LLAMA_HOMEBREW_DETECTION_ANNOUNCED=true
}

llama_detect_homebrew_bin_uncached() {
  local detected_brew=''

  detected_brew="$(command -v brew 2>/dev/null || true)"
  if [ -n "$detected_brew" ]; then
    REPLY="$detected_brew"
    return 0
  fi

  if [ -x '/opt/homebrew/bin/brew' ]; then
    REPLY='/opt/homebrew/bin/brew'
    return 0
  fi

  if [ -x '/usr/local/bin/brew' ]; then
    REPLY='/usr/local/bin/brew'
    return 0
  fi

  REPLY=''
  return 1
}

llama_is_homebrew_writable_for_bin() {
  local brew_bin="$1"
  local brew_prefix=''

  if [ -z "$brew_bin" ]; then
    return 1
  fi

  case "$brew_bin" in
    /opt/homebrew/bin/brew)
      brew_prefix='/opt/homebrew'
      ;;
    /usr/local/bin/brew)
      brew_prefix='/usr/local'
      ;;
    *)
      brew_prefix="$($brew_bin --prefix 2>/dev/null || true)"
      ;;
  esac

  [ -n "$brew_prefix" ] || return 1
  [ -w "$brew_prefix" ]
}

llama_cache_homebrew_state() {
  LLAMA_HOMEBREW_CACHE_STATE="$1"
  LLAMA_HOMEBREW_CACHE_BIN="$2"
  LLAMA_HOMEBREW_CACHE_READY=true
  REPLY="$LLAMA_HOMEBREW_CACHE_STATE"
}

install_llama_cpp_automatically() {
  local install_choice
  local homebrew_state
  local homebrew_bin
  local homebrew_shellenv_line
  local can_build_source
  local can_install_homebrew=false
  local homebrew_disabled=false
  local can_use_homebrew_action=false
  local candidate_path
  local available_install_options
  local choice_homebrew
  local choice_source
  local choice_abort
  local single_option_mode=false

  llama_announce_homebrew_detection_once
  llama_homebrew_state
  homebrew_state="$REPLY"

  if [ "$homebrew_state" = 'installed-not-in-path' ]; then
    if resolve_homebrew_bin_path; then
      homebrew_bin="$REPLY"
      if ! llama_prepare_discovered_homebrew "$homebrew_bin"; then
        return 1
      fi
      llama_homebrew_state
      homebrew_state="$REPLY"
    fi
  fi

  can_build_source=false

  if llama_can_build_from_source; then
    can_build_source=true
  fi

  if [ "$homebrew_state" = 'not-installed' ] || [ "$homebrew_state" = 'installed-not-usable' ]; then
    can_install_homebrew=true
  fi

  if [ "$homebrew_state" != 'usable' ] && [ "$can_build_source" != true ] && [ "$can_install_homebrew" != true ]; then
    error 'Cannot install llama.cpp in this environment'

    err 'Reason:'
    if [ "$homebrew_state" = 'installed-not-in-path' ]; then
      err '- Homebrew is installed but not in your PATH'
    elif [ "$homebrew_state" = 'installed-not-usable' ]; then
      err '- Homebrew is installed but not writable by this user'
    else
      err '- Homebrew is not available or not usable'
    fi

    if ! command -v cmake >/dev/null 2>&1; then
      err '- Source build requires cmake, which is not installed'
    fi

    if ! user_has_sudo; then
      err '- This account cannot install system dependencies'
    fi

    err_blank_line

    err 'To continue:'

    if [ "$homebrew_state" = 'installed-not-in-path' ]; then
      resolve_homebrew_bin_path || return 1
      homebrew_bin="$REPLY"
      resolve_homebrew_shellenv_line "$homebrew_bin"
      homebrew_shellenv_line="$REPLY"
      err '- Fix your Homebrew PATH:'
      err "    $homebrew_shellenv_line"
      err "    echo '$homebrew_shellenv_line' >> ~/.zprofile"
      err ''
    elif [ "$homebrew_state" = 'installed-not-usable' ]; then
      err '- Install Homebrew for this user (recommended):'
      err '    https://brew.sh'
      err ''
    else
      err '- Log into an admin account and run:'
      err '    xcode-select --install'
      err ''
    fi

    err 'Then re-run setup.'
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  while true; do
    available_install_options=0
    single_option_mode=false
    choice_homebrew=''
    choice_source=''
    choice_abort=''

    can_use_homebrew_action=false
    if [ "$homebrew_disabled" != true ]; then
      if [ "$homebrew_state" = 'usable' ] || [ "$can_install_homebrew" = true ]; then
        can_use_homebrew_action=true
      fi
    fi

    if [ "$can_use_homebrew_action" = true ]; then
      available_install_options=$((available_install_options + 1))
      choice_homebrew='1'
    fi

    if [ "$can_build_source" = true ]; then
      available_install_options=$((available_install_options + 1))
      if [ -n "$choice_homebrew" ]; then
        choice_source='2'
      else
        choice_source='1'
      fi
    fi

    choice_abort=$((available_install_options + 1))

    if [ "$available_install_options" -eq 0 ]; then
      error 'Automatic installation is not available in this environment.'
      err 'Aborting setup.'
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    if [ "$available_install_options" -eq 1 ]; then
      if [ -n "$choice_homebrew" ]; then
        install_choice="$choice_homebrew"
        if [ "$homebrew_state" = 'usable' ]; then
          err 'Proceeding with Homebrew install.'
        else
          err 'Proceeding with Homebrew installation.'
        fi
      else
        install_choice="$choice_source"
        err 'Proceeding with local source build.'
      fi
      single_option_mode=true
    else
      print_llama_cpp_install_method_options "$homebrew_state" "$can_use_homebrew_action" "$can_build_source"

      while true; do
        install_choice="$(llama_read_choice "Choose install method [1-$choice_abort]:")"

        if [ "$install_choice" != "$choice_homebrew" ] && [ "$install_choice" != "$choice_source" ] && [ "$install_choice" != "$choice_abort" ]; then
          err 'Invalid selection. Enter one of the listed options.'
          continue
        fi

        break
      done
    fi

    if [ -n "$choice_homebrew" ] && [ "$install_choice" = "$choice_homebrew" ]; then
      if [ "$can_install_homebrew" = true ]; then
        llama_capture_status install_homebrew_automatically
        status=$LLAMA_LAST_STATUS

        if [ "$status" -ne 0 ]; then
          print_llama_auto_install_recovery_plan "$homebrew_state"

          if [ "$single_option_mode" = true ]; then
            if [ "$can_build_source" != true ]; then
              return 1
            fi
            return "$LLAMA_EXIT_GRACEFUL"
          fi

          homebrew_disabled=true
          can_install_homebrew=false
          continue
        fi

        llama_homebrew_state
        homebrew_state="$REPLY"
        can_install_homebrew=false
        homebrew_disabled=false

        continue
      fi

      llama_capture_status install_llama_cpp_with_homebrew "$homebrew_state"
      status=$LLAMA_LAST_STATUS

      if [ "$status" -eq 0 ]; then
        candidate_path="$REPLY"
        REPLY="$candidate_path"
        return 0
      fi

      homebrew_disabled=true
      continue
    fi

    if [ -n "$choice_source" ] && [ "$install_choice" = "$choice_source" ]; then
      llama_capture_status install_llama_cpp_from_source
      status=$LLAMA_LAST_STATUS

      if [ "$status" -eq 0 ]; then
        candidate_path="$REPLY"
        REPLY="$candidate_path"
        return 0
      fi

      if [ "$single_option_mode" = true ]; then
        return 1
      fi

      error 'Source build failed.'
      err 'Please resolve the issue above and try again.'
      err 'Or choose abort setup.'
      continue
    fi

    if [ "$install_choice" = "$choice_abort" ]; then
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    err 'Invalid selection. Enter one of the listed options.'
  done
}

llama_prepare_discovered_homebrew() {
  local brew_bin="$1"
  local homebrew_shellenv_line=''

  if [ -z "$brew_bin" ]; then
    return 1
  fi

  resolve_homebrew_shellenv_line "$brew_bin"
  homebrew_shellenv_line="$REPLY"

  err 'Homebrew was found at:'
  err_blank_line
  err "  $brew_bin"
  err_blank_line
  err 'but is not currently in your PATH.'
  err 'ClawBox can use this Homebrew installation for setup.'
  err 'To make it persistent, run:'
  err "    $homebrew_shellenv_line"
  err "    echo '$homebrew_shellenv_line' >> ~/.zprofile"

  activate_homebrew_bin_in_path "$brew_bin"
}

llama_emit_log_excerpt() {
  local log_path="$1"
  local max_lines="${2:-20}"
  local line=''

  if [ -z "$log_path" ] || [ ! -f "$log_path" ]; then
    return 1
  fi

  while IFS= read -r line; do
    if [ -n "$line" ]; then
      err "$line"
    fi
  done <<EOF
$(tail -n "$max_lines" "$log_path" 2>/dev/null || true)
EOF
}

llama_collect_homebrew_paths_from_log() {
  local log_path="$1"
  local path=''
  local normalized_path=''
  local collected=''

  REPLY=''

  if [ -z "$log_path" ] || [ ! -f "$log_path" ]; then
    return 1
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue

    normalized_path="${path%/}"
    if [[ "$normalized_path" == */* ]]; then
      normalized_path="${normalized_path%/*}"
    fi

    [ -n "$normalized_path" ] || continue

    if printf '%s\n' "$collected" | grep -Fqx "$normalized_path"; then
      continue
    fi

    if [ -n "$collected" ]; then
      collected="$collected
$normalized_path"
    else
      collected="$normalized_path"
    fi
  done <<EOF
$(grep -Eo '/(opt/homebrew|usr/local)([^[:space:]:"]*)' "$log_path" 2>/dev/null || true)
EOF

  REPLY="$collected"
  [ -n "$REPLY" ]
}

llama_summarize_homebrew_failure() {
  local log_path="$1"
  local existing_binary=''
  local affected_paths=''
  local current_user=''

  current_user="$(id -un 2>/dev/null || whoami 2>/dev/null || true)"
  resolve_homebrew_llama_bin >/dev/null 2>&1 || true
  existing_binary="$REPLY"
  llama_collect_homebrew_paths_from_log "$log_path" >/dev/null 2>&1 || true
  affected_paths="$REPLY"

  if grep -qiE 'command not found|No such file or directory' "$log_path"; then
    error 'Homebrew installation failed because the brew executable is not available.'
    err 'Re-run setup after restoring Homebrew or choosing a different install method.'
    return 0
  fi

  if grep -qiE 'another active Homebrew process|brew update.*already running|lock|Resource temporarily unavailable' "$log_path"; then
    error 'Homebrew installation is blocked by another active Homebrew process.'
    err 'Wait for the other brew command to finish, then retry setup.'
    return 0
  fi

  if grep -qiE 'Command Line Tools|xcode-select --install|No developer tools were found' "$log_path"; then
    error 'Homebrew installation failed because Xcode Command Line Tools are missing.'
    err 'Run: xcode-select --install'
    return 0
  fi

  if grep -qiE 'Failed to download|Could not resolve host|timed out|SSL|network|Connection reset' "$log_path"; then
    error 'Homebrew installation failed due to a network or download error.'
    err 'Check connectivity, then retry setup.'
    return 0
  fi

  if grep -qiE 'No available formula|No formulae found|formula .* unavailable' "$log_path"; then
    error 'Homebrew installation failed because the llama.cpp formula is unavailable.'
    err 'Run brew update or install llama.cpp manually, then retry setup.'
    return 0
  fi

  if grep -qiE 'Permission denied|Operation not permitted|not writable|Cannot write|permission.*denied|Failed during: .*chmod|Failed during: .*mkdir' "$log_path"; then
    error 'Homebrew installation failed due to permissions issues.'

    if [ -n "$existing_binary" ]; then
      err 'A shared Homebrew installation was detected, but this account does not currently have permission to modify or upgrade llama.cpp.'
      err 'The existing installation may still be usable.'
      err "Detected binary: $existing_binary"
    else
      err 'This Homebrew installation appears to be owned or managed by another macOS user.'
    fi

    if [ -n "$affected_paths" ]; then
      err 'Affected directories:'
      while IFS= read -r path; do
        [ -n "$path" ] && err "- $path"
      done <<EOF
$affected_paths
EOF
      err 'Suggested fix:'
      err "sudo chown -R ${current_user:-$(whoami)} $(printf '%s ' $affected_paths)"
    else
      err 'Suggested fix:'
      err "sudo chown -R ${current_user:-$(whoami)} /opt/homebrew /usr/local"
    fi

    return 0
  fi

  error 'Homebrew installation failed while installing llama.cpp.'
  err 'Homebrew reported:'
  llama_emit_log_excerpt "$log_path" 20 || err '(no additional Homebrew output captured)'
}

llama_homebrew_available() {
  command -v brew >/dev/null 2>&1
}

resolve_homebrew_bin_path() {
  if [ "${LLAMA_HOMEBREW_CACHE_READY:-false}" = true ] && [ -n "${LLAMA_HOMEBREW_CACHE_BIN:-}" ]; then
    REPLY="$LLAMA_HOMEBREW_CACHE_BIN"
    return 0
  fi

  if llama_detect_homebrew_bin_uncached; then
    REPLY="$REPLY"
    return 0
  fi

  REPLY=''
  return 1
}

is_homebrew_writable() {
  local brew_bin

  if resolve_homebrew_bin_path; then
    brew_bin="$REPLY"
    llama_is_homebrew_writable_for_bin "$brew_bin"
    return
  fi

  return 1
}

resolve_homebrew_shellenv_line() {
  local brew_bin="$1"

  REPLY='eval "$('"$brew_bin"' shellenv)"'
  return 0
}

llama_can_install_homebrew_automatically() {
  command -v curl >/dev/null 2>&1
}

llama_can_auto_install() {
  local homebrew_state="$1"

  if [ "$homebrew_state" = 'usable' ]; then
    return 0
  fi

  if [ "$homebrew_state" = 'not-installed' ] && llama_can_install_homebrew_automatically; then
    return 0
  fi

  return 1
}

print_llama_auto_install_recovery_plan() {
  local homebrew_state="$1"
  local homebrew_bin
  local homebrew_shellenv_line
  local target_user

  if [ "$homebrew_state" = 'installed-not-usable' ]; then
    if [ -n "${SUDO_USER:-}" ]; then
      target_user="$SUDO_USER"
    else
      target_user="$(whoami)"
    fi
    warn 'Automatic installation is not available in this environment, but this can be resolved...'
    err 'You can either fix your environment (recommended), or provide a llama-server binary if you have one available.'
    err_blank_line

    err 'Why:'
    err '- This account does not have administrator privileges'
    err '- Homebrew is installed, but owned by a different user and not writable'
    err_blank_line

    err 'You have two options to fix this:'

    err_blank_line
    err 'Option A (recommended): Fix Homebrew permissions using an admin account'
    err_blank_line
    err '1. Switch to an administrator account on this Mac'
    err '2. Run the following command (this transfers Homebrew ownership to your user):'
    err "   sudo chown -R ${target_user} /opt/homebrew"
    err '3. Log back into your user account'
    err '4. Ensure Homebrew is in your PATH:'
    err '   eval "$(/opt/homebrew/bin/brew shellenv)"'
    err '5. Re-run setup'
    err_blank_line

    err 'Note:'
    err '- This changes Homebrew ownership to your user account'
    err '- Other users can still run brew, but may need admin privileges to install or upgrade packages'

    err_blank_line
    err 'Note (advanced):'
    err '- If multiple users need Homebrew access, you can configure shared group permissions instead of changing ownership.'

    err_blank_line
    err 'Option B (advanced): Install and manage dependencies manually'
    err_blank_line
    err '1. Install llama.cpp on another machine or account'
    err '2. Copy the llama-server binary to this system'
    err '3. Re-run setup and provide the path to the binary when prompted'
    return
  fi

  warn 'Automatic installation is not available in this environment.'
  err 'Why:'

  if ! user_has_sudo; then
    err '- This account does not have admin privileges'
  fi

  case "$homebrew_state" in
    installed-not-in-path)
      err '- Homebrew is installed but not in your PATH'
      ;;
    not-installed)
      err '- Homebrew is not installed'
      ;;
  esac

  if [ "$homebrew_state" = 'not-installed' ] && ! llama_can_install_homebrew_automatically; then
    err '- curl is required to install Homebrew automatically'
  fi

  err_blank_line
  err 'Next steps:'

  if ! user_has_sudo; then
    err '- Switch to an admin account on this Mac'
  fi

  case "$homebrew_state" in
    installed-not-in-path)
      resolve_homebrew_bin_path || return 1
      homebrew_bin="$REPLY"
      resolve_homebrew_shellenv_line "$homebrew_bin"
      homebrew_shellenv_line="$REPLY"
      err '- Activate Homebrew in your shell:'
      err "    $homebrew_shellenv_line"
      err "    echo '$homebrew_shellenv_line' >> ~/.zprofile"
      ;;
    not-installed)
      err '- Install Homebrew: https://brew.sh'
      ;;
  esac

  err '- Switch back to this account and re-run setup'
}

llama_offer_homebrew_path_fix() {
  local brew_bin="$1"
  local shellenv_line
  local profile_path
  local choice
  local profile_status

  resolve_homebrew_shellenv_line "$brew_bin"
  shellenv_line="$REPLY"
  profile_path="$HOME/.zprofile"

  if [ -f "$profile_path" ] && grep -Fqx "$shellenv_line" "$profile_path"; then
    err 'Homebrew is already configured in your shell profile.'
    err 'Activating it for this session...'

    if ! eval "$($brew_bin shellenv)"; then
      llama_fail 'Failed to add Homebrew to the current shell PATH'
      return 1
    fi

    return 0
  fi

  [ -t 0 ] || return 1

  choice="$(llama_read_choice 'Would you like to add Homebrew to your PATH now? [Y/n]')"

  case "$choice" in
    ''|y|Y|yes|Yes|YES)
      if ! eval "$($brew_bin shellenv)"; then
        llama_fail 'Failed to add Homebrew to the current shell PATH'
        return 1
      fi

      profile_status='present'

      if [ -f "$profile_path" ]; then
        if ! grep -Fqx "$shellenv_line" "$profile_path"; then
          printf '%s\n' "$shellenv_line" >> "$profile_path"
          profile_status='added'
        fi
      else
        printf '%s\n' "$shellenv_line" > "$profile_path"
        profile_status='created'
      fi

      err 'Homebrew has been added to your PATH for this session.'

      case "$profile_status" in
        added|created)
          err 'Homebrew PATH has been added to ~/.zprofile.'
          ;;
        present)
          err 'Homebrew PATH is already present in ~/.zprofile.'
          ;;
      esac

      return 0
      ;;
  esac

  return 1
}

llama_homebrew_prefix() {
  brew --prefix 2>/dev/null
}

llama_homebrew_usable() {
  local brew_prefix

  brew_prefix="$(llama_homebrew_prefix)"
  [ -n "$brew_prefix" ] || return 1
  [ -w "$brew_prefix" ]
}

llama_homebrew_state() {
  local brew_bin=''
  local state=''

  if [ "${LLAMA_HOMEBREW_CACHE_READY:-false}" = true ]; then
    REPLY="$LLAMA_HOMEBREW_CACHE_STATE"
    return 0
  fi

  if llama_detect_homebrew_bin_uncached; then
    brew_bin="$REPLY"

    if [ -n "$(command -v brew 2>/dev/null || true)" ]; then
      if llama_is_homebrew_writable_for_bin "$brew_bin"; then
        state='usable'
      else
        state='installed-not-usable'
      fi
    else
      if llama_is_homebrew_writable_for_bin "$brew_bin"; then
        state='installed-not-in-path'
      else
        state='installed-not-usable'
      fi
    fi

    llama_cache_homebrew_state "$state" "$brew_bin"
    return 0
  fi

  llama_cache_homebrew_state 'not-installed' ''
}

activate_homebrew_bin_in_path() {
  local brew_bin="$1"
  local brew_dir

  brew_dir="${brew_bin%/brew}"

  case ":$PATH:" in
    *":$brew_dir:"*)
      return 0
      ;;
  esac

  PATH="$brew_dir:$PATH"
  llama_reset_homebrew_cache
  return 0
}

install_homebrew_automatically() {
  local installer_dir
  local installer_path
  local brew_bin

  installer_dir="$HOME/Library/Caches/ClawBox"
  installer_path="$installer_dir/homebrew-install.sh"

  llama_require_command curl || return 1

  mkdir -p "$installer_dir" || {
    llama_fail "Failed to prepare Homebrew installer directory"
    return 1
  }

  curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer_path" || {
    llama_fail "Failed to download Homebrew installer"
    rm -f "$installer_path"
    return 1
  }

  NONINTERACTIVE=1 CI=1 /bin/bash "$installer_path" || {
    llama_fail "Failed to install Homebrew"
    rm -f "$installer_path"
    return 1
  }

  rm -f "$installer_path"

  if resolve_homebrew_bin_path; then
    brew_bin="$REPLY"

    if [ "$brew_bin" != 'brew' ]; then
      activate_homebrew_bin_in_path "$brew_bin"
    fi
  fi

  llama_reset_homebrew_cache
  llama_homebrew_state
  [ "$REPLY" = 'usable' ]
}

resolve_homebrew_llama_bin() {
  local brew_bin
  local brew_prefix
  local formula_prefix

  if brew_bin="$(command -v llama-server 2>/dev/null)" && [ -x "$brew_bin" ]; then
    REPLY="$brew_bin"
    return 0
  fi

  if ! llama_homebrew_available; then
    return 1
  fi

  formula_prefix="$(brew --prefix llama.cpp 2>/dev/null || true)"
  if [ -n "$formula_prefix" ] && [ -x "$formula_prefix/bin/llama-server" ]; then
    REPLY="$formula_prefix/bin/llama-server"
    return 0
  fi

  brew_prefix="$(brew --prefix 2>/dev/null || true)"
  if [ -n "$brew_prefix" ] && [ -x "$brew_prefix/bin/llama-server" ]; then
    REPLY="$brew_prefix/bin/llama-server"
    return 0
  fi

  if [ -x '/opt/homebrew/bin/llama-server' ]; then
    REPLY='/opt/homebrew/bin/llama-server'
    return 0
  fi

  if [ -x '/usr/local/bin/llama-server' ]; then
    REPLY='/usr/local/bin/llama-server'
    return 0
  fi

  if [ -x "$HOME/.local/bin/llama-server" ]; then
    REPLY="$HOME/.local/bin/llama-server"
    return 0
  fi

  return 1
}

llama_append_unique_binary_candidate() {
  local current_candidates="$1"
  local candidate="$2"
  local existing=''

  REPLY="$current_candidates"

  if ! llama_is_valid_binary "$candidate"; then
    return 1
  fi

  while IFS= read -r existing; do
    [ -n "$existing" ] || continue
    if [ "$existing" = "$candidate" ]; then
      return 0
    fi
  done <<EOF
$current_candidates
EOF

  if [ -n "$current_candidates" ]; then
    REPLY="$current_candidates
$candidate"
  else
    REPLY="$candidate"
  fi

  return 0
}

discover_llama_server_binaries() {
  local candidates=''
  local candidate=''
  local repo_dir=''

  candidate="$(command -v llama-server 2>/dev/null || true)"
  llama_append_unique_binary_candidate "$candidates" "$candidate" >/dev/null 2>&1 || true
  candidates="$REPLY"

  candidate="$(resolve_homebrew_llama_bin 2>/dev/null || true)"
  llama_append_unique_binary_candidate "$candidates" "$candidate" >/dev/null 2>&1 || true
  candidates="$REPLY"

  for candidate in '/opt/homebrew/bin/llama-server' '/usr/local/bin/llama-server' "$HOME/.local/bin/llama-server"; do
    llama_append_unique_binary_candidate "$candidates" "$candidate" >/dev/null 2>&1 || true
    candidates="$REPLY"
  done

  repo_dir="${CLAWBOX_LLAMA_REPO_DIR:-$(default_host_llama_repo_dir)}"
  for candidate in "$repo_dir/build/bin/llama-server" "$repo_dir/build/bin/Release/llama-server"; do
    llama_append_unique_binary_candidate "$candidates" "$candidate" >/dev/null 2>&1 || true
    candidates="$REPLY"
  done

  REPLY="$candidates"
  [ -n "$REPLY" ]
}

choose_existing_llama_binary() {
  local candidate_list=''
  local candidate=''
  local choice=''
  local custom_choice=''
  local abort_choice=''
  local option_number=1
  local default_candidate=''
  local candidates=()

  discover_llama_server_binaries >/dev/null 2>&1 || true
  candidate_list="$REPLY"

  if [ -z "$candidate_list" ]; then
    llama_capture_status prompt_for_manual_llama_bin_path ''
    return "$LLAMA_LAST_STATUS"
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] && candidates+=("$candidate")
  done <<EOF
$candidate_list
EOF

  default_candidate="${candidates[0]:-}"

  err 'Detected llama-server binaries:'
  err_blank_line

  for candidate in "${candidates[@]}"; do
    err "$option_number) $candidate"
    option_number=$((option_number + 1))
  done

  custom_choice="$option_number"
  err "$custom_choice) Enter custom path"
  option_number=$((option_number + 1))
  abort_choice="$option_number"
  err "$abort_choice) Abort setup"
  err_blank_line

  while true; do
    choice="$(llama_read_choice "Choose [1-$abort_choice]:")"

    if [ "$choice" = "$abort_choice" ]; then
      return 1
    fi

    if [ "$choice" = "$custom_choice" ]; then
      llama_capture_status prompt_for_manual_llama_bin_path "$default_candidate"
      return "$LLAMA_LAST_STATUS"
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -lt "$custom_choice" ]; then
      REPLY="${candidates[$((choice - 1))]}"
      return 0
    fi

    err 'Invalid selection. Enter one of the listed options.'
  done
}

install_llama_cpp_with_homebrew() {
  local homebrew_state="$1"
  local homebrew_bin
  local homebrew_shellenv_line
  local installed_path
  local install_log=''

  if [ "$homebrew_state" != 'usable' ]; then
    error 'Cannot use Homebrew install'
    if [ "$homebrew_state" = 'not-installed' ]; then
      err 'Homebrew is not installed.'
    elif [ "$homebrew_state" = 'installed-not-in-path' ]; then
      resolve_homebrew_bin_path || return 1
      homebrew_bin="$REPLY"
      resolve_homebrew_shellenv_line "$homebrew_bin"
      homebrew_shellenv_line="$REPLY"
      err 'Homebrew is installed but not in your PATH.'
      err 'To fix, run:'
      err "    $homebrew_shellenv_line"
      err "    echo '$homebrew_shellenv_line' >> ~/.zprofile"
    elif [ "$homebrew_state" = 'installed-not-usable' ]; then
      err 'Homebrew is installed but not writable by this user.'
      err 'Install Homebrew for this user (recommended):'
      err '    https://brew.sh'
    else
      err 'Homebrew is installed but not writable by the current user.'
      err 'This is commonly caused by Homebrew being installed under a different user account.'
    fi
    return 1
  fi

  err 'Installing llama.cpp with Homebrew...'
  install_log="$(mktemp)"
  brew install llama.cpp >"$install_log" 2>&1 || {
    llama_summarize_homebrew_failure "$install_log"
    rm -f "$install_log"
    return 1
  }

  rm -f "$install_log"

  if resolve_homebrew_llama_bin >/dev/null; then
    installed_path="$REPLY"
    err "Installed at: $installed_path"
    REPLY="$installed_path"
    return 0
  fi

  llama_fail "Failed to locate llama-server binary after build"
  return 1
}

install_llama_cpp_from_source() {
  local repo_dir
  local repo_parent
  local clone_dir
  local origin_url
  local primary_binary_path
  local release_binary_path
  local build_pid

  repo_dir="${CLAWBOX_LLAMA_REPO_DIR:-$(default_host_llama_repo_dir)}"
  [ -n "$repo_dir" ] || {
    llama_fail "Unable to derive llama.cpp repository path"
    return 1
  }

  repo_parent="$(dirname "$repo_dir")"
  clone_dir="$repo_parent/llama.cpp"
  primary_binary_path="$repo_dir/build/bin/llama-server"
  release_binary_path="$repo_dir/build/bin/Release/llama-server"

  if [ -x "$primary_binary_path" ]; then
    REPLY="$primary_binary_path"
    err 'Using existing llama.cpp build'
    return 0
  fi

  if [ -x "$release_binary_path" ]; then
    REPLY="$release_binary_path"
    err 'Using existing llama.cpp build'
    return 0
  fi

  llama_require_command git || return 1
  if ! command -v cmake >/dev/null 2>&1; then
    error 'cmake is required to build llama.cpp from source'
    err 'Install cmake and re-run setup.'
    err 'Options:'
    err '  - Install via Xcode Command Line Tools: xcode-select --install'
    err '  - Or install cmake manually and ensure it is in PATH'
    return 1
  fi

  err 'Building llama.cpp from source'
  out 'This step may take several minutes'

  mkdir -p "$repo_parent"

  if [ ! -d "$repo_dir/.git" ]; then
    (
      cd "$repo_parent"
      git clone https://github.com/ggerganov/llama.cpp.git
    ) || {
      llama_fail "Failed to clone llama.cpp"
      return 1
    }

    repo_dir="$repo_parent/llama.cpp"
  else
    origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"

    case "$origin_url" in
      git@github.com:*)
        git -C "$repo_dir" remote set-url origin https://github.com/ggerganov/llama.cpp.git || {
          llama_fail "Failed to normalize llama.cpp remote to HTTPS"
          return 1
        }
        ;;
    esac

    repo_dir="$repo_parent/llama.cpp"
  fi

  (
    cd "$repo_dir"
    cmake -B build >/dev/null 2>&1
    cmake --build build --config Release >/dev/null 2>&1
  ) &
  build_pid=$!

  llama_spinner "$build_pid"
  wait "$build_pid" || {
    status_end 'llama.cpp build failed.' 'error'
    llama_fail "Failed to build llama.cpp"
    return 1
  }

  status_end 'llama.cpp build completed.' 'success'

  primary_binary_path="$repo_dir/build/bin/llama-server"
  release_binary_path="$repo_dir/build/bin/Release/llama-server"

  if [ -x "$primary_binary_path" ]; then
    REPLY="$primary_binary_path"
    return 0
  fi

  if [ -x "$release_binary_path" ]; then
    REPLY="$release_binary_path"
    return 0
  fi

  llama_fail "Unable to locate llama-server after Homebrew install"
  return 1
}

print_llama_cpp_install_method_options() {
  local homebrew_state="$1"
  local can_use_homebrew_action="${2:-false}"
  local can_build_source="${3:-true}"
  local homebrew_bin
  local homebrew_shellenv_line
  local option_number=1

  err_blank_line

  case "$homebrew_state" in
    not-installed)
      err 'Homebrew is not installed.'
      err_blank_line
      ;;
    installed-not-usable)
      err 'Homebrew is installed but not writable by this user.'
      err 'Install Homebrew for this user (recommended).'
      err_blank_line
      ;;
    installed-not-in-path)
      resolve_homebrew_bin_path || return 1
      homebrew_bin="$REPLY"
      resolve_homebrew_shellenv_line "$homebrew_bin"
      homebrew_shellenv_line="$REPLY"
      err 'Homebrew is installed but not in your PATH.'
      err 'To fix, run:'
      err "    $homebrew_shellenv_line"
      err "    echo '$homebrew_shellenv_line' >> ~/.zprofile"
      err_blank_line
      ;;
  esac

  err 'Install llama.cpp automatically using:'
  err_blank_line
  if [ "$can_use_homebrew_action" = true ]; then
    if [ "$homebrew_state" = 'usable' ]; then
      err "$option_number) Use Homebrew install"
    else
      err "$option_number) Install Homebrew automatically"
    fi
    option_number=$((option_number + 1))
  fi

  if [ "$can_build_source" = true ]; then
    err "$option_number) Clone via HTTPS and build locally"
    option_number=$((option_number + 1))
  fi

  err "$option_number) Abort setup"
  err_blank_line
}

print_llama_bin_resolution_options() {
  local can_auto_install="$1"
  local option_number=1

  err_blank_line
  err 'llama-server binary not found.'
  err_blank_line
  err 'Options:'

  if [ "$can_auto_install" = true ]; then
    err "$option_number) Install llama.cpp automatically"
    option_number=$((option_number + 1))
  fi

  err "$option_number) Use existing llama-server binary"
  option_number=$((option_number + 1))
  err "$option_number) Abort setup"
  err_blank_line
}

prompt_for_manual_llama_bin_path() {
  local candidate="$1"
  local attempt=1

  while [ "$attempt" -le 3 ]; do
    prompt_with_default 'Enter full path to llama-server (or press Enter to cancel)' "$candidate" true
    candidate="$REPLY"

    if [ -z "$candidate" ]; then
      out 'Setup paused. Complete Option A, B, or C, then re-run setup to continue where you left off.'
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    if llama_is_valid_binary "$candidate"; then
      REPLY="$candidate"
      return 0
    fi

    if [ "$attempt" -eq 3 ]; then
      error 'Unable to locate a valid llama-server binary.'
      err 'Please install it and re-run setup.'
      return 1
    fi

    error 'Invalid path. Enter an executable llama-server binary path or press Ctrl+C to abort.'
    attempt=$((attempt + 1))
  done

  return 1
}

resolve_llama_bin_path() {
  local candidate="$1"
  local choice
  local homebrew_state
  local homebrew_bin
  local homebrew_shellenv_line
  local can_auto_install=false
  local choice_auto_install
  local choice_existing
  local choice_abort
  local status

  if [ -n "$candidate" ] && ! llama_is_valid_binary "$candidate"; then
    candidate=''
  fi

  llama_announce_homebrew_detection_once
  llama_homebrew_state
  homebrew_state="$REPLY"

  if [ "$homebrew_state" = 'installed-not-in-path' ]; then
    if resolve_homebrew_bin_path; then
      homebrew_bin="$REPLY"
      llama_prepare_discovered_homebrew "$homebrew_bin" || return 1

      llama_offer_homebrew_path_fix "$homebrew_bin" || true
      llama_homebrew_state
      homebrew_state="$REPLY"
    fi
  fi

  if llama_can_auto_install "$homebrew_state"; then
    can_auto_install=true
  fi

  command -v prompt_with_default >/dev/null 2>&1 || {
    llama_fail "Required function not found: prompt_with_default"
    return 1
  }

  if [ "$can_auto_install" != true ] && ! llama_is_valid_binary "$candidate"; then
    print_llama_auto_install_recovery_plan "$homebrew_state"
    err_blank_line
    err 'Option C (alternative): Use an existing llama-server binary'
    err_blank_line
    err 'If you already have a llama-server binary, enter its full path below.'
    err_blank_line

    llama_capture_status prompt_for_manual_llama_bin_path "$candidate"
    status=$LLAMA_LAST_STATUS

    if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    if [ "$status" -eq 0 ]; then
      return 0
    fi

    return 1
  fi

  while ! llama_is_valid_binary "$candidate"; do
    choice_auto_install='1'
    choice_existing='2'
    choice_abort='3'

    print_llama_bin_resolution_options "$can_auto_install"

    while true; do
      choice="$(llama_read_choice 'Choose [1-3]:')"

      if [ "$choice" != "$choice_auto_install" ] && [ "$choice" != "$choice_existing" ] && [ "$choice" != "$choice_abort" ]; then
        err 'Invalid selection. Enter one of the listed options.'
        continue
      fi

      case "$choice" in
        "$choice_auto_install")
          llama_capture_status install_llama_cpp_automatically
          status=$LLAMA_LAST_STATUS

          if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
            return "$LLAMA_EXIT_GRACEFUL"
          fi

          if [ "$status" -ne 0 ]; then
            continue
          fi

          candidate="$REPLY"
          break
          ;;
        "$choice_existing")
          llama_capture_status choose_existing_llama_binary
          status=$LLAMA_LAST_STATUS

          if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
            return "$LLAMA_EXIT_GRACEFUL"
          fi

          if [ "$status" -eq 0 ]; then
            candidate="$REPLY"
          fi
          break
          ;;
        "$choice_abort")
          return 1
          ;;
        *)
          err 'Invalid selection. Enter one of the listed options.'
          ;;
      esac
    done
  done

  REPLY="$candidate"
  return 0
}