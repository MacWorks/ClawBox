source_env_file() {
  if [ -f "$ENV_FILE" ]; then
    if ! bash -n "$ENV_FILE" >/dev/null 2>&1; then
      error "Invalid .env syntax: $ENV_FILE"
      error 'Fix the file or restore it from .env.example before running ./clawbox setup.'
      return 1
    fi

    set -a
    . "$ENV_FILE"
    set +a
  fi
}

replace_template_value() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local temp_file

  if [ -z "$value" ]; then
    return
  fi

  value="${value//$'\n'/}"
  value="${value//$'\r'/}"
  temp_file="$(mktemp)"

  awk -v key="$key" -v value="$value" '
    $0 ~ ("^" key "=") {
      print key "=\"" value "\""
      next
    }

    { print }
  ' "$file_path" > "$temp_file"

  mv "$temp_file" "$file_path"
}

write_env_from_template() {
  local temp_file

  if [ ! -f "$ENV_EXAMPLE_FILE" ]; then
    error_exit "Missing required file: $ENV_EXAMPLE_FILE"
  fi

  if [ -f "$ENV_FILE" ]; then
    if [ "$ENV_BACKUP_DECISION_MADE" != true ]; then
      blank_line

      ENV_BACKUP_DECISION_MADE=true
    fi

    if [ "$ENV_BACKUP_ENABLED" = true ]; then
      cp "$ENV_FILE" "$BASE_DIR/.env.bak"
    fi
  fi

  temp_file="$(mktemp)"
  cp "$ENV_EXAMPLE_FILE" "$temp_file"
  sed -i '' 's/ClawBox EXAMPLE Configuration/ClawBox Configuration/' "$temp_file"

  replace_template_value "$temp_file" "HOST_IP" "${HOST_IP:-}"
  replace_template_value "$temp_file" "VM_IP" "${VM_IP:-}"
  replace_template_value "$temp_file" "VM_USER" "${VM_USER:-}"
  replace_template_value "$temp_file" "VM_USER_PATH" "${VM_USER_PATH:-}"
  replace_template_value "$temp_file" "VM_HOST" "${VM_HOST:-}"
  replace_template_value "$temp_file" "VM_RUNTIME_PATH" "${VM_RUNTIME_PATH:-}"
  replace_template_value "$temp_file" "VM_MACHINE_NAME" "${VM_MACHINE_NAME:-}"
  replace_template_value "$temp_file" "MODEL_PATH" "${MODEL_PATH:-}"
  replace_template_value "$temp_file" "LLAMA_BIN" "${LLAMA_BIN:-}"
  replace_template_value "$temp_file" "LLAMA_HOST" "${LLAMA_HOST:-}"
  replace_template_value "$temp_file" "LLAMA_PORT" "${LLAMA_PORT:-}"
  replace_template_value "$temp_file" "LLAMA_CTX" "${LLAMA_CTX:-}"
  replace_template_value "$temp_file" "LLAMA_BASE_URL" "${LLAMA_BASE_URL:-}"
  replace_template_value "$temp_file" "LLAMA_EXTERNAL" "${LLAMA_EXTERNAL:-}"
  replace_template_value "$temp_file" "FIREWALL_SHARED_SUBNET" "${FIREWALL_SHARED_SUBNET:-}"
  replace_template_value "$temp_file" "OPENCLAW_PROVIDER_NAME" "${OPENCLAW_PROVIDER_NAME:-}"
  replace_template_value "$temp_file" "OPENCLAW_DEFAULT_MODEL" "${OPENCLAW_DEFAULT_MODEL:-}"
  replace_template_value "$temp_file" "OPENCLAW_AUTOSTART" "${OPENCLAW_AUTOSTART:-}"

  mv "$temp_file" "$ENV_FILE"
}

get_example_value() {
  local key="$1"

  if [ ! -f "$ENV_EXAMPLE_FILE" ]; then
    return
  fi

  awk -F= -v key="$key" '
    $0 ~ ("^" key "=") {
      value = substr($0, index($0, "=") + 1)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$ENV_EXAMPLE_FILE"
}

is_placeholder_value() {
  case "$1" in
    '' )
      return 1
      ;;
    *'<'*'>'*|'/path/to/'*|'your-provider-name'|'your-model-id'|'Your Model'|'Your VM Name in UTM'|'your-vm-username')
      return 0
      ;;
  esac

  return 1
}

value_needs_setup() {
  local key="$1"
  local current_value="$2"

  if [ -z "$current_value" ]; then
    return 0
  fi

  if is_placeholder_value "$current_value"; then
    return 0
  fi

  case "$key:$current_value" in
    'VM_USER:your-vm-username'|'VM_USER_PATH:/Users/<vm-user>'|'VM_IP:<vm-ip>'|'HOST_IP:<host-ip>'|'VM_HOST:<vm-user>@<vm-ip>'|'VM_RUNTIME_PATH:/Users/<vm-user>/ClawBox'|'MODEL_PATH:/Users/<vm-user>/ai/models/model.gguf'|'OPENCLAW_AUTOSTART:<true-or-false>')
      return 0
      ;;
  esac

  return 1
}

print_summary_value() {
  local key="$1"
  local value="$2"

  outf ' %-28s = "%s"' "$key" "$value"
}

normalize_openclaw_autostart() {
  local input_value="$1"

  case "$input_value" in
    ""|[Yy]|[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee])
      REPLY='true'
      return 0
      ;;
    [Nn]|[Nn][Oo]|[Ff][Aa][Ll][Ss][Ee])
      REPLY='false'
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

configured_or_default() {
  local key="$1"
  local current_value="$2"
  local fallback_value="$3"

  if is_placeholder_value "$current_value"; then
    current_value=''
  fi

  if is_placeholder_value "$fallback_value"; then
    fallback_value=''
  fi

  if [ -n "$current_value" ] && ! value_needs_setup "$key" "$current_value"; then
    REPLY="$current_value"
    return 0
  fi

  REPLY="$fallback_value"
  return 0
}
