# Dependencies are sourced by scripts/setup.sh before this function runs:
# shared output/prompt helpers; setup env, derive, model, VM, llama binary,
# and llama pre-start modules; VM repair helpers; and error_exit.
#
# This workflow reads and updates setup globals including ENV_FILE,
# VM_REPAIR_MODE, ENV_CREATED_FROM_EXAMPLE, ENV_BOOTSTRAPPED, VM connection
# values, llama connection values, model selection, firewall subnet, and
# OpenClaw provider/autostart values.

maybe_migrate_llama_extra_args() {
  local original_extra_args="${LLAMA_EXTRA_ARGS:-}"
  local proposed_extra_args=''

  llama_migrate_managed_runtime_extra_args "$original_extra_args" || return 0
  proposed_extra_args="$LLAMA_MIGRATION_EXTRA_ARGS"

  if ! [ -t 0 ] && ! [ -p /dev/stdin ]; then
    error 'LLAMA_EXTRA_ARGS contains settings now managed by first-class ClawBox variables.'
    error 'Run ./clawbox setup interactively to migrate them, or edit .env manually:'
    outf ' LLAMA_CTX="%s"' "${LLAMA_MIGRATION_CTX:-${LLAMA_CTX:-32768}}"
    outf ' LLAMA_PARALLEL="%s"' "${LLAMA_MIGRATION_PARALLEL:-1}"
    outf ' LLAMA_GPU_LAYERS="%s"' "${LLAMA_MIGRATION_GPU_LAYERS:-}"
    outf ' LLAMA_FLASH_ATTENTION="%s"' "${LLAMA_MIGRATION_FLASH_ATTENTION:-false}"
    outf ' LLAMA_JINJA="%s"' "${LLAMA_MIGRATION_JINJA:-false}"
    outf ' LLAMA_MLOCK="%s"' "${LLAMA_MIGRATION_MLOCK:-false}"
    outf ' MMPROJ_PATH="%s"' "${LLAMA_MIGRATION_MMPROJ_PATH:-${MMPROJ_PATH:-}}"
    outf ' LLAMA_EXTRA_ARGS="%s"' "$proposed_extra_args"
    return 1
  fi

  warn 'LLAMA_EXTRA_ARGS contains settings that ClawBox now manages directly.'
  out 'ClawBox can migrate those flags into first-class .env variables while preserving unmanaged passthrough arguments.'
  blank_line
  out 'Proposed migration:'
  outf ' LLAMA_CTX="%s"' "${LLAMA_MIGRATION_CTX:-${LLAMA_CTX:-32768}}"
  outf ' LLAMA_PARALLEL="%s"' "${LLAMA_MIGRATION_PARALLEL:-1}"
  outf ' LLAMA_GPU_LAYERS="%s"' "${LLAMA_MIGRATION_GPU_LAYERS:-}"
  outf ' LLAMA_FLASH_ATTENTION="%s"' "${LLAMA_MIGRATION_FLASH_ATTENTION:-false}"
  outf ' LLAMA_JINJA="%s"' "${LLAMA_MIGRATION_JINJA:-false}"
  outf ' LLAMA_MLOCK="%s"' "${LLAMA_MIGRATION_MLOCK:-false}"
  outf ' MMPROJ_PATH="%s"' "${LLAMA_MIGRATION_MMPROJ_PATH:-${MMPROJ_PATH:-}}"
  outf ' LLAMA_EXTRA_ARGS="%s"' "$proposed_extra_args"

  prompt_yes_no 'Apply this LLAMA_EXTRA_ARGS migration now?' 'y'
  if ! is_yes "$REPLY"; then
    error 'LLAMA_EXTRA_ARGS migration was declined.'
    error 'Move managed flags to first-class .env settings before setup can continue.'
    return 1
  fi

  LLAMA_CTX="${LLAMA_MIGRATION_CTX:-${LLAMA_CTX:-32768}}"
  LLAMA_PARALLEL="${LLAMA_MIGRATION_PARALLEL:-1}"
  LLAMA_GPU_LAYERS="${LLAMA_MIGRATION_GPU_LAYERS:-}"
  LLAMA_FLASH_ATTENTION="${LLAMA_MIGRATION_FLASH_ATTENTION:-false}"
  LLAMA_JINJA="${LLAMA_MIGRATION_JINJA:-false}"
  LLAMA_MLOCK="${LLAMA_MIGRATION_MLOCK:-false}"
  MMPROJ_PATH="${LLAMA_MIGRATION_MMPROJ_PATH:-${MMPROJ_PATH:-}}"
  LLAMA_EXTRA_ARGS="$proposed_extra_args"

  write_env_from_template
  source_env_file || return $?

  out 'LLAMA_EXTRA_ARGS migration applied.'
}

