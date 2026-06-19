# Dependencies are sourced or defined by scripts/setup.sh before these
# functions run: setup env helpers and error_exit.
#
# This phase validates setup files and host commands, loads the environment,
# and validates the VM values required by deployment.

require_nonempty() {
  local message="$1"
  local value="$2"

  if [ -z "$value" ]; then
    error_exit "$message"
  fi
}

require_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    error_exit "Missing required file: $path"
  fi
}

require_value() {
  local name="$1"
  require_nonempty "Missing required value in .env: $name" "${!name:-}"
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    error_exit "Required command not found: $name"
  fi
}

validate_setup_requirements() {
  require_file "$ENV_FILE" || return $?
  require_file "$GENERATE_SCRIPT" || return $?
  require_file "$PROVISION_SCRIPT" || return $?
  require_command "jq" || return $?
  require_command "ssh" || return $?
  require_command "scp" || return $?
  require_command "shasum" || return $?

  source_env_file || return $?

  require_value "VM_HOST" || return $?
  require_value "VM_RUNTIME_PATH" || return $?
}
