configs_match() {
  local local_config_sha
  local remote_config_sha
  local remote_exec=''

  if command -v ssh_exec_vm >/dev/null 2>&1; then
    remote_exec='ssh_exec_vm'
  elif command -v ssh_exec_zsh >/dev/null 2>&1; then
    remote_exec='ssh_exec_zsh'
  else
    log_error "Required function not found: ssh_exec_vm"
    return 1
  fi
  [ -n "${CONFIG_PATH:-}" ] || {
    log_error "Required variable not set: CONFIG_PATH"
    return 1
  }
  [ -n "${REMOTE_CONFIG_PATH:-}" ] || {
    log_error "Required variable not set: REMOTE_CONFIG_PATH"
    return 1
  }

  # Compare normalized JSON content instead of raw file bytes so whitespace,
  # key ordering, and other formatting-only differences do not trigger a prompt.
  # OpenClaw mutates gateway.auth and meta at runtime, so those fields are
  # excluded from the hash to avoid treating runtime state as config drift.
  local_config_sha="$(jq -cS 'del(.gateway.auth, .meta)' "$CONFIG_PATH" | shasum -a 256 | awk '{print $1}')"
  remote_config_sha="$(
    "$remote_exec" "jq -cS 'del(.gateway.auth, .meta)' $REMOTE_CONFIG_PATH 2>/dev/null | shasum -a 256" \
    2>/dev/null | awk '{print $1}' || echo ""
  )"

  [ -n "$remote_config_sha" ] && [ "$local_config_sha" = "$remote_config_sha" ]
}
