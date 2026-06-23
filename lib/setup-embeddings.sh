# Optional host-only embeddings llama-server setup. It deliberately has no VM,
# OpenClaw configuration, deployment, or gateway lifecycle responsibilities.

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

setup_embeddings_service_phase() {
  local choice='' mode='' port_default='' port='' host='' ctx='' args=''
  section 'Optional Embeddings Service'
  prompt_yes_no 'Configure a separate host llama-server for embeddings?' 'n'
  choice="$REPLY"
  if ! is_yes "$choice"; then
    if [ -z "${EMBEDDINGS_ENABLED:-}" ]; then EMBEDDINGS_ENABLED=false; write_env_from_template; source_env_file || return $?; fi
    out 'Embeddings server is not configured.'
    return 0
  fi

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
  detect_existing_llama_install_mode >/dev/null 2>&1 || true; mode="$REPLY"
  [ -n "$mode" ] || mode=user
  setup_embeddings_llama_service_for_mode "$mode" || return $?
  success "Embeddings llama-server is responding at $EMBEDDINGS_LLAMA_BASE_URL"
}

switch_embeddings_model() {
  local mode=''
  if [ "${EMBEDDINGS_ENABLED:-false}" != true ]; then
    out 'Embeddings server is not configured.'
    setup_embeddings_service_phase
    return $?
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
  success "Embeddings llama-server now uses ${EMBEDDINGS_MODEL_PATH##*/}."
  out "Embeddings llama-server API: ${EMBEDDINGS_LLAMA_BASE_URL:-not configured}"
  out 'OpenClaw configuration and VM runtime were not changed.'
  out 'Check status with: ./clawbox status'
}
