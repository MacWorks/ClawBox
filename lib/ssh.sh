SSH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SSH_LIB_DIR/log-paths.sh"

if ! command -v log_error >/dev/null 2>&1; then
  echo "[ERROR] Required function not found: log_error"
  return 1
fi

vm_launchd_path() {
  printf '%s\n' "${CLAWBOX_VM_LAUNCHD_PATH:-/opt/homebrew/bin:/opt/homebrew/sbin:/opt/homebrew/opt/node@22/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin}"
}

vm_openclaw_resolution_command() {
  REPLY='clawbox_vm_openclaw_bin="$(command -v openclaw 2>/dev/null || true)"; if [ -z "$clawbox_vm_openclaw_bin" ] || [ ! -x "$clawbox_vm_openclaw_bin" ]; then for clawbox_vm_candidate in /opt/homebrew/bin/openclaw /usr/local/bin/openclaw "$HOME/.local/bin/openclaw"; do if [ -x "$clawbox_vm_candidate" ]; then clawbox_vm_openclaw_bin="$clawbox_vm_candidate"; break; fi; done; fi; [ -n "$clawbox_vm_openclaw_bin" ] && [ -x "$clawbox_vm_openclaw_bin" ]'
}

resolve_vm_openclaw_bin_path() {
  local resolution_command=''
  local resolved_bin=''

  vm_openclaw_resolution_command
  resolution_command="$REPLY"
  resolved_bin="$(
    ssh_check_zsh "$(printf '%s\n' "$resolution_command")
printf '%s\\n' \"\$clawbox_vm_openclaw_bin\""
  )" || return 1

  [ -n "$resolved_bin" ] || return 1
  REPLY="$resolved_bin"
}

vm_openclaw_gateway_pid_list_command() {
  REPLY='ps -axo pid=,comm=,args= | awk -v gateway_pattern='"'"'(^|[[:space:]])gateway([[:space:]]|$)'"'"' '\''$2 == "openclaw" && $0 ~ gateway_pattern { print $1 }'\'''
}

vm_openclaw_runtime_pid_list_command() {
  REPLY='ps -axo pid=,comm=,args= | awk -v gateway_pattern='"'"'(^|[[:space:]])gateway([[:space:]]|$)'"'"' '\''$2 == "openclaw" && ($0 ~ gateway_pattern || $3 == "openclaw") { print $1 }'\'''
}

vm_openclaw_gateway_port() {
  printf '%s\n' "${CLAWBOX_OPENCLAW_GATEWAY_PORT:-18789}"
}

