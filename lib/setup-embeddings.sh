# Optional host-only embeddings llama-server setup. Normal setup performs
# OpenClaw config sync later in the deployment phase. The model command may
# provide sync_model_openclaw_config_scope to update only memorySearch keys
# after an embeddings model switch.

select_embeddings_model_path() {
  local default_dir='' selected='' choice='' index=1 model='' models=()
  derive_models_directory_from_model_path "${EMBEDDINGS_MODEL_PATH:-${MODEL_PATH:-}}"
  default_dir="$REPLY"
  while true; do
    prompt_with_default 'Embeddings models directory path' "$default_dir"
    default_dir="$REPLY"
    if [ -d "$default_dir" ]; then break; fi
    error 'Directory not found. Please enter a valid path.'
  done
  while IFS= read -r model; do [ -z "$model" ] || models+=("$model"); done <<EOF
$(list_models_in_directory "$default_dir")
EOF
  if [ "${#models[@]}" -eq 0 ]; then
    prompt_with_default 'No GGUF models found. Enter full embeddings model path' "${EMBEDDINGS_MODEL_PATH:-}"
    selected="$REPLY"
    model_path_is_supported_file "$selected" || { error 'Embeddings model path must be an existing .gguf file.'; return 1; }
  elif [ "${#models[@]}" -eq 1 ]; then
    selected="$default_dir/${models[0]}"
    out "Using embeddings model: ${models[0]}"
  else
    out 'Available embeddings models:'
    for model in "${models[@]}"; do outf '  %s) %s' "$index" "$model"; index=$((index + 1)); done
    prompt_model_selection "${#models[@]}" '1'
    selected="$default_dir/${models[$((REPLY - 1))]}"
  fi
  EMBEDDINGS_MODEL_PATH="$selected"
}

embeddings_service_configured() {
  [ "${EMBEDDINGS_ENABLED:-false}" = true ] && return 0
  [ -n "${EMBEDDINGS_MODEL_PATH:-}" ] && [ -n "${EMBEDDINGS_LLAMA_PORT:-}" ] && return 0
  if command -v embeddings_llama_service_loaded >/dev/null 2>&1; then
    embeddings_llama_service_loaded user && return 0
    if command -v user_has_sudo >/dev/null 2>&1 && user_has_sudo; then
      embeddings_llama_service_loaded system && return 0
    fi
  fi
  return 1
}

detect_embeddings_llama_install_mode() {
  if command -v embeddings_llama_service_loaded >/dev/null 2>&1 && embeddings_llama_service_loaded user; then
    REPLY=user
    return 0
  fi
  if command -v user_has_sudo >/dev/null 2>&1 && user_has_sudo \
    && command -v embeddings_llama_service_loaded >/dev/null 2>&1 \
    && embeddings_llama_service_loaded system
  then
    REPLY=system
    return 0
  fi
  if [ -n "${EMBEDDINGS_LLAMA_PORT:-}" ] && llama_port_in_use "$EMBEDDINGS_LLAMA_PORT"; then
    REPLY=user
    return 0
  fi
  detect_existing_llama_install_mode >/dev/null 2>&1 || true
}

configure_embeddings_service() {
  local mode='' port_default='' port='' host='' ctx='' args=''
  EMBEDDINGS_ENABLED=true
  select_embeddings_model_path || return $?
  configured_or_default 'EMBEDDINGS_LLAMA_HOST' "${EMBEDDINGS_LLAMA_HOST:-}" '0.0.0.0'; host="$REPLY"
  configured_or_default 'EMBEDDINGS_LLAMA_PORT' "${EMBEDDINGS_LLAMA_PORT:-}" '11435'; port_default="$REPLY"
  while true; do
    if [ "$port_default" = "${LLAMA_PORT:-}" ] || llama_port_in_use "$port_default"; then
      llama_suggest_available_port "$HOST_IP" "$port_default" || { error 'No available embeddings port could be suggested.'; return 1; }
      warn "Embeddings port $port_default is unavailable."
      port_default="$REPLY"
    fi
    prompt_with_default 'Embeddings llama-server port' "$port_default"
    port="$REPLY"
    if [ "$port" != "${LLAMA_PORT:-}" ] && ! llama_port_in_use "$port"; then break; fi
    warn "Embeddings port $port is unavailable. Choose another port."
    port_default="$port"
  done
  configured_or_default 'EMBEDDINGS_LLAMA_CTX' "${EMBEDDINGS_LLAMA_CTX:-}" '8192'; ctx="$REPLY"
  prompt_with_default 'Embeddings context size' "$ctx"; ctx="$REPLY"
  configured_or_default 'EMBEDDINGS_LLAMA_EXTRA_ARGS' "${EMBEDDINGS_LLAMA_EXTRA_ARGS:-}" '--embedding'; args="$REPLY"
  prompt_with_default 'Embeddings llama-server extra args (whitespace-separated)' "$args"; args="$REPLY"
  EMBEDDINGS_LLAMA_HOST="$host"; EMBEDDINGS_LLAMA_PORT="$port"; EMBEDDINGS_LLAMA_CTX="$ctx"; EMBEDDINGS_LLAMA_EXTRA_ARGS="$args"; EMBEDDINGS_LLAMA_BASE_URL="http://${HOST_IP}:${port}/v1"
  write_env_from_template; source_env_file || return $?
  detect_embeddings_llama_install_mode >/dev/null 2>&1 || true; mode="${REPLY:-}"
  [ -n "$mode" ] || mode=user
  setup_embeddings_llama_service_for_mode "$mode" || return $?
}

