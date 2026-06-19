#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENV_FILE="${CLAWBOX_ENV_FILE:-/usr/local/etc/clawbox.env}"
TEMPLATE_FILE="$BASE_DIR/host/firewall/pf.conf.fragment"

PF_MAIN_CONF="/etc/pf.conf"
PF_ANCHOR_NAME="com.clawbox/llama"
PF_ANCHOR_FILE="/usr/local/etc/clawbox-pf.conf"
PF_ANCHOR_CANDIDATE="/usr/local/etc/clawbox-pf.conf.candidate"
PF_MAIN_CANDIDATE="/usr/local/etc/pf.conf.clawbox.candidate"

PF_ANCHOR_DECLARATION="anchor \"$PF_ANCHOR_NAME\""
PF_ANCHOR_LOAD="load anchor \"$PF_ANCHOR_NAME\" from \"$PF_ANCHOR_FILE\""

DEFAULT_FIREWALL_MODE="relaxed"

source "$BASE_DIR/lib/llama.sh"

require_sudo() {
  if user_has_sudo; then
    blank_line
    printf '%s\n' 'Administrator privileges may be required' >&2
    blank_line
    sudo -v
    blank_line
  fi
}

fail() {
  echo "✗ $1" >&2
  exit 1
}

validate_port() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  if [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
    return 1
  fi
}

require_value() {
  local value_name="$1"
  local value="${!value_name:-}"

  if [ -z "$value" ]; then
    fail "Missing required env value: $value_name"
  fi
}

render_anchor_file() {
  local allowed_subnet="$1"

  llama_maybe_sudo system mkdir -p /usr/local/etc
  sed \
    -e "s/__LLAMA_PORT__/$LLAMA_PORT/g" \
    -e "s#__ALLOWED_SUBNET__#$allowed_subnet#g" \
    "$TEMPLATE_FILE" | llama_maybe_sudo system tee "$PF_ANCHOR_CANDIDATE" >/dev/null

  llama_maybe_sudo system pfctl -vnf "$PF_ANCHOR_CANDIDATE" >/dev/null
  llama_maybe_sudo system install -m 644 "$PF_ANCHOR_CANDIDATE" "$PF_ANCHOR_FILE"
  llama_maybe_sudo system rm -f "$PF_ANCHOR_CANDIDATE"
}

ensure_anchor_registration() {
  llama_maybe_sudo system cp "$PF_MAIN_CONF" "$PF_MAIN_CANDIDATE"

  if ! llama_maybe_sudo system grep -Fqx "$PF_ANCHOR_DECLARATION" "$PF_MAIN_CANDIDATE"; then
    printf "\n%s\n" "$PF_ANCHOR_DECLARATION" | llama_maybe_sudo system tee -a "$PF_MAIN_CANDIDATE" >/dev/null
  fi

  if ! llama_maybe_sudo system grep -Fqx "$PF_ANCHOR_LOAD" "$PF_MAIN_CANDIDATE"; then
    printf "%s\n" "$PF_ANCHOR_LOAD" | llama_maybe_sudo system tee -a "$PF_MAIN_CANDIDATE" >/dev/null
  fi

  llama_maybe_sudo system pfctl -vnf "$PF_MAIN_CANDIDATE" >/dev/null

  if ! llama_maybe_sudo system grep -Fqx "$PF_ANCHOR_DECLARATION" "$PF_MAIN_CONF"; then
    printf "\n%s\n" "$PF_ANCHOR_DECLARATION" | llama_maybe_sudo system tee -a "$PF_MAIN_CONF" >/dev/null
  fi

  if ! llama_maybe_sudo system grep -Fqx "$PF_ANCHOR_LOAD" "$PF_MAIN_CONF"; then
    printf "%s\n" "$PF_ANCHOR_LOAD" | llama_maybe_sudo system tee -a "$PF_MAIN_CONF" >/dev/null
  fi

  llama_maybe_sudo system rm -f "$PF_MAIN_CANDIDATE"
}

print_rule_explanation() {
  echo "→ Firewall rule summary"
  echo "  - localhost access to llama-server remains allowed"
  echo "  - mode '$FIREWALL_MODE' allows $ALLOWED_SUBNET to reach TCP port $LLAMA_PORT"
  echo "  - all other inbound TCP traffic to port $LLAMA_PORT is blocked"
  echo "  - SSH, Tailscale, and unrelated ports are unchanged because rules only target TCP port $LLAMA_PORT"
}

