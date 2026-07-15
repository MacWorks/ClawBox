# Prevent double-loading
if [ -n "${CLAWBOX_OUTPUT_SH_LOADED:-}" ]; then
  return 0
fi
CLAWBOX_OUTPUT_SH_LOADED=1

if [ -z "${COLOR_RESET+x}" ]; then
  if [ -t 1 ] || [ -t 2 ]; then
    COLOR_BOLD="\033[1m"
    COLOR_RED="\033[31m"
    COLOR_YELLOW="\033[33m"
    COLOR_GREEN="\033[32m"
    COLOR_RESET="\033[0m"
  else
    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_YELLOW=""
    COLOR_GREEN=""
    COLOR_RESET=""
  fi
fi

# Tracks whether last output was blank
CLAWBOX_OUTPUT_STATE_FILE="${CLAWBOX_OUTPUT_STATE_FILE:-${TMPDIR:-/tmp}/clawbox-output-state-$$}"
CLAWBOX_LAST_OUTPUT_WAS_BLANK=true
CLAWBOX_LAST_OUTPUT_TYPE="blank"
CLAWBOX_OUTPUT_EMITTED=false
printf '%s\n' "$CLAWBOX_LAST_OUTPUT_TYPE" > "$CLAWBOX_OUTPUT_STATE_FILE"

# -----------------------------
# Core primitives
# -----------------------------

_refresh_output_state() {
  if [ -f "$CLAWBOX_OUTPUT_STATE_FILE" ]; then
    IFS= read -r CLAWBOX_LAST_OUTPUT_TYPE < "$CLAWBOX_OUTPUT_STATE_FILE" || CLAWBOX_LAST_OUTPUT_TYPE="blank"
  else
    CLAWBOX_LAST_OUTPUT_TYPE="blank"
  fi

  if [ "$CLAWBOX_LAST_OUTPUT_TYPE" = "blank" ]; then
    CLAWBOX_LAST_OUTPUT_WAS_BLANK=true
  else
    CLAWBOX_LAST_OUTPUT_WAS_BLANK=false
  fi
}

status_tick_interval() {
  printf '%s\n' "${CLAWBOX_STATUS_INTERVAL_SECONDS:-0.075}"
}

_status_clear_line() {
  printf '\r\033[2K' >&2
}

_status_render_active_line() {
  _status_clear_line
  printf '%s' "$1" >&2
  CLAWBOX_LAST_OUTPUT_TYPE='status'
  CLAWBOX_LAST_OUTPUT_WAS_BLANK=false
}

_status_render_final_line() {
  _status_clear_line
  printf '%s\n' "$1" >&2
  _set_output_state "normal"
}

_status_suspend_rendering() {
  if [ "${CLAWBOX_STATUS_ACTIVE:-false}" = true ] && _status_can_spin; then
    _status_clear_line
    printf '\n' >&2
    _status_show_cursor
    _set_output_state "blank"
    CLAWBOX_STATUS_ACTIVE=false
    CLAWBOX_STATUS_MESSAGE=''
    CLAWBOX_STATUS_SPINNER_INDEX=0
  fi
}

_should_preserve_prompt_state() {
  local shared_output_type

  if [ "${BASH_SUBSHELL:-0}" -le 0 ]; then
    return 1
  fi

  if [ "${CLAWBOX_LAST_OUTPUT_TYPE:-blank}" != "prompt" ]; then
    return 1
  fi

  if [ -f "$CLAWBOX_OUTPUT_STATE_FILE" ]; then
    IFS= read -r shared_output_type < "$CLAWBOX_OUTPUT_STATE_FILE" || shared_output_type="blank"
  else
    shared_output_type="blank"
  fi

  [ "$shared_output_type" = "prompt" ]
}

_set_output_state() {
  local next_output_type="$1"

  if _should_preserve_prompt_state && [ "$next_output_type" != 'blank' ]; then
    CLAWBOX_LAST_OUTPUT_TYPE="$next_output_type"

    if [ "$CLAWBOX_LAST_OUTPUT_TYPE" = "blank" ]; then
      CLAWBOX_LAST_OUTPUT_WAS_BLANK=true
    else
      CLAWBOX_LAST_OUTPUT_WAS_BLANK=false
    fi

    return
  fi

  CLAWBOX_LAST_OUTPUT_TYPE="$next_output_type"
  CLAWBOX_OUTPUT_EMITTED=true

  if [ "$CLAWBOX_LAST_OUTPUT_TYPE" = "blank" ]; then
    CLAWBOX_LAST_OUTPUT_WAS_BLANK=true
  else
    CLAWBOX_LAST_OUTPUT_WAS_BLANK=false
  fi

  printf '%s\n' "$CLAWBOX_LAST_OUTPUT_TYPE" > "$CLAWBOX_OUTPUT_STATE_FILE"
}

