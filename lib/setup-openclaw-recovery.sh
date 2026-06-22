# Dependencies are sourced by scripts/setup.sh before these functions run:
# output/prompt helpers, SSH/runtime helpers, and setup globals.

vm_llama_inference_available() {
  local completion_url=''

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

  label="$(openclaw_runtime_service_label)"
  ssh_exec_zsh "uid=\$(id -u)
launchctl kickstart -k \"gui/\$uid/$label\"" || return 1

  local attempt=1
  while [ "$attempt" -le 30 ]; do
    openclaw_runtime_has_running_gateway_service && return 0
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
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
