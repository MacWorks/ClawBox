#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE_FILE="$ROOT_DIR/.env.example"

FAILURES=0
OUTPUT_FILE=""
ENV_BACKUP=""

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

cleanup() {
  if [ -n "$OUTPUT_FILE" ] && [ -f "$OUTPUT_FILE" ]; then
    rm -f "$OUTPUT_FILE"
  fi

  if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
    cp "$ENV_BACKUP" "$ENV_FILE"
    rm -f "$ENV_BACKUP"
  fi
}

trap cleanup EXIT

if [ ! -f "$ENV_EXAMPLE_FILE" ]; then
  fail "Missing required file: $ENV_EXAMPLE_FILE"
  printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
  exit 1
fi

OUTPUT_FILE="$(mktemp)"

if [ -f "$ENV_FILE" ]; then
  ENV_BACKUP="$(mktemp)"
  cp "$ENV_FILE" "$ENV_BACKUP"
fi

cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"

status=0
if "$ROOT_DIR/scripts/setup.sh" </dev/null >"$OUTPUT_FILE" 2>&1; then
  status=0
else
  status=$?
fi

if [ "$status" -ne 0 ]; then
  pass "setup.sh startup smoke exits non-zero in noninteractive mode"
else
  fail "setup.sh startup smoke should not succeed in noninteractive mode"
fi

if grep -Fq 'This setup script will guide you through' "$OUTPUT_FILE"; then
  pass "setup.sh startup smoke reaches entrypoint output"
else
  fail "setup.sh startup smoke should reach entrypoint output"
fi

if grep -Fq 'Interactive setup requires a TTY' "$OUTPUT_FILE"; then
  pass "setup.sh startup smoke reaches env bootstrap guard before prompting"
else
  fail "setup.sh startup smoke should reach env bootstrap guard before prompting"
fi

if grep -Fq 'local: can only be used in a function' "$OUTPUT_FILE"; then
  fail "setup.sh startup smoke should not hit top-level local runtime errors"
else
  pass "setup.sh startup smoke avoids top-level local runtime errors"
fi

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1