_prepare_normal_output() {
  _status_suspend_rendering
  _refresh_output_state

  if [ "$CLAWBOX_LAST_OUTPUT_TYPE" = "prompt" ] && [ "$CLAWBOX_LAST_OUTPUT_WAS_BLANK" = false ]; then
    _print_blank
  fi
}

_prepare_normal_output_err() {
  _status_suspend_rendering
  _refresh_output_state

  if [ "$CLAWBOX_LAST_OUTPUT_TYPE" = "prompt" ] && [ "$CLAWBOX_LAST_OUTPUT_WAS_BLANK" = false ]; then
    _print_blank_err
  fi
}

_prepare_prompt_output() {
  _status_suspend_rendering
  _refresh_output_state

  if [ "${CLAWBOX_OUTPUT_EMITTED:-false}" != true ]; then
    printf '\n' >&2
    _set_output_state 'blank'
    return 0
  fi

  if [ "$CLAWBOX_LAST_OUTPUT_TYPE" = 'prompt' ]; then
    return 0
  fi

  if [ "$CLAWBOX_LAST_OUTPUT_TYPE" != 'blank' ]; then
    _print_blank_err
  fi
}

_print_line() {
  _prepare_normal_output
  printf '%s\n' "$1"
  _set_output_state "normal"
}

_print_line_err() {
  _prepare_normal_output_err
  printf '%s\n' "$1" >&2
  _set_output_state "normal"
}

_print_blank() {
  _refresh_output_state

  if [ "$CLAWBOX_LAST_OUTPUT_WAS_BLANK" = false ]; then
    printf '\n'
    _set_output_state "blank"
  fi
}

_print_blank_err() {
  _refresh_output_state

  if [ "$CLAWBOX_LAST_OUTPUT_WAS_BLANK" = false ]; then
    printf '\n' >&2
    _set_output_state "blank"
  fi
}

_print_formatted_line() {
  local color="$1"
  local message="$2"

  _prepare_normal_output
  if [ "$CLAWBOX_LAST_OUTPUT_TYPE" != 'blank' ]; then
    _print_blank
  fi

  printf '%b%s%b\n' "${color}${COLOR_BOLD:-}" "$message" "${COLOR_RESET:-}"
  _set_output_state "callout"
  _print_blank
}

_print_formatted_line_err() {
  local color="$1"
  local message="$2"

  _prepare_normal_output_err
  if [ "$CLAWBOX_LAST_OUTPUT_TYPE" != 'blank' ]; then
    _print_blank_err
  fi

  printf '%b%s%b\n' "${color}${COLOR_BOLD:-}" "$message" "${COLOR_RESET:-}" >&2
  _set_output_state "callout"
  _print_blank_err
}

# -----------------------------
# Public API
# -----------------------------

blank_line() {
  _print_blank
}

out() {
  if [ -z "$1" ]; then
    _print_blank
    return
  fi
  _print_line "$1"
}

err() {
  if [ -z "$1" ]; then
    _print_blank
    return
  fi
  _print_line_err "$1"
}

outf() {
  local format="$1"; shift
  _prepare_normal_output
  printf "$format\n" "$@"
  _set_output_state "normal"
}

errf() {
  local format="$1"; shift
  _prepare_normal_output_err
  printf "$format\n" "$@" >&2
  _set_output_state "normal"
}

debug() {
  local format="$1"; shift

  if [ "${DEBUG_MODE:-false}" != true ]; then
    return 0
  fi

  _prepare_normal_output
  printf "DEBUG: %s\n" "$(printf "$format" "$@")" >&2
  _set_output_state "normal"
}

step() {
  out "$1"
}

# -----------------------------
# Highlighted output (strict spacing)
# -----------------------------

success() {
  _print_formatted_line "${COLOR_GREEN:-}" "$1"
}

warn() {
  _print_formatted_line_err "${COLOR_YELLOW:-}" "$1"
}

error() {
  _print_formatted_line_err "${COLOR_RED:-}" "$1"
}

err_blank_line() {
  _print_blank_err
}

# -----------------------------
# Structural elements
# -----------------------------

