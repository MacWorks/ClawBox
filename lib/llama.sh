LLAMA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$LLAMA_LIB_DIR/output.sh"

# Exit codes:
# 0 = success
# 42 = graceful exit (no error, user action required)
# other non-zero = failure
LLAMA_EXIT_GRACEFUL=42
LLAMA_EXIT_RETRY=43
LLAMA_EXIT_CHANGE_PORT=44
LLAMA_LAST_STATUS=0

llama_capture_status() {
  set +e
  "$@"
  LLAMA_LAST_STATUS=$?
  set -e
  return 0
}

llama_fail() {
  if command -v log_error >/dev/null 2>&1; then
    log_error "$1"
  else
    error "$1"
  fi

  return 1
}

llama_read_choice() {
  local prompt_label="$1"
  local value=''

  prompt "$prompt_label"
  IFS= read -r value || true
  prompt_complete

  REPLY="$value"
  printf '%s\n' "$value"
  return 0
}

llama_spinner() {
  local pid="$1"
  status_wait_for_pid "$pid" 'Building llama.cpp...'
}

user_has_sudo() {
  sudo -n true >/dev/null 2>&1
}

llama_is_valid_binary() {
  local path="$1"

  [ -n "$path" ] && [ -x "$path" ]

  return $?
}

llama_require_value() {
  local name="$1"

  if [ -z "${!name:-}" ]; then
    llama_fail "Missing required value: $name"
    return 1
  fi
}

llama_require_command() {
  local name="$1"

  if ! command -v "$name" >/dev/null 2>&1; then
    llama_fail "Required command not found: $name"
    return 1
  fi
}

source "$LLAMA_LIB_DIR/llama/llama-runtime.sh"
source "$LLAMA_LIB_DIR/llama/llama-health.sh"
source "$LLAMA_LIB_DIR/llama/llama-install.sh"