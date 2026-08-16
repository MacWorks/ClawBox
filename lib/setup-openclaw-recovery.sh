# Dependencies are sourced by scripts/setup.sh before these functions run:
# output/prompt helpers, SSH/runtime helpers, and setup globals.

vm_llama_inference_available() {
  local completion_url=''

  # Deliberately process-environment-only, for manually exercising the
  # recovery prompt. Its value is captured before .env is sourced. Never use
  # it outside this probe.
  if [ "${CLAWBOX_DEV_FORCE_VM_LLAMA_INFERENCE_FAILURE_PROCESS_VALUE:-false}" = true ]; then
    return 1
  fi

  [ -n "${LLAMA_BASE_URL:-}" ] || return 1
  completion_url="${LLAMA_BASE_URL%/v1}/completion"

  ssh_check_zsh "url=$(printf '%q' "$completion_url")
response=\$(curl -s --connect-timeout 1 --max-time 10 -o /dev/null -w '%{http_code}' \"\$url\" -H 'Content-Type: application/json' -d '{\"prompt\":\"ping\",\"n_predict\":1,\"cache_prompt\":false}') || exit 1
[ \"\$response\" -ge 200 ] 2>/dev/null && [ \"\$response\" -lt 300 ]"
}

print_openclaw_gateway_restart_guidance() {
  out 'Restart the VM OpenClaw gateway later with:'
  outf "  ssh %s 'zsh -lc \"launchctl kickstart -k gui/\$(id -u)/com.clawbox.openclaw\"'" "$VM_HOST"
  out 'Diagnose the VM OpenClaw gateway with:'
  outf "  ssh %s 'zsh -lc \"launchctl print gui/\$(id -u)/com.clawbox.openclaw\"'" "$VM_HOST"
  out "  VM logs: ${VM_RUNTIME_PATH:-<VM_RUNTIME_PATH>}/logs/runtime/openclaw.out.log"
  out "           ${VM_RUNTIME_PATH:-<VM_RUNTIME_PATH>}/logs/runtime/openclaw.err.log"
}

restart_clawbox_managed_openclaw_gateway() {
  local label=''
  local attempt=1
  local max_attempts="${CLAWBOX_OPENCLAW_RESTART_VERIFY_MAX_ATTEMPTS:-45}"

  label="$(openclaw_runtime_service_label)"
  ssh_exec_zsh "uid=\$(id -u)
launchctl kickstart -k \"gui/\$uid/$label\"" || return 1

  while [ "$attempt" -le "$max_attempts" ]; do
    if openclaw_runtime_has_running_gateway_service \
      && openclaw_gateway_local_http_ready
    then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

openclaw_gateway_local_http_ready() {
  local gateway_port=''

  if command -v vm_openclaw_gateway_port >/dev/null 2>&1; then
    gateway_port="$(vm_openclaw_gateway_port)"
  else
    gateway_port='18789'
  fi

  ssh_exec_zsh "gateway_port=$(printf '%q' "$gateway_port")
if command -v curl >/dev/null 2>&1; then
  http_status=\$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 \"http://127.0.0.1:\$gateway_port/\" 2>/dev/null || true)
  case \"\$http_status\" in
    2??|3??|401|403|404) exit 0 ;;
  esac
fi
exit 1"
}

offer_openclaw_restart_after_llama_update() {
  [ "${LLAMA_SERVICE_CHANGED:-false}" = true ] || return 0
  [ "${NEEDS_PROVISIONING:-false}" = false ] || return 0
  [ "${IS_RUNNING:-false}" = true ] || return 0

  # Restart only the service ClawBox can verify; do not take over manual or
  # external gateways during this recovery flow.
  openclaw_runtime_has_running_gateway_service || return 0
  vm_llama_inference_available && return 0

  blank_line
  warn 'Host llama-server was restarted, but VM → host inference is failing.'
  blank_line
  prompt_yes_no 'Restart the VM OpenClaw gateway now?' 'n'
  if ! is_yes "$REPLY"; then
    out 'OpenClaw was not restarted.'
    print_openclaw_gateway_restart_guidance
    return 0
  fi

  step 'Waiting for VM OpenClaw gateway to restart...'
  if restart_clawbox_managed_openclaw_gateway; then
    success 'VM OpenClaw gateway restarted and is running.'
  else
    warn 'VM OpenClaw gateway did not become healthy after restart.'
    print_openclaw_gateway_restart_guidance
  fi
}
