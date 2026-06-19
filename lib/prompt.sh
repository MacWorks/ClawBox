source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

sanitize_prompt_value() {
  local value="$1"

  value="$(printf '%s' "$value" | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g; s/[\r\n]//g; s/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]//g')"
  value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

  REPLY="$value"
  return 0
}

sanitize_prompt_default_value() {
  sanitize_prompt_value "$1"
}

prompt_with_suffix() {
  local label="$1"
  local suffix="$2"
  local input_value
  local prompt_label

  prompt_label="$label $suffix:"
  prompt "$prompt_label"
  read -r input_value || input_value=""
  prompt_complete
  sanitize_prompt_value "$input_value"
  input_value="$REPLY"
  REPLY="$input_value"

  return 0
}

prompt_yes_no() {
  local label="$1"
  local default="$2"
  local suffix
  local input

  default="$(printf '%s' "$default" | tr '[:upper:]' '[:lower:]')"

  if [ "$default" = "y" ]; then
    suffix='[Y/n]'
  else
    suffix='[y/N]'
  fi

  while true; do
    prompt_with_suffix "$label" "$suffix"
    input="$REPLY"
    input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"

    if [ -z "$input" ]; then
      input="$default"
    fi

    case "$input" in
      y|yes)
        REPLY='true'
        return 0
        ;;
      n|no)
        REPLY='false'
        return 0
        ;;
    esac

    error 'Invalid input. Enter y, yes, n, or no.'
  done
}

prompt_with_default() {
  local label="$1"
  local default_value="$2"
  local input_value
  local prompt_label
  local allow_empty="${3:-false}"

  sanitize_prompt_default_value "$default_value"
  default_value="$REPLY"

  while true; do
    if [ -n "$default_value" ]; then
      prompt_label="$label [$default_value]:"
    else
      prompt_label="$label:"
    fi

    prompt "$prompt_label"

    read -r input_value || input_value=""
    prompt_complete
    sanitize_prompt_value "$input_value"
    input_value="$REPLY"

    if [ -n "$input_value" ]; then
      REPLY="$input_value"
      return 0
    fi

    if [ "$allow_empty" = 'true' ]; then
      REPLY=''
      return 0
    fi

    if [ -n "$default_value" ]; then
      REPLY="$default_value"
      return 0
    fi

    error 'Value required.'
  done
}

prompt_model_selection() {
  local model_count="$1"
  local default_selection="$2"
  local input_value

  while true; do
    prompt_with_suffix 'Choose AI model' "[1-$model_count]"
    input_value="$REPLY"

    if [ -z "$input_value" ] && [ -n "$default_selection" ]; then
      REPLY="$default_selection"
      return 0
    fi

    if ! [[ "$input_value" =~ ^[0-9]+$ ]]; then
      error "Invalid selection. Enter a number between 1 and $model_count."
      continue
    fi

    if [ "$input_value" -lt 1 ] || [ "$input_value" -gt "$model_count" ]; then
      error "Invalid selection. Enter a number between 1 and $model_count."
      continue
    fi

    REPLY="$input_value"
    return 0
  done
}

prompt_resolved_value() {
  local label="$1"
  local key="$2"
  local current_value="$3"
  local fallback_value="$4"

  command -v configured_or_default >/dev/null 2>&1 || {
    log_error "Required function not found: configured_or_default"
    return 1
  }

  configured_or_default "$key" "$current_value" "$fallback_value" >/dev/null
  prompt_with_default "$label" "$REPLY" false
  return $?
}

prompt_openclaw_autostart() {
  local current_value="$1"
  local default_value
  local prompt_suffix
  local input_value

  command -v value_needs_setup >/dev/null 2>&1 || {
    log_error "Required function not found: value_needs_setup"
    return 1
  }
  command -v normalize_openclaw_autostart >/dev/null 2>&1 || {
    log_error "Required function not found: normalize_openclaw_autostart"
    return 1
  }

  if [ "$ENV_CREATED_FROM_EXAMPLE" = false ] && [ -n "$current_value" ] && ! value_needs_setup "OPENCLAW_AUTOSTART" "$current_value"; then
    default_value="$current_value"
  else
    default_value="true"
  fi

  if [ "$default_value" = "false" ]; then
    prompt_suffix='[y/N]'
  else
    prompt_suffix='[Y/n]'
  fi

  while true; do
    prompt_with_suffix 'Start OpenClaw automatically after setup using launchd when it is stopped?' "$prompt_suffix"
    input_value="$REPLY"

    if [ -z "$input_value" ]; then
      REPLY="$default_value"
      return 0
    fi

    if normalize_openclaw_autostart "$input_value"; then
      input_value="$REPLY"
      REPLY="$input_value"
      return 0
    fi

    error 'Invalid input. Enter y, yes, n, or no.'
  done
}
