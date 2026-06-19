CLAWBOX_LOG_PATHS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

clawbox_repo_root() {
  if [ -n "${BASE_DIR:-}" ] && [ -d "$BASE_DIR" ]; then
    printf '%s\n' "$BASE_DIR"
    return 0
  fi

  printf '%s\n' "$(cd "$CLAWBOX_LOG_PATHS_DIR/.." && pwd)"
}

clawbox_logs_root_dir() {
  printf '%s/logs\n' "$(clawbox_repo_root)"
}

clawbox_log_category_dir() {
  case "$1" in
    tests|runtime|setup|dev|ssh|vm|archive)
      printf '%s/%s\n' "$(clawbox_logs_root_dir)" "$1"
      ;;
    *)
      return 1
      ;;
  esac
}

clawbox_ensure_log_dir() {
  mkdir -p "$1"
}

clawbox_ensure_standard_log_dirs() {
  local category=''

  for category in tests runtime setup dev ssh vm archive; do
    clawbox_ensure_log_dir "$(clawbox_log_category_dir "$category")"
  done
}

clawbox_named_log_path() {
  local category="$1"
  local name="$2"

  printf '%s/%s\n' "$(clawbox_log_category_dir "$category")" "$name"
}

clawbox_log_timestamp() {
  date '+%Y%m%d-%H%M%S'
}

clawbox_timestamped_log_path() {
  local category="$1"
  local prefix="$2"
  local extension="${3:-log}"

  printf '%s/%s-%s.%s\n' "$(clawbox_log_category_dir "$category")" "$prefix" "$(clawbox_log_timestamp)" "$extension"
}

clawbox_llama_system_stdout_log_default() {
  clawbox_named_log_path runtime 'clawbox-llama-system.out.log'
}

clawbox_llama_system_stderr_log_default() {
  clawbox_named_log_path runtime 'clawbox-llama-system.err.log'
}

clawbox_llama_user_stdout_log_default() {
  clawbox_named_log_path runtime 'clawbox-llama-user.out.log'
}

clawbox_llama_user_stderr_log_default() {
  clawbox_named_log_path runtime 'clawbox-llama-user.err.log'
}

clawbox_startutmvm_stdout_log_default() {
  clawbox_named_log_path vm 'clawbox-startutmvm.out.log'
}

clawbox_startutmvm_stderr_log_default() {
  clawbox_named_log_path vm 'clawbox-startutmvm.err.log'
}

clawbox_vm_logs_root_dir() {
  [ -n "${VM_RUNTIME_PATH:-}" ] || return 1
  printf '%s/logs\n' "$VM_RUNTIME_PATH"
}

clawbox_vm_log_category_dir() {
  local category="$1"

  case "$category" in
    tests|runtime|setup|dev|ssh|vm|archive)
      printf '%s/%s\n' "$(clawbox_vm_logs_root_dir)" "$category"
      ;;
    *)
      return 1
      ;;
  esac
}

clawbox_vm_named_log_path() {
  local category="$1"
  local name="$2"

  printf '%s/%s\n' "$(clawbox_vm_log_category_dir "$category")" "$name"
}

clawbox_openclaw_vm_stdout_log_default() {
  clawbox_vm_named_log_path runtime 'openclaw.out.log'
}

clawbox_openclaw_vm_stderr_log_default() {
  clawbox_vm_named_log_path runtime 'openclaw.err.log'
}