divider() {
  _refresh_output_state
  printf '%s\n' '-----------------------------------------'
  _set_output_state "section"
}

section() {
  blank_line
  divider
  printf '%b%s%b\n' "${COLOR_BOLD:-}" " > $1" "${COLOR_RESET:-}"
  _set_output_state "section"
  divider
  blank_line
}

menu_begin() {
  blank_line
  out "$1"
  blank_line
}

menu_end() {
  blank_line
}

title() {
  local content=''
  local padding=0
  local right_padding=0

  blank_line
  _set_output_state "normal"
  blank_line
  divider
  content=">  $1  <"
  padding=$(((41 - ${#content}) / 2))
  [ "$padding" -ge 0 ] || padding=0
  right_padding=$((41 - padding - ${#content}))
  [ "$right_padding" -ge 0 ] || right_padding=0
  printf '%*s%b%s%b%*s\n' "$padding" '' "${COLOR_BOLD:-}" "$content" "${COLOR_RESET:-}" "$right_padding" ''
  _set_output_state "section"
  divider
  blank_line
}

# -----------------------------
# Prompts
# -----------------------------

prompt_text() {
  _prepare_prompt_output
  printf '%s ' "$1" >&2
  _set_output_state "prompt"
}

prompt() {
  prompt_text "$1"
}

prompt_complete() {
  return 0
}

# -----------------------------
# Progress (no newline)
# -----------------------------

progress() {
  if [ "${CLAWBOX_STATUS_ACTIVE:-false}" = true ] && _status_can_spin; then
    _status_render_active_line "$1"
    return 0
  fi

  _prepare_normal_output_err
  _status_render_active_line "$1"
}

progress_done() {
  if [ "${CLAWBOX_STATUS_ACTIVE:-false}" = true ] && _status_can_spin; then
    _status_render_final_line "$1"
    return 0
  fi

  _prepare_normal_output_err
  _status_render_final_line "$1"
}

CLAWBOX_STATUS_ACTIVE=false
CLAWBOX_STATUS_MESSAGE=''
CLAWBOX_STATUS_SPINNER_INDEX=0
CLAWBOX_CURSOR_HIDDEN=false

_append_trap() {
  local trap_command="$1"
  local signal_name="$2"
  local existing_trap=''

  existing_trap="$(trap -p "$signal_name")"
  existing_trap="$(printf '%s' "$existing_trap" | sed -n "s/^trap -- '\(.*\)' $signal_name$/\1/p")"

  if [ -n "$existing_trap" ]; then
    trap "$existing_trap
$trap_command" "$signal_name"
  else
    trap "$trap_command" "$signal_name"
  fi
}

_status_show_cursor() {
  if [ "${CLAWBOX_CURSOR_HIDDEN:-false}" = true ]; then
    printf '\033[?25h' >&2
    CLAWBOX_CURSOR_HIDDEN=false
  fi
}

_status_hide_cursor() {
  if _status_can_spin && [ "${CLAWBOX_CURSOR_HIDDEN:-false}" != true ]; then
    printf '\033[?25l' >&2
    CLAWBOX_CURSOR_HIDDEN=true
  fi
}

_status_restore_on_exit() {
  _status_show_cursor
}

install_status_exit_trap() {
  if [ "${CLAWBOX_STATUS_TRAP_INSTALLED:-false}" = true ]; then
    return 0
  fi

  _append_trap '_status_restore_on_exit' EXIT
  CLAWBOX_STATUS_TRAP_INSTALLED=true
}

_status_can_spin() {
  [ -t 2 ]
}

_status_spinner_frame() {
  case "${CLAWBOX_STATUS_SPINNER_INDEX:-0}" in
    0) REPLY='/' ;;
    1) REPLY='-' ;;
    2) REPLY='\' ;;
    *) REPLY='|' ;;
  esac
}

_status_render_message() {
  local message="$1"
  local frame="${2:-}"
  local base_message="$message"

  case "$base_message" in
    *...)
      base_message="${base_message%...}"
      ;;
  esac

  if [ -n "$frame" ]; then
    REPLY="$base_message $frame"
  else
    REPLY="$base_message"
  fi
}

_status_finalize_message() {
  local message="$1"
  local level="${2:-info}"
  local color=''

  case "$level" in
    success)
      color="${COLOR_GREEN:-}"
      ;;
    warning)
      color="${COLOR_YELLOW:-}"
      ;;
    error)
      color="${COLOR_RED:-}"
      ;;
    progress|plain|info)
      color=''
      ;;
  esac

  if [ -n "$color" ] && [ -n "${COLOR_BOLD:-}" ]; then
    printf -v REPLY '%b%s%b' "${color}${COLOR_BOLD:-}" "$message" "${COLOR_RESET:-}"
    return 0
  fi

  REPLY="$message"
  return 0
}

