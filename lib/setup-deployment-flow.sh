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
    unverified)
      out 'VM auto-start at host login: configured but not verified.'
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
      if [ "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-unknown}" != 'running manually' ] &&
         command -v print_openclaw_personalization_next_step >/dev/null 2>&1; then
        print_openclaw_personalization_next_step
      fi
      ;;
  esac
}

detect_openclaw_runtime_state_with_status() {
  local state_file=''
  local pid=''
  local status=0

  state_file="$(mktemp "${TMPDIR:-/tmp}/clawbox-openclaw-runtime-state.XXXXXX")" || return 1

  (
    detect_openclaw_runtime_state
    status="$?"
    {
      printf '%s\n' "${NEEDS_PROVISIONING:-false}"
      printf '%s\n' "${IS_RUNNING:-false}"
      printf '%s\n' "${OPENCLAW_RUNTIME_MANAGEMENT_STATE:-unknown}"
    } >"$state_file"
    exit "$status"
  ) &
  pid="$!"

  if status_wait_for_pid_active "$pid" "${CLAWBOX_STATUS_MESSAGE:-Preparing OpenClaw configuration}"; then
    status=0
  else
    status="$?"
  fi

  if [ -f "$state_file" ]; then
    {
      IFS= read -r NEEDS_PROVISIONING || NEEDS_PROVISIONING=false
      IFS= read -r IS_RUNNING || IS_RUNNING=false
      IFS= read -r OPENCLAW_RUNTIME_MANAGEMENT_STATE || OPENCLAW_RUNTIME_MANAGEMENT_STATE='unknown'
    } <"$state_file"
  fi

  rm -f "$state_file"
  return "$status"
}

run_provisioning_and_deployment() {
  local connectivity_status

  setup_host_inference_service_phase || return $?
  setup_embeddings_service_phase || return $?

  if command -v llama_refresh_openclaw_effective_context_window >/dev/null 2>&1; then
    llama_refresh_openclaw_effective_context_window || return $?
  fi

  section "VM Setup"

  if ensure_vm_connectivity_or_repair; then
    :
  else
    connectivity_status=$?
    return "$connectivity_status"
  fi

  if status_run_compact \
    "Deploying to VM" \
    "Deployment staged ✓" \
    "Deployment staging failed." \
    ensure_vm_provision_script
  then
    :
  else
    connectivity_status=$?
    return "$connectivity_status"
  fi

  status_begin_compact "Preparing OpenClaw configuration"

  if detect_openclaw_runtime_state_with_status; then
    :
  else
    status_end "Preparing OpenClaw configuration failed." 'error'
    return 1
  fi

  if [ "${NEEDS_PROVISIONING:-false}" = true ]; then
    openclaw_config_preparation_status_success
    ensure_openclaw_provisioned || return $?
    status_begin_compact "Preparing OpenClaw configuration"
  fi

  # Existing VM config is user/OpenClaw-owned. Normal setup makes only
  # targeted OpenClaw CLI updates; the generator is used only for bootstrap.
  if ! sync_openclaw_config; then
    openclaw_config_preparation_status_failure
    return 1
  fi
  openclaw_config_preparation_status_success

  offer_targeted_openclaw_config_restart || return $?

  section "Runtime"
  step "Configuring runtime services"

  setup_launchagent || return $?

  handle_openclaw_runtime_state || return $?

  offer_openclaw_restart_after_llama_update || return $?

  offer_openclaw_webui || return $?

  print_setup_completion_summary
}