print_rollback_instructions() {
  echo "→ Rollback instructions"
  echo "  1. Flush only the ClawBox anchor rules: sudo pfctl -a $PF_ANCHOR_NAME -F rules"
  echo "  2. Reload the main ruleset: sudo pfctl -f $PF_MAIN_CONF"
  echo "  3. Optionally remove these two lines from $PF_MAIN_CONF if you want to detach the anchor:"
  echo "     $PF_ANCHOR_DECLARATION"
  echo "     $PF_ANCHOR_LOAD"
}

apply_rules() {
  llama_maybe_sudo system pfctl -vnf "$PF_MAIN_CONF" >/dev/null
  llama_maybe_sudo system pfctl -E >/dev/null 2>&1 || true
  llama_maybe_sudo system pfctl -a "$PF_ANCHOR_NAME" -f "$PF_ANCHOR_FILE" >/dev/null
  llama_maybe_sudo system pfctl -f "$PF_MAIN_CONF" >/dev/null
}

verify_anchor_rules() {
  local rendered_rules

  rendered_rules="$(llama_maybe_sudo system pfctl -a "$PF_ANCHOR_NAME" -sr)"

  echo "$rendered_rules" | grep -F "pass in quick on lo0 inet proto tcp from any to any port = $LLAMA_PORT" >/dev/null \
    || fail "localhost allow rule missing from pf anchor"

  echo "$rendered_rules" | grep -F "from $ALLOWED_SUBNET to any port = $LLAMA_PORT" >/dev/null \
    || fail "allowed subnet rule missing from pf anchor"

  if ! echo "$rendered_rules" | grep -F "block" | grep -F "port = $LLAMA_PORT" >/dev/null; then
    fail "block rule for llama-server port missing from pf anchor"
  fi
}

verify_local_access() {
  curl -fsS --max-time 5 "http://127.0.0.1:${LLAMA_PORT}/v1/models" >/dev/null \
    || fail "llama-server is not reachable on localhost after pf apply"

  echo "✓ llama-server remains reachable locally"
}

verify_external_block_simulation() {
  llama_maybe_sudo system pfctl -a "$PF_ANCHOR_NAME" -sr | grep -F "port = $LLAMA_PORT" | grep -F "block" >/dev/null \
    || fail "simulated external block check failed; no block rule found for port $LLAMA_PORT"

  echo "✓ simulated external block confirmed by loaded pf rules"
}

echo "> ClawBox Firewall Apply <"

require_sudo

[ -f "$ENV_FILE" ] || fail "Missing env file at $ENV_FILE"
[ -f "$TEMPLATE_FILE" ] || fail "Missing pf template at $TEMPLATE_FILE"
[ -f "$PF_MAIN_CONF" ] || fail "Missing pf config at $PF_MAIN_CONF"

set -a
. "$ENV_FILE"
set +a

FIREWALL_MODE="${FIREWALL_MODE:-$DEFAULT_FIREWALL_MODE}"
FIREWALL_RELAXED_SUBNET="${FIREWALL_RELAXED_SUBNET:-}"
FIREWALL_SHARED_SUBNET="${FIREWALL_SHARED_SUBNET:-${FIREWALL_VM_SUBNET:-}}"

validate_port "$LLAMA_PORT" || fail "Invalid LLAMA_PORT value: $LLAMA_PORT"

case "$FIREWALL_MODE" in
  relaxed)
    require_value FIREWALL_RELAXED_SUBNET
    ALLOWED_SUBNET="$FIREWALL_RELAXED_SUBNET"
    ;;
  strict)
    require_value FIREWALL_SHARED_SUBNET
    ALLOWED_SUBNET="$FIREWALL_SHARED_SUBNET"
    ;;
  *)
    fail "Unsupported FIREWALL_MODE '$FIREWALL_MODE' (expected relaxed or strict)"
    ;;
esac

print_rule_explanation
print_rollback_instructions

echo "→ Rendering pf anchor file"
render_anchor_file "$ALLOWED_SUBNET"

echo "→ Registering ClawBox anchor in /etc/pf.conf without overwriting it"
ensure_anchor_registration

echo "→ Validating pf configuration"
llama_maybe_sudo system pfctl -vnf "$PF_MAIN_CONF" >/dev/null

echo "→ Applying pf rules"
apply_rules

echo "→ Verifying loaded pf rules"
verify_anchor_rules

echo "→ Verifying llama-server local reachability"
verify_local_access

echo "→ Verifying external block behavior (simulated by ruleset inspection)"
verify_external_block_simulation

echo "✓ ClawBox firewall applied in $FIREWALL_MODE mode"