vm_openclaw_gateway_listener_pid_list_command() {
  local gateway_port=''

  gateway_port="$(vm_openclaw_gateway_port)"
  REPLY="if command -v lsof >/dev/null 2>&1; then
  lsof -nP -t -iTCP:$gateway_port -sTCP:LISTEN 2>/dev/null | while IFS= read -r pid; do
    [ -n \"\$pid\" ] || continue
    command_path=\$(ps -p \"\$pid\" -o comm= 2>/dev/null | awk 'NF { print \$1; exit }')
    if [ \"\${command_path##*/}\" = 'openclaw' ]; then
      printf '%s\\n' \"\$pid\"
    fi
  done || true
fi"
}

vm_openclaw_service_label() {
  printf '%s\n' "${CLAWBOX_VM_OPENCLAW_SERVICE_LABEL:-com.clawbox.openclaw}"
}

vm_openclaw_launchctl_domain_command() {
  REPLY='uid=$(id -u)
domain="gui/$uid"'
}

vm_openclaw_launchagent_relpath() {
  local label=''

  label="$(vm_openclaw_service_label)"
  printf '%s\n' "Library/LaunchAgents/$label.plist"
}

require_vm_host() {
  if [ -z "${VM_HOST:-}" ]; then
    log_error "VM_HOST is not set"
    return 1
  fi
}

ssh_exec() {
  require_vm_host || return 1

  ssh -n "$VM_HOST" "$@"
}

ssh_check() {
  require_vm_host || return 1

  ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$VM_HOST" "$@"
}

ssh_run_quiet() {
  require_vm_host || return 1

  ssh_exec "$@" >/dev/null 2>&1
}

ssh_ensure_dir() {
  require_vm_host || return 1

  if [ -z "${1:-}" ]; then
    log_error "Missing path for ssh_ensure_dir"
    return 1
  fi

  ssh_exec "mkdir -p \"$1\""
}

write_text_file() {
  local path="$1"
  shift

  printf '%s\n' "$@" > "$path"
}

write_openclaw_launchagent_plist() {
  local path="$1"
  local label="$2"
  local binary_path="$3"
  local launchd_path="$4"
  local stdout_path="$5"
  local stderr_path="$6"

  cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$binary_path</string>
    <string>gateway</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$launchd_path</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$stdout_path</string>
  <key>StandardErrorPath</key>
  <string>$stderr_path</string>
</dict>
</plist>
EOF
}

ssh_run_uploaded_zsh_script() {
  local script_body="$1"
  local ssh_mode="$2"
  local local_script=''
  local remote_name=''
  local remote_rel=''
  local remote_path=''
  local status=0

  require_vm_host || return 1

  local_script="$(mktemp)" || {
    log_error "Unable to create temporary script file"
    return 1
  }

  remote_name="clawbox-ssh-${$}-${RANDOM}.zsh"
  remote_rel=".clawbox/tmp/$remote_name"
  remote_path="\$HOME/.clawbox/tmp/$remote_name"

  write_text_file "$local_script" '#!/bin/zsh' 'set -euo pipefail' "$script_body"

  if ! zsh -n "$local_script"; then
    rm -f "$local_script"
    return 1
  fi

  if ! ssh_exec 'mkdir -p ~/.clawbox/tmp'; then
    rm -f "$local_script"
    return 1
  fi

  if ! scp -q "$local_script" "$VM_HOST:$remote_rel" </dev/null; then
    rm -f "$local_script"
    return 1
  fi

  rm -f "$local_script"

  if [ "$ssh_mode" = 'check' ]; then
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$VM_HOST" "zsh -l \"$remote_path\""
    status=$?
  else
    ssh -n "$VM_HOST" "zsh -l \"$remote_path\""
    status=$?
  fi

  ssh -n "$VM_HOST" "rm -f \"$remote_path\"" >/dev/null 2>&1 || true
  return "$status"
}

ssh_exec_zsh() {
  require_vm_host || return 1

  ssh_run_uploaded_zsh_script "$1" 'exec'
}

ssh_check_zsh() {
  require_vm_host || return 1

  ssh_run_uploaded_zsh_script "$1" 'check'
}

stop_openclaw() {
  local label=''
  local runtime_pid_command=''
  local listener_pid_command=''
  local remote_command=''

  label="$(vm_openclaw_service_label)"
  vm_openclaw_runtime_pid_list_command
  runtime_pid_command="$REPLY"
  vm_openclaw_gateway_listener_pid_list_command
  listener_pid_command="$REPLY"
  vm_openclaw_launchctl_domain_command
  remote_command="label=$(printf '%q' "$label")
$(printf '%s\n' "$REPLY")
service_target=\"\$domain/\$label\"
plist=\"\$HOME/$(vm_openclaw_launchagent_relpath)\"
if launchctl print \"\$service_target\" >/dev/null 2>&1; then
  launchctl bootout \"\$domain\" \"\$plist\" >/dev/null 2>&1 || launchctl bootout \"\$service_target\" >/dev/null 2>&1 || true
fi
quiet=0
attempts=0
while [ \"\$attempts\" -lt 12 ]; do
  pids=\$(
  {
    $runtime_pid_command
    $listener_pid_command
  } | awk 'NF && !seen[\$0]++'
)
  if [ -n \"\$pids\" ]; then
    printf '%s\\n' \"\$pids\" | xargs kill >/dev/null 2>&1 || true
    quiet=0
  else
    quiet=\$((quiet + 1))
    if [ \"\$quiet\" -ge 2 ]; then
      exit 0
    fi
  fi
  attempts=\$((attempts + 1))
  sleep 0.5
done
printf 'OpenClaw gateway process remained after stop request: %s\\n' \"\$pids\" >&2
exit 1"

  ssh_exec_zsh "$remote_command"
}

start_openclaw() {
  local label=''
  local runtime_pid_command=''
  local launchd_path=''
  local resolved_bin=''
  local local_plist=''
  local remote_command=''
  local remote_plist_rel=''
  local start_state_file=''
  local start_state=''
  local stdout_path=''
  local stderr_path=''

  OPENCLAW_START_STATE=''
  label="$(vm_openclaw_service_label)"
  launchd_path="$(vm_launchd_path)"
  stdout_path="$(clawbox_openclaw_vm_stdout_log_default)" || {
    log_error "VM_RUNTIME_PATH is not set for OpenClaw log paths"
    return 1
  }
  stderr_path="$(clawbox_openclaw_vm_stderr_log_default)" || {
    log_error "VM_RUNTIME_PATH is not set for OpenClaw log paths"
    return 1
  }
  vm_openclaw_resolution_command
  resolved_bin="$({
    ssh_exec_zsh "$(printf '%s\n' "$REPLY")
printf '%s\\n' \"\$clawbox_vm_openclaw_bin\""
  })" || return 1

  if [ -z "$resolved_bin" ]; then
    log_error "Unable to resolve openclaw binary on VM"
    return 1
  fi
  OPENCLAW_BIN="$resolved_bin"

  vm_openclaw_runtime_pid_list_command
  runtime_pid_command="$REPLY"

  local_plist="$(mktemp)" || {
    log_error "Unable to create temporary launchd plist"
    return 1
  }

  write_openclaw_launchagent_plist \
    "$local_plist" \
    "$label" \
    "$resolved_bin" \
    "$launchd_path" \
    "$stdout_path" \
    "$stderr_path"

  if ! ssh_exec "mkdir -p ~/Library/LaunchAgents \"$(dirname "$stdout_path")\""; then
    rm -f "$local_plist"
    return 1
  fi

  remote_plist_rel="$(vm_openclaw_launchagent_relpath)"
  if ! scp -q "$local_plist" "$VM_HOST:$remote_plist_rel" </dev/null; then
    rm -f "$local_plist"
    return 1
  fi

  rm -f "$local_plist"

  vm_openclaw_launchctl_domain_command
  remote_command="label=$(printf '%q' "$label")
$(printf '%s\n' "$REPLY")
service_target=\"\$domain/\$label\"
plist=\"\$HOME/$(vm_openclaw_launchagent_relpath)\"
  if launchctl print \"\$service_target\" >/dev/null 2>&1 && $runtime_pid_command; then
  printf '%s\\n' 'already-loaded'
  exit 0
fi
if launchctl print \"\$service_target\" >/dev/null 2>&1; then
  launchctl bootout \"\$domain\" \"\$plist\" >/dev/null 2>&1 || launchctl bootout \"\$service_target\" >/dev/null 2>&1 || true
  bootout_wait=0
  while launchctl print \"\$service_target\" >/dev/null 2>&1; do
    bootout_wait=\$((bootout_wait + 1))
    if [ \"\$bootout_wait\" -ge 10 ]; then
      printf 'OpenClaw launchd service stayed loaded after bootout: %s\\n' \"\$service_target\" >&2
      exit 1
    fi
    sleep 0.5
  done
fi
if ! bootstrap_output=\$(launchctl bootstrap \"\$domain\" \"\$plist\" 2>&1); then
  printf 'OpenClaw bootstrap command failed: launchctl bootstrap "%s" "%s"\\n' \"\$domain\" \"\$plist\" >&2
  printf '%s\\n' \"\$bootstrap_output\" >&2
  exit 1
fi
launchctl kickstart -k \"\$service_target\" >/dev/null 2>&1 || true
if ! launchctl print \"\$service_target\" >/dev/null 2>&1; then
  printf 'OpenClaw launchd service did not load after bootstrap: %s\\n' \"\$service_target\" >&2
  exit 1
fi
printf '%s\\n' 'bootstrapped'"
  start_state_file="$(mktemp)" || {
    log_error "Unable to capture OpenClaw launchd start state"
    return 1
  }
  if ! ssh_exec_zsh "$remote_command" > "$start_state_file"; then
    rm -f "$start_state_file"
    return 1
  fi
  IFS= read -r start_state < "$start_state_file" || start_state=''
  rm -f "$start_state_file"
  OPENCLAW_START_STATE="${start_state:-bootstrapped}"

  ssh_exec_zsh "label=$(printf '%q' "$label")
$(printf '%s\n' "$REPLY")
service_target=\"\$domain/\$label\"
attempts=0
  until launchctl print \"\$service_target\" >/dev/null 2>&1 && $runtime_pid_command; do
  attempts=\$((attempts + 1))
  if [ \"\$attempts\" -ge 20 ]; then
    printf 'OpenClaw launchd service did not reach a running state: %s\\n' \"\$service_target\" >&2
    exit 1
  fi
  sleep 0.5
done"
}
