setup_configure_model_selection() {
  local model_path_value=''
  local models_dir_default=''
  local models_dir_value=''
  local selected_model_name=''
  local selection_default=''
  local selection_index=''
  local model_path_default=''
  local model_name=''
  local model_number=''
  local model_recovery_choice=''
  local model_directory_candidate=''
  local model_files=()

  section "Model Configuration"
  derive_models_directory_from_model_path "${MODEL_PATH:-}"
  configured_or_default 'MODEL_PATH' "$REPLY" "/Users/${VM_USER}/models"
  models_dir_default="$REPLY"

  while true; do
    local path

    prompt_with_default 'Enter AI models directory path' "$models_dir_default"
    path="$REPLY"

    debug "path='%s'" "$path"
    debug "test -d => %s" "$( [ -d "$path" ] && echo yes || echo no )"

    if [ -d "$path" ]; then
      models_dir_value="$path"
      break
    fi

    error 'Directory not found. Please enter a valid path.'
    models_dir_default="$path"
  done

  while true; do
    model_files=()
    while IFS= read -r model_name; do
      if [ -n "$model_name" ]; then
        model_files+=("$model_name")
      fi
    done <<EOF
$(list_models_in_directory "$models_dir_value")
EOF

    if [ "${#model_files[@]}" -eq 0 ]; then
      warn 'No supported .gguf model files were found in:'
      out "$models_dir_value"
      blank_line
      out '1) Enter a different models directory'
      out '2) Enter a full model file path manually'
      out '3) Re-scan current directory'
      out '4) Abort setup'
      blank_line

      while true; do
        prompt_with_suffix 'Choose model setup option' '[1-4]'
        model_recovery_choice="$REPLY"

        if [ -z "$model_recovery_choice" ]; then
          model_recovery_choice='1'
        fi

        case "$model_recovery_choice" in
          1)
            while true; do
              prompt_with_default 'Enter AI models directory path' "$models_dir_value"
              model_directory_candidate="$REPLY"

              if [ -d "$model_directory_candidate" ]; then
                models_dir_value="$model_directory_candidate"
                break
              fi

              error 'Directory not found. Please enter a valid path.'
            done
            break
            ;;
          2)
            while true; do
              configured_or_default 'MODEL_PATH' "${MODEL_PATH:-}" ''
              model_path_default="$REPLY"
              prompt_with_default 'Enter full model path' "$model_path_default"
              model_path_value="$REPLY"

              if model_path_is_supported_file "$model_path_value"; then
                break
              fi

              error 'Model path must be an existing .gguf file.'
            done

            break 2
            ;;
          3)
            break
            ;;
          4)
            return "$LLAMA_EXIT_GRACEFUL"
            ;;
          *)
            error 'Invalid selection. Enter a number between 1 and 4.'
            ;;
        esac
      done

      continue
    fi

    if [ "${#model_files[@]}" -eq 1 ]; then
      selected_model_name="${model_files[0]}"
      out "Using model: $selected_model_name"
      model_path_value="$models_dir_value/$selected_model_name"
      break
    fi

    blank_line
    out 'Available Models:'

    model_number=1
    for model_name in "${model_files[@]}"; do
      outf '  %s) %s' "$model_number" "$model_name"
      model_number=$((model_number + 1))
    done

    blank_line

    selection_default='1'
    prompt_model_selection "${#model_files[@]}" "$selection_default"
    selection_index="$REPLY"
    selected_model_name="${model_files[$((selection_index - 1))]}"
    model_path_value="$models_dir_value/$selected_model_name"
    break
  done

  derive_model_filename "$model_path_value"
  selected_model_name="$REPLY"

  MODEL_PATH="$model_path_value"
  write_env_from_template
  source_env_file || return $?

  REPLY="$selected_model_name"
  return 0
}