_status_prepare_begin() {
  _refresh_output_state

  if [ "${CLAWBOX_LAST_OUTPUT_TYPE:-blank}" != 'prompt' ]; then
    err_blank_line
  fi
}

status_begin() {
  local message="$1"
  local can_spin=false

  CLAWBOX_STATUS_ACTIVE=true
  CLAWBOX_STATUS_MESSAGE="$message"
  CLAWBOX_STATUS_SPINNER_INDEX=0

  if _status_can_spin; then
    can_spin=true
    _status_prepare_begin
  else
    blank_line
  fi

  if [ "$can_spin" = true ]; then
    _status_hide_cursor
    _status_render_message "$message"
    _status_render_active_line "$REPLY"
  else
    out "$message"
  fi
}

status_tick() {
  local message="${1:-${CLAWBOX_STATUS_MESSAGE:-}}"

  [ "${CLAWBOX_STATUS_ACTIVE:-false}" = true ] || return 0

  if _status_can_spin; then
    _status_spinner_frame
    _status_render_message "$message" "$REPLY"
    _status_render_active_line "$REPLY"
    CLAWBOX_STATUS_SPINNER_INDEX=$(((CLAWBOX_STATUS_SPINNER_INDEX + 1) % 4))
  fi
}

status_sleep() {
  local duration="$1"
  local message="${2:-${CLAWBOX_STATUS_MESSAGE:-}}"
  local interval=''
  local full_ticks=0
  local remainder=''
  local tick=0

  if ! _status_can_spin; then
    sleep "$duration"
    return 0
  fi

  interval="$(status_tick_interval)"
  full_ticks="$(awk -v duration="$duration" -v interval="$interval" 'BEGIN { print int(duration / interval) }')"
  remainder="$(awk -v duration="$duration" -v interval="$interval" 'BEGIN { printf "%.6f", duration - (int(duration / interval) * interval) }')"

  if [ "$full_ticks" -eq 0 ]; then
    sleep "$duration"
    status_tick "$message"
    return 0
  fi

  while [ "$tick" -lt "$full_ticks" ]; do
    sleep "$interval"
    status_tick "$message"
    tick=$((tick + 1))
  done

  if awk -v remainder="$remainder" 'BEGIN { exit(remainder > 0.000001 ? 0 : 1) }'; then
    sleep "$remainder"
    status_tick "$message"
  fi
}

status_end() {
  local message="$1"
  local level="${2:-info}"
  local preserved_reply="${REPLY-}"
  local final_message=''

  _status_show_cursor

  if [ "${CLAWBOX_STATUS_ACTIVE:-false}" = true ] && _status_can_spin; then
    if [ -z "$message" ]; then
      _status_clear_line
      printf '\n' >&2
      _set_output_state 'blank'
      REPLY="$preserved_reply"
      CLAWBOX_STATUS_ACTIVE=false
      CLAWBOX_STATUS_MESSAGE=''
      CLAWBOX_STATUS_SPINNER_INDEX=0
      return 0
    fi

    _status_finalize_message "$message" "$level"
    final_message="$REPLY"
    REPLY="$preserved_reply"
    _status_render_final_line "$final_message"
  else
    case "$level" in
      success)
        success "$message"
        ;;
      warning)
        warn "$message"
        ;;
      error)
        error "$message"
        ;;
      progress|plain|info)
        out "$message"
        ;;
      *)
        out "$message"
        ;;
    esac
  fi

  REPLY="$preserved_reply"

  CLAWBOX_STATUS_ACTIVE=false
  CLAWBOX_STATUS_MESSAGE=''
  CLAWBOX_STATUS_SPINNER_INDEX=0
}

terminal_safe_exit() {
  local status="${1:-0}"

  _status_show_cursor
  blank_line
  exit "$status"
}

status_suspend() {
  _status_suspend_rendering
}

status_wait_for_pid() {
  local pid="$1"
  local message="$2"
  local wait_interval=''

  wait_interval="$(status_tick_interval)"

  status_begin "$message"

  while kill -0 "$pid" >/dev/null 2>&1; do
    status_sleep "$wait_interval" "$message"
  done
}
