source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

openclaw_runtime_launchctl_domain_command() {
  if command -v vm_openclaw_launchctl_domain_command >/dev/null 2>&1; then
    vm_openclaw_launchctl_domain_command
    return 0
  fi

  REPLY='uid=$(id -u)
domain="gui/$uid"'
}

openclaw_runtime_zsh_check() {
  if command -v ssh_check_zsh >/dev/null 2>&1; then
    ssh_check_zsh "$1"
    return $?
  fi

  ssh_check "$1"
}

openclaw_runtime_service_label() {
  if command -v vm_openclaw_service_label >/dev/null 2>&1; then
    vm_openclaw_service_label
    return 0
  fi

  printf '%s\n' 'com.clawbox.openclaw'
}

openclaw_runtime_native_service_label() {
  printf '%s\n' 'ai.openclaw.gateway'
}

openclaw_runtime_has_live_process() {
  openclaw_runtime_zsh_check \
    'ps -axo pid=,comm=,args= | awk '\''$2 == "openclaw" && $0 ~ /(^|[[:space:]])gateway([[:space:]]|$)/ { found=1 } END { exit(found ? 0 : 1) }'\'''
}

openclaw_runtime_has_any_process() {
  openclaw_runtime_zsh_check \
    'ps -axo pid=,comm= | awk '\''$2 == "openclaw" { found=1 } END { exit(found ? 0 : 1) }'\'''
}

openclaw_runtime_has_active_service() {
  local label=''

  label="$(openclaw_runtime_service_label)"
  openclaw_runtime_launchctl_domain_command
  openclaw_runtime_zsh_check \
    "label=$(printf '%q' "$label")
$(printf '%s\n' "$REPLY")
launchctl print \"\$domain/\$label\" >/dev/null 2>&1"
}

openclaw_runtime_has_running_gateway_service() {
  local label=''

  label="$(openclaw_runtime_service_label)"
  openclaw_runtime_launchctl_domain_command
  openclaw_runtime_zsh_check \
    "label=$(printf '%q' "$label")
$(printf '%s\n' "$REPLY")
gateway_service_output=\$(launchctl print \"\$domain/\$label\" 2>/dev/null) || exit 1
printf '%s\n' \"\$gateway_service_output\" | grep -Eq '(^|[[:space:]])(state|job state) = running'
printf '%s\n' \"\$gateway_service_output\" | grep -Eq 'pid = [1-9][0-9]*'
printf '%s\n' \"\$gateway_service_output\" | grep -Fq 'openclaw'
printf '%s\n' \"\$gateway_service_output\" | grep -Eq '(^|[[:space:]])gateway([[:space:]]|\$)'"
}

openclaw_runtime_has_running_native_gateway_service() {
  local label=''

  label="$(openclaw_runtime_native_service_label)"
  openclaw_runtime_launchctl_domain_command
  openclaw_runtime_zsh_check \
    "label=$(printf '%q' "$label")
$(printf '%s\n' "$REPLY")
gateway_service_output=\$(launchctl print \"\$domain/\$label\" 2>/dev/null) || exit 1
printf '%s\n' \"\$gateway_service_output\" | grep -Eq '(^|[[:space:]])(state|job state) = running'
printf '%s\n' \"\$gateway_service_output\" | grep -Eq 'pid = [1-9][0-9]*'
printf '%s\n' \"\$gateway_service_output\" | grep -Fq 'openclaw'
printf '%s\n' \"\$gateway_service_output\" | grep -Eq '(^|[[:space:]])gateway([[:space:]]|\$)'"
}

openclaw_runtime_has_launchd_gateway() {
  openclaw_runtime_has_running_gateway_service && openclaw_runtime_has_any_process
}

openclaw_runtime_has_manual_process() {
  openclaw_runtime_has_any_process || return 1
  openclaw_runtime_has_launchd_gateway && return 1
  return 0
}

openclaw_runtime_report_start() {
  case "${OPENCLAW_START_STATE:-bootstrapped}" in
    already-loaded)
      out "OpenClaw launchd service is already loaded on the VM."
      OPENCLAW_RUNTIME_MANAGEMENT_STATE='managed by VM launchd'
      ;;
    *)
      success "OpenClaw started as a VM user launchd service."
      OPENCLAW_RUNTIME_MANAGEMENT_STATE='managed by VM launchd'
      ;;
  esac
  out 'OpenClaw runtime: managed by VM launchd.'
}