ensure_env_bootstrap() {
  local needs_setup=false
  local required_keys
  local status=0
  local host_ip_value
  local llama_base_url_value
  local llama_bin_value
  local llama_ctx_value
  local llama_host_value
  local llama_port_value
  local selected_model_name
  local firewall_shared_subnet_value
  local openclaw_provider_name_value
  local openclaw_default_model_value
  local openclaw_autostart_value
  local openclaw_provider_timeout_seconds_value
  local openclaw_stuck_session_warn_ms_value
  local openclaw_stuck_session_abort_ms_value
  local vm_ip_value
  local vm_user_value
  local vm_user_path_value
  local vm_host_value
  local vm_runtime_path_value
  local vm_machine_name_value
  local host_ip_default
  local parsed_host_ip
  local derived_host_ip
  local fallback_host_ip
  local llama_base_url_current
  local llama_base_url_default
  local vm_ip_default
  local vm_user_default
  local vm_user_path_default
  local connectivity_status
  local llama_section_needed=false
  local llama_bin_default
  local llama_port_discovery_mode='discover'
  local openclaw_max_tokens_value
  local llama_parallel_value
  local llama_gpu_layers_value
  local llama_flash_attention_value
  local llama_jinja_value
  local llama_mlock_value
  local openclaw_model_supports_vision_value
  local mmproj_path_value
  local openclaw_model_supports_vision_configured=false
  local native_context_value=''

  if [ ! -f "$ENV_FILE" ]; then
    ENV_CREATED_FROM_EXAMPLE=true
  fi

  source_env_file
  if env_file_has_key 'OPENCLAW_MODEL_SUPPORTS_VISION'; then
    openclaw_model_supports_vision_configured=true
  fi
  maybe_migrate_llama_extra_args || return $?

  validate_openclaw_token_context_values "${LLAMA_CTX:-32768}" "${OPENCLAW_MAX_TOKENS:-8192}" '.env' || return $?
  openclaw_resolve_runtime_tuning_values || return $?
  OPENCLAW_PROVIDER_TIMEOUT_SECONDS="${OPENCLAW_PROVIDER_TIMEOUT_SECONDS_VALUE:-$(openclaw_default_provider_timeout_seconds)}"
  OPENCLAW_STUCK_SESSION_WARN_MS="${OPENCLAW_STUCK_SESSION_WARN_MS_VALUE:-$(openclaw_default_stuck_session_warn_ms)}"
  OPENCLAW_STUCK_SESSION_ABORT_MS="${OPENCLAW_STUCK_SESSION_ABORT_MS_VALUE:-$(openclaw_default_stuck_session_abort_ms "$OPENCLAW_STUCK_SESSION_WARN_MS")}"
  LLAMA_PARALLEL="${LLAMA_PARALLEL:-1}"
  LLAMA_GPU_LAYERS="${LLAMA_GPU_LAYERS:-}"
  LLAMA_FLASH_ATTENTION="${LLAMA_FLASH_ATTENTION:-false}"
  LLAMA_JINJA="${LLAMA_JINJA:-true}"
  LLAMA_MLOCK="${LLAMA_MLOCK:-false}"
  MMPROJ_PATH="${MMPROJ_PATH:-}"

  if [ "$openclaw_model_supports_vision_configured" != true ] \
    && ! value_needs_setup 'MODEL_PATH' "${MODEL_PATH:-}"; then
    if [ ! -t 0 ] && [ ! -p /dev/stdin ]; then
      error 'Primary model vision capability is not configured in .env.'
      error 'Run ./clawbox setup in a terminal to choose text-only or vision-capable behavior.'
      return 1
    fi

    section "Model Configuration"
    out 'This existing ClawBox installation predates managed vision settings.'
    setup_configure_model_vision "${MODEL_PATH:-}" "${MODEL_PATH:-}" || return $?
    write_env_from_template
    source_env_file || return $?
    openclaw_model_supports_vision_configured=true
  fi

  OPENCLAW_MODEL_SUPPORTS_VISION="${OPENCLAW_MODEL_SUPPORTS_VISION:-false}"

  if [ "$VM_REPAIR_MODE" = true ]; then
    required_keys='VM_IP VM_USER VM_USER_PATH VM_HOST VM_RUNTIME_PATH VM_MACHINE_NAME'
  else
    required_keys='HOST_IP VM_IP VM_USER VM_USER_PATH VM_HOST VM_RUNTIME_PATH VM_MACHINE_NAME LLAMA_BIN LLAMA_HOST LLAMA_PORT LLAMA_CTX LLAMA_BASE_URL MODEL_PATH OPENCLAW_PROVIDER_NAME OPENCLAW_DEFAULT_MODEL OPENCLAW_AUTOSTART'
  fi

  for required_key in $required_keys; do
    if value_needs_setup "$required_key" "${!required_key:-}"; then
      needs_setup=true
      break
    fi
  done

  if [ "$needs_setup" = false ]; then
    host_ip_value="${HOST_IP:-}"
    llama_port_value="${LLAMA_PORT:-11434}"
    if [ "$llama_port_value" = '11434' ]; then
      llama_port_discovery_mode='discover'
    else
      llama_port_discovery_mode='selected'
    fi

    while true; do
      llama_capture_status run_prestart_llama_instance_flow "$host_ip_value" "$llama_port_value" "$llama_port_discovery_mode"
      status=$LLAMA_LAST_STATUS

      if [ "$status" -eq "$LLAMA_EXIT_RETRY" ]; then
        continue
      fi

      break
    done

    if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    if [ "$status" -ne 0 ]; then
      return "$status"
    fi

    LLAMA_PORT="$REPLY"
    if [ "${LLAMA_EXTERNAL:-false}" != true ]; then
      LLAMA_BASE_URL="$(build_llama_base_url "$host_ip_value" "$LLAMA_PORT")"
    fi

    write_env_from_template
    source_env_file || return $?
    ENV_BOOTSTRAPPED=true
    return 0
  fi

  if [ ! -t 0 ] && [ ! -p /dev/stdin ]; then
    error 'Interactive setup requires a TTY.'
    error 'Run ./clawbox setup in a terminal to complete .env setup.'
    return 1
  fi

  llama_capture_status ensure_vm_connection_setup
  status=$LLAMA_LAST_STATUS

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$status" -ne 0 ]; then
    return "$status"
  fi

  if ensure_vm_connectivity_or_repair; then
    :
  else
    connectivity_status=$?
    return "$connectivity_status"
  fi

  if [ "$VM_REPAIR_MODE" = true ]; then
    ENV_BOOTSTRAPPED=true
    return 0
  fi

  setup_configure_model_selection
  status=$?

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$status" -ne 0 ]; then
    return "$status"
  fi

  selected_model_name="$REPLY"
  if gguf_native_context_from_file "${MODEL_PATH:-}" >/dev/null 2>&1; then
    native_context_value="$(gguf_native_context_from_file "$MODEL_PATH" 2>/dev/null || true)"
    [ -z "$native_context_value" ] || outf 'Model native context: %s' "$native_context_value"
  else
    warn 'Model native context metadata is unavailable; using ClawBox defaults.'
  fi

  derive_llama_bin_path
  configured_or_default 'LLAMA_BIN' "${LLAMA_BIN:-}" "$REPLY"
  llama_bin_default="$REPLY"
  if value_needs_setup 'LLAMA_PORT' "${LLAMA_PORT:-}" \
    || value_needs_setup 'LLAMA_CTX' "${LLAMA_CTX:-}" \
    || value_needs_setup 'LLAMA_BASE_URL' "${LLAMA_BASE_URL:-}" \
    || value_needs_setup 'HOST_IP' "${HOST_IP:-}" \
    || ! llama_is_valid_binary "$llama_bin_default"; then
    llama_section_needed=true
  fi

  if [ "$llama_section_needed" = true ]; then
    section "LLaMA Server Configuration"
  fi

  configured_or_default 'LLAMA_HOST' "${LLAMA_HOST:-}" '0.0.0.0'
  llama_host_value="$REPLY"
  if [ "$llama_section_needed" = true ]; then
    prompt_resolved_value 'Port for llama-server' 'LLAMA_PORT' "${LLAMA_PORT:-}" '11434'
    llama_port_value="$REPLY"
    if [ "${PROMPT_USED_DEFAULT:-false}" = true ]; then
      llama_port_discovery_mode='discover'
    else
      llama_port_discovery_mode='selected'
    fi
  else
    configured_or_default 'LLAMA_PORT' "${LLAMA_PORT:-}" '11434'
    llama_port_value="$REPLY"
    llama_port_discovery_mode='selected'
  fi
  parse_host_ip_from_base_url "${LLAMA_BASE_URL:-}"
  parsed_host_ip="$REPLY"
  derive_host_ip_from_vm_ip "${VM_IP:-}"
  derived_host_ip="$REPLY"
  configured_or_default 'HOST_IP' "$parsed_host_ip" "$derived_host_ip"
  fallback_host_ip="$REPLY"
  configured_or_default 'HOST_IP' "${HOST_IP:-}" "$fallback_host_ip"
  host_ip_default="$REPLY"
  [ -n "$host_ip_default" ] || host_ip_default="$derived_host_ip"
  if [ "$llama_section_needed" = true ]; then
    prompt_with_default 'Host IP for llama-server API' "$host_ip_default"
    host_ip_value="$REPLY"
  else
    host_ip_value="$host_ip_default"
  fi

  while true; do
    llama_capture_status run_prestart_llama_instance_flow "$host_ip_value" "$llama_port_value" "$llama_port_discovery_mode"
    status=$LLAMA_LAST_STATUS

    if [ "$status" -eq "$LLAMA_EXIT_RETRY" ]; then
      continue
    fi

    break
  done

  if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
    return "$LLAMA_EXIT_GRACEFUL"
  fi

  if [ "$status" -ne 0 ]; then
    return "$status"
  fi

  llama_port_value="$REPLY"

  if [ "$LLAMA_USE_EXISTING_INSTANCE" = true ]; then
    configured_or_default 'OPENCLAW_MAX_TOKENS' "${OPENCLAW_MAX_TOKENS:-}" '8192'
    openclaw_max_tokens_value="$REPLY"
    configured_or_default 'LLAMA_CTX' "${LLAMA_CTX:-}" "${native_context_value:-32768}"
    llama_ctx_value="$REPLY"
    validate_openclaw_token_context_values "$llama_ctx_value" "$openclaw_max_tokens_value" 'setup input' || return $?
    llama_bin_value="$llama_bin_default"
    if [ "${LLAMA_EXTERNAL:-false}" = true ] && [ -n "${LLAMA_BASE_URL:-}" ]; then
      llama_base_url_value="$LLAMA_BASE_URL"
    else
      llama_base_url_value="$(build_llama_base_url "$host_ip_value" "$llama_port_value")"
    fi
  else
    configured_or_default 'OPENCLAW_MAX_TOKENS' "${OPENCLAW_MAX_TOKENS:-}" '8192'
    openclaw_max_tokens_value="$REPLY"
    prompt_llama_context_for_openclaw "${LLAMA_CTX:-}" "${native_context_value:-32768}" "$openclaw_max_tokens_value"
    llama_ctx_value="$REPLY"
    if [ -n "$native_context_value" ] && [ "$llama_ctx_value" -gt "$native_context_value" ] 2>/dev/null; then
      warn "Configured LLAMA_CTX=$llama_ctx_value exceeds model native context $native_context_value."
      prompt_yes_no 'Use this larger context anyway?' 'n'
      is_yes "$REPLY" || return "$LLAMA_EXIT_GRACEFUL"
    fi

    llama_bin_value="$llama_bin_default"
    llama_capture_status resolve_configured_llama_bin "$llama_bin_value"
    status=$LLAMA_LAST_STATUS

    if [ "$status" -eq "$LLAMA_EXIT_GRACEFUL" ]; then
      return "$LLAMA_EXIT_GRACEFUL"
    fi

    if [ "$status" -ne 0 ]; then
      error_exit "llama-server setup aborted"
    fi

    llama_bin_value="$REPLY"

    llama_base_url_default="$(build_llama_base_url "$host_ip_value" "$llama_port_value")"
    llama_base_url_current="${LLAMA_BASE_URL:-}"
    if value_needs_setup 'LLAMA_BASE_URL' "$llama_base_url_current"; then
      llama_base_url_current=''
    fi
    if [ "$llama_section_needed" = true ]; then
      prompt_resolved_value 'Base URL for llama-server API' 'LLAMA_BASE_URL' "$llama_base_url_current" "$llama_base_url_default"
      llama_base_url_value="$REPLY"
    else
      configured_or_default 'LLAMA_BASE_URL' "$llama_base_url_current" "$llama_base_url_default"
      llama_base_url_value="$REPLY"
    fi
  fi

  HOST_IP="$host_ip_value"
  LLAMA_BIN="$llama_bin_value"
  LLAMA_HOST="$llama_host_value"
  LLAMA_PORT="$llama_port_value"
  LLAMA_CTX="$llama_ctx_value"
  configured_or_default 'LLAMA_PARALLEL' "${LLAMA_PARALLEL:-}" '1'
  llama_parallel_value="$REPLY"
  configured_or_default 'LLAMA_GPU_LAYERS' "${LLAMA_GPU_LAYERS:-}" ''
  llama_gpu_layers_value="$REPLY"
  configured_or_default 'LLAMA_FLASH_ATTENTION' "${LLAMA_FLASH_ATTENTION:-}" 'false'
  llama_flash_attention_value="$REPLY"
  configured_or_default 'LLAMA_JINJA' "${LLAMA_JINJA:-}" 'true'
  llama_jinja_value="$REPLY"
  configured_or_default 'LLAMA_MLOCK' "${LLAMA_MLOCK:-}" 'false'
  llama_mlock_value="$REPLY"
  configured_or_default 'OPENCLAW_MODEL_SUPPORTS_VISION' "${OPENCLAW_MODEL_SUPPORTS_VISION:-}" 'false'
  openclaw_model_supports_vision_value="$REPLY"
  configured_or_default 'MMPROJ_PATH' "${MMPROJ_PATH:-}" ''
  mmproj_path_value="$REPLY"
  LLAMA_PARALLEL="$llama_parallel_value"
  LLAMA_GPU_LAYERS="$llama_gpu_layers_value"
  LLAMA_FLASH_ATTENTION="$llama_flash_attention_value"
  LLAMA_JINJA="$llama_jinja_value"
  LLAMA_MLOCK="$llama_mlock_value"
  OPENCLAW_MODEL_SUPPORTS_VISION="$openclaw_model_supports_vision_value"
  MMPROJ_PATH="$mmproj_path_value"
  LLAMA_BASE_URL="$llama_base_url_value"
  OPENCLAW_MAX_TOKENS="$openclaw_max_tokens_value"
  write_env_from_template
  source_env_file || return $?

  derive_shared_subnet_from_vm_ip "${VM_IP:-}"
  configured_or_default 'FIREWALL_SHARED_SUBNET' "${FIREWALL_SHARED_SUBNET:-}" "$REPLY"
  firewall_shared_subnet_value="$REPLY"

  FIREWALL_SHARED_SUBNET="$firewall_shared_subnet_value"
  write_env_from_template
  source_env_file || return $?

  section "OpenClaw Configuration"
  configured_or_default 'OPENCLAW_PROVIDER_NAME' "${OPENCLAW_PROVIDER_NAME:-}" 'clawbox'
  openclaw_provider_name_value="$REPLY"
  configured_or_default 'OPENCLAW_DEFAULT_MODEL' "${OPENCLAW_DEFAULT_MODEL:-}" 'local'
  openclaw_default_model_value="$REPLY"
  configured_or_default 'OPENCLAW_PROVIDER_TIMEOUT_SECONDS' "${OPENCLAW_PROVIDER_TIMEOUT_SECONDS:-}" "$(openclaw_default_provider_timeout_seconds)"
  openclaw_provider_timeout_seconds_value="$REPLY"
  configured_or_default 'OPENCLAW_STUCK_SESSION_WARN_MS' "${OPENCLAW_STUCK_SESSION_WARN_MS:-}" "$(openclaw_default_stuck_session_warn_ms)"
  openclaw_stuck_session_warn_ms_value="$REPLY"
  configured_or_default 'OPENCLAW_STUCK_SESSION_ABORT_MS' "${OPENCLAW_STUCK_SESSION_ABORT_MS:-}" "$(openclaw_default_stuck_session_abort_ms "$openclaw_stuck_session_warn_ms_value")"
  openclaw_stuck_session_abort_ms_value="$REPLY"
  prompt_openclaw_autostart "${OPENCLAW_AUTOSTART:-}"
  openclaw_autostart_value="$REPLY"

  OPENCLAW_PROVIDER_NAME="$openclaw_provider_name_value"
  OPENCLAW_DEFAULT_MODEL="$openclaw_default_model_value"
  OPENCLAW_AUTOSTART="$openclaw_autostart_value"
  OPENCLAW_PROVIDER_TIMEOUT_SECONDS="$openclaw_provider_timeout_seconds_value"
  OPENCLAW_STUCK_SESSION_WARN_MS="$openclaw_stuck_session_warn_ms_value"
  OPENCLAW_STUCK_SESSION_ABORT_MS="$openclaw_stuck_session_abort_ms_value"
  openclaw_resolve_runtime_tuning_values || return $?
  write_env_from_template
  source_env_file || return $?

  HOST_IP="$host_ip_value"
  LLAMA_BIN="$llama_bin_value"
  LLAMA_HOST="$llama_host_value"
  LLAMA_PORT="$llama_port_value"
  LLAMA_CTX="$llama_ctx_value"
  LLAMA_PARALLEL="$llama_parallel_value"
  LLAMA_GPU_LAYERS="$llama_gpu_layers_value"
  LLAMA_FLASH_ATTENTION="$llama_flash_attention_value"
  LLAMA_JINJA="$llama_jinja_value"
  LLAMA_MLOCK="$llama_mlock_value"
  OPENCLAW_MODEL_SUPPORTS_VISION="$openclaw_model_supports_vision_value"
  MMPROJ_PATH="$mmproj_path_value"
  LLAMA_BASE_URL="$llama_base_url_value"
  OPENCLAW_MAX_TOKENS="${OPENCLAW_MAX_TOKENS:-8192}"
  FIREWALL_SHARED_SUBNET="$firewall_shared_subnet_value"
  OPENCLAW_PROVIDER_NAME="$openclaw_provider_name_value"
  OPENCLAW_DEFAULT_MODEL="$openclaw_default_model_value"
  OPENCLAW_AUTOSTART="$openclaw_autostart_value"
  OPENCLAW_PROVIDER_TIMEOUT_SECONDS="$openclaw_provider_timeout_seconds_value"
  OPENCLAW_STUCK_SESSION_WARN_MS="$openclaw_stuck_session_warn_ms_value"
  OPENCLAW_STUCK_SESSION_ABORT_MS="$openclaw_stuck_session_abort_ms_value"

  write_env_from_template

  source_env_file

  section "Configuration Summary"

  print_summary_value "HOST_IP" "${HOST_IP:-}"
  print_summary_value "VM_IP" "${VM_IP:-}"
  print_summary_value "VM_USER" "${VM_USER:-}"
  print_summary_value "VM_USER_PATH" "${VM_USER_PATH:-}"
  print_summary_value "VM_HOST" "${VM_HOST:-}"
  print_summary_value "VM_RUNTIME_PATH" "${VM_RUNTIME_PATH:-}"
  print_summary_value "VM_MACHINE_NAME" "${VM_MACHINE_NAME:-}"
  print_summary_value "LLAMA_BIN" "${LLAMA_BIN:-}"
  print_summary_value "LLAMA_HOST" "${LLAMA_HOST:-}"
  print_summary_value "LLAMA_PORT" "${LLAMA_PORT:-}"
  print_summary_value "LLAMA_CTX" "${LLAMA_CTX:-}"
  print_summary_value "LLAMA_PARALLEL" "${LLAMA_PARALLEL:-}"
  print_summary_value "LLAMA_GPU_LAYERS" "${LLAMA_GPU_LAYERS:-}"
  print_summary_value "LLAMA_FLASH_ATTENTION" "${LLAMA_FLASH_ATTENTION:-}"
  print_summary_value "LLAMA_JINJA" "${LLAMA_JINJA:-}"
  print_summary_value "LLAMA_MLOCK" "${LLAMA_MLOCK:-}"
  print_summary_value "OPENCLAW_MODEL_SUPPORTS_VISION" "${OPENCLAW_MODEL_SUPPORTS_VISION:-}"
  print_summary_value "MMPROJ_PATH" "${MMPROJ_PATH:-}"
  print_summary_value "LLAMA_BASE_URL" "${LLAMA_BASE_URL:-}"
  print_summary_value "OPENCLAW_MAX_TOKENS" "${OPENCLAW_MAX_TOKENS:-}"
  print_summary_value "MODEL_PATH" "${MODEL_PATH:-}"
  print_summary_value "OPENCLAW_PROVIDER_NAME" "${OPENCLAW_PROVIDER_NAME:-}"
  print_summary_value "OPENCLAW_DEFAULT_MODEL" "${OPENCLAW_DEFAULT_MODEL:-}"
  print_summary_value "OPENCLAW_AUTOSTART" "${OPENCLAW_AUTOSTART:-}"
  print_summary_value "OPENCLAW_PROVIDER_TIMEOUT_SECONDS" "${OPENCLAW_PROVIDER_TIMEOUT_SECONDS:-}"
  print_summary_value "OPENCLAW_STUCK_SESSION_WARN_MS" "${OPENCLAW_STUCK_SESSION_WARN_MS:-}"
  print_summary_value "OPENCLAW_STUCK_SESSION_ABORT_MS" "${OPENCLAW_STUCK_SESSION_ABORT_MS:-}"
  blank_line

  ENV_BOOTSTRAPPED=true
}
