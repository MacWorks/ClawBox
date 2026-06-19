# Dependencies are sourced by scripts/setup.sh before these functions run:
# shared output/prompt helpers, SSH helpers, lib/llama.sh, runtime state
# detection, and error_exit.
#
# These functions use setup globals including VM_RUNTIME_PATH, VM_HOST,
# GENERATE_SCRIPT, CONFIG_PATH, PROVISION_SCRIPT, and NEEDS_PROVISIONING.

generate_openclaw_config() {
  step "Generating OpenClaw config..."

  ssh_ensure_dir "$VM_RUNTIME_PATH"

  bash "$GENERATE_SCRIPT" >/dev/null

  if [ ! -f "$CONFIG_PATH" ]; then
    error_exit "Generated config not found: $CONFIG_PATH"
  fi
}

ensure_vm_provision_script() {
  out 'Finalizing...'

  if ssh_exec "test -f \"$VM_RUNTIME_PATH/vm-provision.sh\""; then
    :
  else
    scp -q "$PROVISION_SCRIPT" "$VM_HOST:$VM_RUNTIME_PATH/vm-provision.sh" </dev/null
    ssh_run_quiet "chmod +x \"$VM_RUNTIME_PATH/vm-provision.sh\""
    ssh_exec "test -f \"$VM_RUNTIME_PATH/vm-provision.sh\""
  fi

}

ensure_openclaw_provisioned() {
  if [ "$NEEDS_PROVISIONING" = true ]; then
    section "VM Provisioning"
    out 'OpenClaw is not yet installed in the VM.'
    blank_line
    out 'Run the following INSIDE the VM terminal:'
    outf 'cd %s && ./vm-provision.sh' "$VM_RUNTIME_PATH"
    blank_line

    prompt_yes_no 'Provisioning completed inside the VM?' 'y'
    if ! is_yes "$REPLY"; then
      out 'Resume setup on the host with:'
      out '  ./clawbox setup'
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    detect_openclaw_runtime_state
    if [ "$NEEDS_PROVISIONING" = true ]; then
      warn 'OpenClaw is still not detected in the VM.'
      out 'Complete VM provisioning, then resume setup on the host with:'
      out '  ./clawbox setup'
      return "$LLAMA_EXIT_GRACEFUL"
    fi
  fi

  return 0
}
