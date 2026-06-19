# Dependencies are sourced by scripts/setup.sh before this function runs:
# shared output/prompt helpers, lib/llama.sh, setup-llama-bin helpers,
# error_exit, and is_yes.

setup_host_inference_service_phase() {
  local llama_install_mode
  local existing_llama_mode
  local reconfigure_choice
  local model_name
  local status=0

  section "Host Inference Service"
  if [ "$LLAMA_USE_EXISTING_INSTANCE" = true ]; then
    out "Using existing llama-server at $LLAMA_BASE_URL"
  else
    if user_has_sudo; then
      warn 'Administrator privileges may be required'
      sudo -v
    fi

    detect_existing_llama_install_mode >/dev/null 2>&1 || true
    existing_llama_mode="$REPLY"
    if [ -n "$existing_llama_mode" ] && llama_verify_service_health >/dev/null 2>&1; then
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

      if is_yes "$reconfigure_choice"; then
        llama_install_mode="$existing_llama_mode"
        if [ "$llama_install_mode" = 'system' ]; then
          setup_system_llama_service
        else
          setup_user_llama_service
        fi
      fi
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
      if [ "$llama_install_mode" = 'system' ]; then
        setup_system_llama_service
      else
        setup_user_llama_service
      fi
    fi
  fi

  return 0
}