openclaw_runtime_is_active() {
  if openclaw_runtime_has_launchd_gateway; then
    OPENCLAW_RUNTIME_MANAGEMENT_STATE='managed by VM launchd'
    return 0
  fi

  if openclaw_runtime_has_running_native_gateway_service; then
    OPENCLAW_RUNTIME_MANAGEMENT_STATE='managed by native OpenClaw LaunchAgent'
    return 0
  fi

  if openclaw_runtime_has_manual_process; then
    OPENCLAW_RUNTIME_MANAGEMENT_STATE='running manually'
    return 0
  fi

  openclaw_runtime_has_active_service >/dev/null 2>&1 || true

  OPENCLAW_RUNTIME_MANAGEMENT_STATE='not running'
  return 1
}

detect_openclaw_runtime_state() {
  NEEDS_PROVISIONING=false
  IS_RUNNING=false

  if ! openclaw_runtime_zsh_check \
    'command -v openclaw >/dev/null 2>&1 && openclaw --version >/dev/null 2>&1'
  then
    NEEDS_PROVISIONING=true
  fi

  if [ "$NEEDS_PROVISIONING" = false ]; then
    if openclaw_runtime_is_active
    then
      IS_RUNNING=true
    fi
  fi
}

handle_openclaw_runtime_state() {
  local manage_manual_choice=''

  if [ "$CONFIG_OVERWRITTEN" = true ] && openclaw_runtime_has_running_native_gateway_service; then
    success 'Config updated.'
    warn 'OpenClaw is already running under the native OpenClaw LaunchAgent.'
    out 'ClawBox will not stop or replace the native gateway automatically.'
    OPENCLAW_RUNTIME_MANAGEMENT_STATE='managed by native OpenClaw LaunchAgent'
    return 0
  fi

  if [ "$CONFIG_OVERWRITTEN" = true ]; then
    stop_openclaw

    if [ "${OPENCLAW_AUTOSTART:-false}" = "true" ]; then
      if ! start_openclaw; then
        return 1
      fi
      success "Config updated."
      openclaw_runtime_report_start
    else
      success "Config updated."
      out "OpenClaw is not running."
      out "Start with: openclaw gateway"
    fi
  elif [ "$IS_RUNNING" = false ] && [ "${OPENCLAW_AUTOSTART:-false}" = "true" ]; then
    if ! start_openclaw; then
      return 1
    fi
    openclaw_runtime_report_start
  elif [ "$IS_RUNNING" = true ]; then
    if [ "${OPENCLAW_AUTOSTART:-false}" = "true" ] && openclaw_runtime_has_manual_process; then
      warn 'OpenClaw is already running in the VM outside the ClawBox launchd service.'
      out 'ClawBox can stop the foreground/manual gateway and restart it as a VM user launchd service.'
      blank_line
      prompt_yes_no 'Stop foreground OpenClaw and manage it with VM launchd?' 'y'
      manage_manual_choice="$REPLY"

      if is_yes "$manage_manual_choice"; then
        stop_openclaw || return 1
        if ! start_openclaw; then
          return 1
        fi
        openclaw_runtime_report_start
      else
        out 'OpenClaw remains running outside ClawBox launchd management.'
        OPENCLAW_RUNTIME_MANAGEMENT_STATE='running manually'
      fi
      return 0
    fi

    out "OpenClaw is already running on the VM."
    if [ "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-}" = 'managed by VM launchd' ]; then
      out 'OpenClaw runtime: managed by VM launchd.'
    elif [ "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-}" = 'managed by native OpenClaw LaunchAgent' ]; then
      out 'OpenClaw runtime: managed by native OpenClaw LaunchAgent (ai.openclaw.gateway).'
    fi
  else
    warn "OpenClaw is installed but not running."
    out "Start with: openclaw gateway"
    OPENCLAW_RUNTIME_MANAGEMENT_STATE='not running'
  fi
}