restart_existing_embeddings_service() {
  local mode=''
  EMBEDDINGS_ENABLED=true
  write_env_from_template; source_env_file || return $?
  detect_embeddings_llama_install_mode >/dev/null 2>&1 || true; mode="${REPLY:-}"
  [ -n "$mode" ] || mode=user
  setup_embeddings_llama_service_for_mode "$mode" || return $?
}

setup_existing_embeddings_service_phase() {
  local choice='' label='' mode='' owner='' endpoint='' display_port='' local_endpoint='' healthy=false
  local installed_mode='' installed_port='' installed_host='' installed_bin='' installed_model='' installed_args='' installed_ctx=''
  local configured_enabled="${EMBEDDINGS_ENABLED:-false}"
  endpoint="$(embeddings_llama_configured_base_url)"
  label="$(embeddings_llama_label 2>/dev/null || printf '%s' 'com.clawbox.llama.embeddings')"
  owner='configured but not currently running'
  if command -v embeddings_llama_service_loaded >/dev/null 2>&1; then
    if embeddings_llama_service_loaded system; then
      installed_mode='system'
      owner='ClawBox-managed LaunchDaemon'
    elif embeddings_llama_service_loaded user; then
      installed_mode='user'
      owner='ClawBox-managed LaunchAgent'
    fi
  fi

  if [ -n "$installed_mode" ]; then
    embeddings_llama_mode_env_get "$installed_mode" EMBEDDINGS_LLAMA_PORT >/dev/null 2>&1 && installed_port="$REPLY"
    embeddings_llama_mode_env_get "$installed_mode" EMBEDDINGS_LLAMA_HOST >/dev/null 2>&1 && installed_host="$REPLY"
    embeddings_llama_mode_env_get "$installed_mode" EMBEDDINGS_LLAMA_BIN >/dev/null 2>&1 && installed_bin="$REPLY"
    embeddings_llama_mode_env_get "$installed_mode" EMBEDDINGS_MODEL_PATH >/dev/null 2>&1 && installed_model="$REPLY"
    embeddings_llama_mode_env_get "$installed_mode" EMBEDDINGS_LLAMA_CTX >/dev/null 2>&1 && installed_ctx="$REPLY"
    embeddings_llama_mode_env_get "$installed_mode" EMBEDDINGS_LLAMA_EXTRA_ARGS >/dev/null 2>&1 && installed_args="$REPLY"
  fi

  display_port="${installed_port:-${EMBEDDINGS_LLAMA_PORT:-11435}}"
  local_endpoint="http://$(llama_local_readiness_host "${installed_host:-${EMBEDDINGS_LLAMA_HOST:-0.0.0.0}}"):$display_port/v1"
  endpoint="http://${HOST_IP:-127.0.0.1}:$display_port/v1"
  if embeddings_llama_endpoint_responding "$local_endpoint"; then
    healthy=true
  fi

  if [ "$healthy" = true ]; then
    outf 'embeddings llama-server detected at %s' "$endpoint"
  else
    outf 'embeddings llama-server configured at %s' "$endpoint"
  fi
  blank_line
  outf 'Port: %s' "$display_port"
  outf 'Launch label: %s' "$label"
  outf 'Binary: %s' "${installed_bin:-${LLAMA_BIN:-unknown}}"
  outf 'Owner: %s' "$owner"
  if [ "$configured_enabled" = false ] && [ -n "$installed_mode" ]; then
    warn 'Embeddings are disabled in .env, but a ClawBox-managed embeddings service is installed.'
  fi
  if [ -n "$installed_port" ] && [ -n "${EMBEDDINGS_LLAMA_PORT:-}" ] && [ "$installed_port" != "$EMBEDDINGS_LLAMA_PORT" ]; then
    warn "Embeddings .env port (${EMBEDDINGS_LLAMA_PORT:-}) differs from the installed managed service port ($installed_port)."
  fi
  out 'This instance is managed separately from the primary llama-server.'
  menu_begin 'Options:'
  if [ "$healthy" = true ]; then
    outf '1) Use the existing running embeddings llama-server on port %s (recommended)' "$display_port"
  else
    outf '1) Use the existing embeddings llama-server on port %s' "$display_port"
  fi
  outf '2) Restart/update the existing embeddings llama-server on port %s' "$display_port"
  out '3) Reconfigure embeddings model/port'
  out '4) Disable embeddings'
  out '5) Skip embeddings management during setup'
  menu_end

  while true; do
    prompt_with_suffix 'Choose' '[1-5]'
    choice="${REPLY:-1}"
    case "$choice" in
      1)
        if [ "$healthy" = true ]; then
          local local_endpoint=''
          local configured_endpoint=''

          EMBEDDINGS_ENABLED=true
          if [ -n "$installed_port" ]; then
            [ -z "$installed_bin" ] || LLAMA_BIN="$installed_bin"
            [ -z "$installed_model" ] || EMBEDDINGS_MODEL_PATH="$installed_model"
            [ -z "$installed_host" ] || EMBEDDINGS_LLAMA_HOST="$installed_host"
            [ -z "$installed_port" ] || EMBEDDINGS_LLAMA_PORT="$installed_port"
            [ -z "$installed_ctx" ] || EMBEDDINGS_LLAMA_CTX="$installed_ctx"
            EMBEDDINGS_LLAMA_EXTRA_ARGS="$installed_args"
            EMBEDDINGS_LLAMA_BASE_URL="http://${HOST_IP:-127.0.0.1}:${EMBEDDINGS_LLAMA_PORT:-$display_port}/v1"
          fi

          if ! embeddings_llama_verify_configured_endpoint; then
            warn 'Existing embeddings llama-server is not healthy at the configured endpoint.'
            out 'Choose restart/update or reconfigure embeddings to repair it.'
            continue
          fi

          if [ -n "$installed_port" ]; then
            write_env_from_template
            source_env_file || return $?
          fi
          out 'Using existing embeddings llama-server.'
          local_endpoint="$(embeddings_llama_local_base_url)"
          configured_endpoint="$(embeddings_llama_configured_base_url)"
          if [ "$local_endpoint" != "$configured_endpoint" ]; then
            out "Local endpoint: $local_endpoint"
            out "Configured VM endpoint: $configured_endpoint"
          fi
          return 0
        fi
        warn 'Existing embeddings llama-server is not healthy at the configured endpoint.'
        out 'Choose restart/update or reconfigure embeddings to repair it.'
        ;;
      2)
        restart_existing_embeddings_service
        return $?
        ;;
      3)
        configure_embeddings_service
        return $?
        ;;
      4)
        EMBEDDINGS_ENABLED=false
        write_env_from_template; source_env_file || return $?
        out 'Embeddings disabled in ClawBox configuration. Existing services are not stopped automatically.'
        return 0
        ;;
      5)
        out 'Skipping embeddings management during setup.'
        return 0
        ;;
      *)
        error 'Invalid selection. Enter a number between 1 and 5.'
        ;;
    esac
  done
}

