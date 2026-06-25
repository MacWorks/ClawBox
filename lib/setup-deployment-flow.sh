# Dependencies are sourced by scripts/setup.sh before this function runs:
# shared output helpers; host inference, VM connectivity, OpenClaw
# provisioning, config sync, deployment, launchagent, and runtime helpers.

print_setup_completion_summary() {
  local openclaw_bin=''

  section "Setup Complete"
  success "ClawBox setup completed successfully."

  case "${VM_AUTOSTART_STATE:-unknown}" in
    enabled|kept)
      out 'VM auto-start at host login: enabled.'
      ;;
    disabled)
      out 'VM auto-start at host login: disabled.'
      ;;
    skipped)
      out 'VM auto-start at host login: skipped for this run.'
      ;;
    *)
      out 'VM auto-start at host login: not changed.'
      ;;
  esac

  case "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-unknown}" in
    'managed by VM launchd')
      out 'OpenClaw runtime: managed by VM launchd.'
      ;;
    'managed by native OpenClaw LaunchAgent')
      out 'OpenClaw runtime: managed by native OpenClaw LaunchAgent (ai.openclaw.gateway).'
      ;;
    'running manually')
      out 'OpenClaw runtime: running manually in the VM.'
      ;;
    'not running')
      out 'OpenClaw runtime: installed but not running.'
      ;;
    *)
      out 'OpenClaw runtime: check current state with status.'
      ;;
  esac

  out 'Check status with: ./clawbox status'
  case "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-unknown}" in
    'managed by VM launchd'|'managed by native OpenClaw LaunchAgent'|'running manually')
      out 'OpenClaw gateway is running in the VM.'
      openclaw_bin="${OPENCLAW_BIN:-}"
      if [ -z "$openclaw_bin" ] && resolve_vm_openclaw_bin_path; then
        openclaw_bin="$REPLY"
      fi

      if [ -n "$openclaw_bin" ]; then
        outf "Get started with: ssh %s 'zsh -lc \"openclaw --help\"'" "$VM_HOST"
      else
        out 'OpenClaw CLI path could not be resolved; verify the gateway with ./clawbox status.'
      fi
      ;;
  esac
}

run_provisioning_and_deployment() {
  local connectivity_status

  setup_host_inference_service_phase || return $?
  setup_embeddings_service_phase || return $?

  section "VM Onboarding"
  step "Checking SSH access to the VM."

  if ensure_vm_connectivity_or_repair; then
    :
  else
    connectivity_status=$?
    return "$connectivity_status"
  fi

  section "OpenClaw Configuration"
  step "Preparing OpenClaw configuration..."

  detect_openclaw_runtime_state

  # Existing VM config is user/OpenClaw-owned. Normal setup makes only
  # targeted OpenClaw CLI updates; the generator is used only for bootstrap.
  sync_openclaw_config

  section "Deployment"
  step "Deploying to VM..."

  ensure_vm_provision_script

  ensure_openclaw_provisioned || return $?

  section "Runtime"
  step "Configuring runtime services..."

  setup_launchagent

  handle_openclaw_runtime_state || return $?

  offer_targeted_openclaw_config_restart || return $?

  offer_openclaw_restart_after_llama_update || return $?

  print_setup_completion_summary
}
