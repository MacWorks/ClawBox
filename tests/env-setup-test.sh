#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE_FILE="$ROOT_DIR/.env.example"
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

require_command() {
  local name="$1"

  if command -v "$name" >/dev/null 2>&1; then
    pass "$name is available"
  else
    fail "$name is not available"
  fi
}

require_key() {
  local key="$1"

  if grep -Eq "^${key}=" "$ENV_FILE"; then
    pass "$key exists in .env"
  else
    fail "$key is missing from .env"
  fi
}

assert_no_placeholders() {
  if grep -Eq '<[^>]+>|your-provider-name|your-model-id|Your Model|Your VM Name in UTM|your-vm-username|/path/to/|<true-or-false>' "$ENV_FILE"; then
    fail ".env still contains placeholder values"
  else
    pass ".env does not contain placeholder values"
  fi
}

assert_format() {
  local description="$1"
  local value="$2"
  local pattern="$3"

  if printf '%s\n' "$value" | grep -Eq "$pattern"; then
    pass "$description has expected format"
  else
    fail "$description has invalid format"
  fi
}

printf 'Running env setup tests\n'

require_command bash

if [ -f "$ENV_EXAMPLE_FILE" ]; then
  pass ".env.example exists"
else
  fail ".env.example is missing"
fi

TEMP_DIR="$(mktemp -d)"
cp "$ENV_EXAMPLE_FILE" "$TEMP_DIR/.env"

if [ -f "$TEMP_DIR/.env" ]; then
  pass ".env can be created from .env.example"
else
  fail ".env could not be created from .env.example"
fi

if [ -f "$TEMP_DIR/.env" ] && bash -n "$TEMP_DIR/.env" >/dev/null 2>&1; then
  pass "generated fixture .env parses successfully"
else
  fail "generated fixture .env does not parse successfully"
fi

if [ -f "$ENV_FILE" ]; then
  pass ".env exists"
else
  fail ".env is missing"
fi

if [ -f "$ENV_FILE" ] && bash -n "$ENV_FILE" >/dev/null 2>&1; then
  pass ".env parses successfully"
else
  fail ".env does not parse successfully"
fi

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

while IFS='=' read -r key _; do
  case "$key" in
    ''|'#'*)
      continue
      ;;
  esac
  require_key "$key"
done < <(grep -E '^[A-Z0-9_]+=' "$ENV_EXAMPLE_FILE")

assert_no_placeholders
assert_format 'HOST_IP' "${HOST_IP:-}" '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
assert_format 'VM_IP' "${VM_IP:-}" '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
assert_format 'VM_HOST' "${VM_HOST:-}" '^[^@[:space:]]+@[0-9]{1,3}(\.[0-9]{1,3}){3}$'
assert_format 'VM_USER_PATH' "${VM_USER_PATH:-}" '^/[^[:space:]]+$'
assert_format 'VM_RUNTIME_PATH' "${VM_RUNTIME_PATH:-}" '^/[^[:space:]]+$'
assert_format 'MODEL_PATH' "${MODEL_PATH:-}" '^/[^[:space:]]+$'
assert_format 'LLAMA_BIN' "${LLAMA_BIN:-}" '^/[^[:space:]]+$'
assert_format 'LLAMA_PORT' "${LLAMA_PORT:-}" '^[0-9]+$'
assert_format 'LLAMA_CTX' "${LLAMA_CTX:-}" '^[0-9]+$'
assert_format 'LLAMA_BASE_URL' "${LLAMA_BASE_URL:-}" '^http://[^[:space:]]+/v1$'
assert_format 'FIREWALL_SHARED_SUBNET' "${FIREWALL_SHARED_SUBNET:-}" '^[0-9]{1,3}(\.[0-9]{1,3}){2}\.0/[0-9]{1,2}$'
assert_format 'OPENCLAW_AUTOSTART' "${OPENCLAW_AUTOSTART:-}" '^(true|false)$'

if [ "$FAILURES" -eq 0 ]; then
  printf 'PASS: test suite succeeded\n'
  exit 0
fi

printf 'FAIL: test suite failed with %s issues\n' "$FAILURES"
exit 1