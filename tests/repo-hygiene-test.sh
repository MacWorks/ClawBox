#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

assert_no_matches() {
  local description="$1"
  local find_args=("$@")
  local matches=''

  find_args=("${find_args[@]:1}")

  matches="$(find "$ROOT_DIR" "${find_args[@]}" -print)"

  if [ -z "$matches" ]; then
    pass "$description"
    return 0
  fi

  printf '%s\n' "$matches"
  fail "$description"
}

printf 'Running repository hygiene tests\n'

assert_no_matches 'repository root has no generated .log files' -maxdepth 1 -name '*.log'
assert_no_matches 'repository has no .DS_Store files' -name '.DS_Store'
assert_no_matches 'repository has no transient *.XXXXXX.sh shell artifacts' -name '*.XXXXXX.sh'
assert_no_matches 'tests directory has no setup-reuse-only transient shell artifacts' -path "$ROOT_DIR/tests/setup-reuse-only*.sh"
assert_no_matches 'logs tree contains only .log artifacts and .gitkeep placeholders' -path "$ROOT_DIR/logs/*" -type f ! -name '.gitkeep' ! -name '*.log'

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
