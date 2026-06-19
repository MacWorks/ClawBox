#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
TEMP_DIR=""

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

cleanup() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}

trap cleanup EXIT

assert_line_count() {
  local description="$1"
  local file_path="$2"
  local expected_count="$3"
  local actual_count

  actual_count=$(awk 'END { print NR }' "$file_path")

  if [ "$actual_count" = "$expected_count" ]; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_line_equals() {
  local description="$1"
  local file_path="$2"
  local line_number="$3"
  local expected_value="$4"
  local actual_value

  actual_value=$(sed -n "${line_number}p" "$file_path")

  if [ "$actual_value" = "$expected_value" ]; then
    pass "$description"
  else
    fail "$description"
  fi
}

capture_scenario() {
  local output_file="$1"
  local scenario_name="$2"

  (
    source "$ROOT_DIR/lib/output.sh"
    "$scenario_name"
  ) > "$output_file" 2>&1
}

scenario_prompt_then_output() {
  prompt 'Prompt:'
  printf '1\n'
  prompt_complete
  out 'value'
}

scenario_prompt_then_prompt() {
  prompt 'First:'
  printf '1\n'
  prompt_complete
  prompt 'Second:'
  printf '2\n'
  prompt_complete
}

scenario_section_then_prompt() {
  section 'Network + VM Configuration'
  prompt 'Enter VM host:'
  printf 'vm-user@192.168.64.2\n'
  prompt_complete
}

scenario_menu_then_prompt() {
  out 'VM IP discovery completed.'
  out 'The current VM IP address (192.168.64.7) was unreachable.'
  menu_begin 'Detected possible VM addresses:'
  out '1) 192.168.64.6'
  out '2) Retry manual entry'
  menu_end
  prompt 'Choose VM address [1-2]:'
  printf '1\n'
  prompt_complete
}

scenario_end_of_script() {
  out 'done'
  terminal_safe_exit 0
}

scenario_long_title() {
  title 'ClawBox System State'
}

test_prompt_then_output() {
  local output_file="$TEMP_DIR/prompt-then-output.txt"

  capture_scenario "$output_file" scenario_prompt_then_output

  assert_line_count 'prompt to output emits one blank line above and below the prompt before output' "$output_file" 4
  assert_line_equals 'prompt to output keeps a blank line above the prompt' "$output_file" 1 ''
  assert_line_equals 'prompt to output keeps prompt and user input on second line' "$output_file" 2 'Prompt: 1'
  assert_line_equals 'prompt to output inserts one blank separator line below the prompt' "$output_file" 3 ''
  assert_line_equals 'prompt to output keeps output on fourth line' "$output_file" 4 'value'
}

test_prompt_then_prompt() {
  local output_file="$TEMP_DIR/prompt-then-prompt.txt"

  capture_scenario "$output_file" scenario_prompt_then_prompt

  assert_line_count 'prompt to prompt emits one blank line above the first prompt and no separator between prompts' "$output_file" 3
  assert_line_equals 'prompt to prompt keeps a blank line above the first prompt' "$output_file" 1 ''
  assert_line_equals 'prompt to prompt keeps the first prompt and reply together' "$output_file" 2 'First: 1'
  assert_line_equals 'prompt to prompt keeps the second prompt and reply together without blank drift' "$output_file" 3 'Second: 2'
}

test_section_then_prompt() {
  local output_file="$TEMP_DIR/section-then-prompt.txt"

  capture_scenario "$output_file" scenario_section_then_prompt

  assert_line_count 'section to prompt emits section block plus prompt without extra trailing blank line' "$output_file" 5
  assert_line_equals 'section to prompt starts with divider' "$output_file" 1 '-----------------------------------------'
  assert_line_equals 'section to prompt shows section title' "$output_file" 2 ' > Network + VM Configuration'
  assert_line_equals 'section to prompt ends section with divider' "$output_file" 3 '-----------------------------------------'
  assert_line_equals 'section to prompt keeps exactly one blank separator line' "$output_file" 4 ''
  assert_line_equals 'section to prompt places prompt after separator' "$output_file" 5 'Enter VM host: vm-user@192.168.64.2'
}

test_menu_then_prompt() {
  local output_file="$TEMP_DIR/menu-then-prompt.txt"

  capture_scenario "$output_file" scenario_menu_then_prompt

  assert_line_count 'menu to prompt emits a separated menu block and prompt without trailing blank drift' "$output_file" 9
  assert_line_equals 'menu to prompt keeps completion status on first line' "$output_file" 1 'VM IP discovery completed.'
  assert_line_equals 'menu to prompt keeps warning line on second line' "$output_file" 2 'The current VM IP address (192.168.64.7) was unreachable.'
  assert_line_equals 'menu to prompt keeps one blank line above the menu heading' "$output_file" 3 ''
  assert_line_equals 'menu to prompt keeps menu heading on fourth line' "$output_file" 4 'Detected possible VM addresses:'
  assert_line_equals 'menu to prompt keeps one blank line between heading and options' "$output_file" 5 ''
  assert_line_equals 'menu to prompt keeps first option on sixth line' "$output_file" 6 '1) 192.168.64.6'
  assert_line_equals 'menu to prompt keeps second option on seventh line' "$output_file" 7 '2) Retry manual entry'
  assert_line_equals 'menu to prompt keeps one separator blank line before the prompt' "$output_file" 8 ''
  assert_line_equals 'menu to prompt keeps prompt on ninth line' "$output_file" 9 'Choose VM address [1-2]: 1'
}

test_end_of_script() {
  local output_file="$TEMP_DIR/end-of-script.txt"
  local status=0

  if capture_scenario "$output_file" scenario_end_of_script; then
    status=0
  else
    status=$?
  fi

  if [ "$status" = '0' ]; then
    pass 'terminal safe exit keeps zero status'
  else
    fail 'terminal safe exit keeps zero status'
  fi

  assert_line_count 'end of script emits final blank line exactly once' "$output_file" 2
  assert_line_equals 'end of script keeps final content on first line' "$output_file" 1 'done'
  assert_line_equals 'end of script keeps second line blank' "$output_file" 2 ''
}

test_long_title_centering() {
  local output_file="$TEMP_DIR/long-title.txt"
  local title_line=''
  local content='>  ClawBox System State  <'
  local left_padding=''

  capture_scenario "$output_file" scenario_long_title
  title_line="$(grep -F "$content" "$output_file")"
  left_padding="${title_line%%"$content"*}"

  if [ "${#title_line}" -eq 41 ] && [ "${#left_padding}" -eq 7 ]; then
    pass 'long title centers within the divider width'
  else
    fail 'long title should center within the divider width'
  fi
}

printf 'Running output spacing tests\n'

TEMP_DIR="$(mktemp -d)"

test_prompt_then_output
test_prompt_then_prompt
test_section_then_prompt
test_menu_then_prompt
test_end_of_script
test_long_title_centering

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
