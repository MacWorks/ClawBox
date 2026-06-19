ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILURES=${FAILURES:-0}
TEMP_DIR="${TEMP_DIR:-}"
MOCK_BIN_DIR="${MOCK_BIN_DIR:-}"
ORIGINAL_PATH="${ORIGINAL_PATH:-$PATH}"
PROMPT_INDEX=${PROMPT_INDEX:-0}
PROMPT_QUEUE=()
PROMPT_ANSWER="${PROMPT_ANSWER:-}"

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

cleanup_temp_dir() {
  PATH="$ORIGINAL_PATH"
  export PATH

  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}

setup_mock_bin_dir() {
  MOCK_BIN_DIR="$TEMP_DIR/mock-bin"
  mkdir -p "$MOCK_BIN_DIR"
  PATH="$MOCK_BIN_DIR:$ORIGINAL_PATH"
  export PATH
}

write_mock_command() {
  local name="$1"
  local content="$2"

  if [ -z "$MOCK_BIN_DIR" ]; then
    fail 'write_mock_command called before setup_mock_bin_dir'
    return 1
  fi

  printf '%s\n' "$content" > "$MOCK_BIN_DIR/$name"
  chmod +x "$MOCK_BIN_DIR/$name"
}

run_test() {
  local test_name="$1"
  local status=0

  set +e
  "$test_name"
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    fail "$test_name exited unexpectedly with status $status"
  fi
}

assert_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_not_contains() {
  local description="$1"
  local haystack="$2"
  local needle="$3"

  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$description"
  else
    pass "$description"
  fi
}

assert_equals() {
  local description="$1"
  local actual="$2"
  local expected="$3"

  if [ "$actual" = "$expected" ]; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_no_excessive_blank_lines() {
  local description="$1"
  local haystack="$2"

  if printf '%s\n' "$haystack" | awk '
    /^$/ { run++; if (run > max_run) max_run = run; next }
    { run = 0 }
    END { exit !(max_run > 25) }
  '; then
    fail "$description"
  else
    pass "$description"
  fi
}

render_terminal_output() {
  printf '%s' "$1" | perl -e '
    use strict;
    use warnings;

    local $/;
    my $input = <STDIN>;
    my @lines;
    my $line = q{};

    pos($input) = 0;
    while (pos($input) < length($input)) {
      if ($input =~ /\G\r/gc) {
        $line = q{};
        next;
      }

      if ($input =~ /\G\n/gc) {
        push @lines, $line;
        $line = q{};
        next;
      }

      if ($input =~ /\G\e\[[0-9;?]*[A-Za-z]/gc) {
        next;
      }

      if ($input =~ /\G([^\r\n\e]+)/gc) {
        $line .= $1;
        next;
      }

      if ($input =~ /\G(.)/gcs) {
        $line .= $1;
      }
    }

    push @lines, $line if length($line);
    print join("\n", @lines);
  '
}

load_setup_functions() {
  local setup_lib="$TEMP_DIR/setup-lib.sh"

  sed \
    -e "s|^BASE_DIR=.*$|BASE_DIR=\"$ROOT_DIR\"|" \
    -e 's/VM_REPAIR_MODE=true exec "$0"/return 0/' \
    -e '/^status=0$/,$d' \
    "$ROOT_DIR/scripts/setup.sh" > "$setup_lib"

  # Loading setup definitions emits the interactive header; tests exercise the
  # individual functions and should not repeat it for every fixture.
  # shellcheck source=/dev/null
  . "$setup_lib" >/dev/null 2>&1
}

queue_prompt_answers() {
  PROMPT_INDEX=0
  PROMPT_QUEUE=("$@")
}

take_prompt_answer() {
  PROMPT_ANSWER="${PROMPT_QUEUE[$PROMPT_INDEX]:-}"
  PROMPT_INDEX=$((PROMPT_INDEX + 1))
}

install_prompt_stubs() {
  _normalize_stub_prompt_answer() {
    local value="$1"

    if command -v sanitize_prompt_value >/dev/null 2>&1; then
      sanitize_prompt_value "$value"
      REPLY="$REPLY"
      return 0
    fi

    value="$(printf '%s' "$value" | tr -d '\r\n')"
    value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    REPLY="$value"
    return 0
  }

  prompt_with_suffix() {
    local label="$1"
    local suffix="$2"
    local answer

    prompt "$label $suffix:"
    take_prompt_answer
    prompt_complete
    answer="$PROMPT_ANSWER"
    _normalize_stub_prompt_answer "$answer"
    answer="$REPLY"
    REPLY="$answer"
    return 0
  }

  prompt_with_default() {
    local label="$1"
    local default_value="$2"
    local allow_empty="${3:-false}"
    local answer

    if [ -n "$default_value" ]; then
      prompt "$label [$default_value]:"
    else
      prompt "$label:"
    fi

    take_prompt_answer
    prompt_complete
    answer="$PROMPT_ANSWER"
    _normalize_stub_prompt_answer "$answer"
    answer="$REPLY"

    if [ -n "$answer" ]; then
      REPLY="$answer"
      return 0
    fi

    if [ "$allow_empty" = 'true' ]; then
      REPLY=''
      return 0
    fi

    REPLY="$default_value"
    return 0
  }

  prompt_resolved_value() {
    local label="$1"
    local key="$2"
    local current_value="$3"
    local fallback_value="$4"
    local resolved_value

    resolved_value="$fallback_value"
    if [ -n "$current_value" ]; then
      resolved_value="$current_value"
    fi

    prompt_with_default "$label" "$resolved_value"
  }

  prompt_yes_no() {
    local label="$1"
    local default="$2"
    local suffix
    local answer

    if [ "$default" = 'y' ]; then
      suffix='[Y/n]'
    else
      suffix='[y/N]'
    fi

    prompt_with_suffix "$label" "$suffix"
    answer="$REPLY"

    if [ -z "$answer" ]; then
      answer="$default"
    fi

    case "$answer" in
      y|Y|yes|YES)
        REPLY='true'
        ;;
      *)
        REPLY='false'
        ;;
    esac
    return 0
  }

  prompt_model_selection() {
    local model_count="$1"
    local default_selection="$2"
    local answer

    prompt_with_suffix 'Choose AI model' "[1-$model_count]"
    answer="$REPLY"

    if [ -z "$answer" ]; then
      answer="$default_selection"
    fi

    REPLY="$answer"
    return 0
  }

  prompt_openclaw_autostart() {
    local current_value="$1"
    local default_value='true'
    local answer

    if [ -n "$current_value" ]; then
      default_value="$current_value"
    fi

    prompt_with_suffix 'Start OpenClaw automatically after setup using launchd when it is stopped?' '[Y/n]'
    answer="$REPLY"

    if [ -z "$answer" ]; then
      answer="$default_value"
    fi

    REPLY="$answer"
    return 0
  }
}