setup_embeddings_service_phase() {
  local choice=''
  section 'Optional Embeddings Service'
  if embeddings_service_configured; then
    setup_existing_embeddings_service_phase
    return $?
  fi

  prompt_yes_no 'Configure a separate host llama-server for embeddings?' 'n'
  choice="$REPLY"
  if ! is_yes "$choice"; then
    if [ -z "${EMBEDDINGS_ENABLED:-}" ]; then EMBEDDINGS_ENABLED=false; write_env_from_template; source_env_file || return $?; fi
    out 'Embeddings server is not configured.'
    return 0
  fi

  configure_embeddings_service
}

switch_embeddings_model() {
  local mode=''
  if [ "${EMBEDDINGS_ENABLED:-false}" != true ]; then
    out 'Embeddings server is not configured.'
    setup_embeddings_service_phase || return $?
    if command -v sync_model_openclaw_config_scope >/dev/null 2>&1; then
      sync_model_openclaw_config_scope memorySearch || return $?
    fi
    return 0
  fi
  section 'Embeddings Model'
  out "Current embeddings model: ${EMBEDDINGS_MODEL_PATH:-not configured}"
  out "Embeddings llama-server API: ${EMBEDDINGS_LLAMA_BASE_URL:-not configured}"
  prompt_yes_no 'Switch embeddings model?' 'n'
  is_yes "$REPLY" || { out 'Embeddings model is unchanged.'; return 0; }
  select_embeddings_model_path || return $?
  write_env_from_template; source_env_file || return $?
  detect_existing_llama_install_mode >/dev/null 2>&1 || true; mode="$REPLY"
  [ -n "$mode" ] || mode=user
  setup_embeddings_llama_service_for_mode "$mode" || return $?
  if command -v sync_model_openclaw_config_scope >/dev/null 2>&1; then
    sync_model_openclaw_config_scope memorySearch || return $?
  fi
  success "Embeddings llama-server now uses ${EMBEDDINGS_MODEL_PATH##*/}."
  out "Embeddings llama-server API: ${EMBEDDINGS_LLAMA_BASE_URL:-not configured}"
  if [ "${CONFIG_TARGETED_UPDATED:-false}" = true ]; then
    out 'OpenClaw config was not replaced; only ClawBox-managed memorySearch keys were synced.'
  elif [ "${CONFIG_TARGETED_NO_CHANGE:-false}" = true ]; then
    out 'OpenClaw config already matched; no OpenClaw changes were made.'
  fi
  out 'Check status with: ./clawbox status'
}
