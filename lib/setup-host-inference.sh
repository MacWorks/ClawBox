# Dependencies are sourced by scripts/setup.sh before this function runs:
# shared output/prompt helpers, lib/llama.sh, setup-llama-bin helpers,
# error_exit, and is_yes.

setup_host_inference_service_phase() {
  local llama_install_mode
  local existing_llama_mode
  local reconfigure_choice
  local model_name
  local status=0

  LLAMA_SERVICE_CHANGED=false

  section "Host Inference Service"
  if [ "$LLAMA_USE_EXISTING_INSTANCE" = true ]; then
    out "Using existing llama-server at $LLAMA_BASE_URL"
  else
    if user_has_sudo; then
      warn 'Administrator privileges may be required'
      step 'Requesting administrator authorization...'
      sudo -v
    fi

    detect_existing_llama_install_mode >/dev/null 2>&1 || true
    existing_llama_mode="$REPLY"

    # A restart selected in the pre-start ownership menu deliberately unloads
    # the service before this phase. Use the bounded API probe here instead of
    # the interactive health helper: the latter waits for a service we just
    # stopped, then hides its recovery menu when called with redirected output.
    if [ -n "$existing_llama_mode" ] \
      && llama_api_responding "${HOST_IP:-}" "$LLAMA_PORT"; then
      model_name="${MODEL_PATH##*/}"

      out 'llama-server is already installed and running.'
      blank_line
      out 'Current configuration:'
      outf '  Mode: %s' "$existing_llama_mode"
      outf '  Port: %s' "$LLAMA_PORT"
      outf '  Model: %s' "$model_name"
      blank_line
      prompt_yes_no 'Reconfigure llama-server?' 'n'
      reconfigure_choice="$REPLY"

      if ! is_yes "$reconfigure_choice"; then
        return 0
      fi

      llama_install_mode="$existing_llama_mode"
    elif [ -n "$existing_llama_mode" ]; then
      llama_install_mode="$existing_llama_mode"
    else
      llama_capture_status select_requested_llama_install_mode
      status=$LLAMA_LAST_STATUS

      if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
        return "$LLAMA_EXIT_GRACEFUL"
      fi

      if [ "$status" -ne 0 ]; then
        error_exit "llama-server install mode selection failed"
      fi

      llama_install_mode="$REPLY"
    fi

    if [ "$llama_install_mode" = 'system' ]; then
      llama_capture_status setup_system_llama_service
    else
      llama_capture_status setup_user_llama_service
    fi
    status=$LLAMA_LAST_STATUS

    if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    if [ "$status" -ne 0 ]; then
      warn 'Host llama-server was not restored.'
      llama_show_recent_error_log "$llama_install_mode"
      out 'Correct the reported issue, then rerun: ./clawbox setup'
      return "$status"
    fi
  fi

  return 0
}
