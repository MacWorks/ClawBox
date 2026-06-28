source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

# Normal setup owns only these OpenClaw paths. Existing config files are never
# uploaded or regenerated here; updates go through OpenClaw's config CLI.

openclaw_config_remote_get() {
  local key="$1"
  ssh_exec "zsh -lc $(printf '%q' "openclaw config get $(printf '%q' "$key")")"
}

openclaw_config_remote_set() {
  local key="$1" value="$2"
  ssh_exec "zsh -lc $(printf '%q' "openclaw config set $(printf '%q' "$key") $(printf '%q' "$value")")"
}

openclaw_config_value_matches() {
  local current="$1" desired="$2"
  [ "$current" = "$desired" ] && return 0
  python3 - "$current" "$desired" <<'PY' >/dev/null 2>&1
import json, sys
try:
    raise SystemExit(0 if json.loads(sys.argv[1]) == json.loads(sys.argv[2]) else 1)
except Exception:
    raise SystemExit(1)
PY
}

openclaw_config_model_array_matches() {
  local current="$1" desired="$2"
  python3 - "$current" "$desired" <<'PY' >/dev/null 2>&1
import json, sys

try:
    current = json.loads(sys.argv[1])
    desired = json.loads(sys.argv[2])
except Exception:
    raise SystemExit(1)

if not isinstance(current, list) or not isinstance(desired, list) or not desired:
    raise SystemExit(1)

required = desired[0]
required_id = required.get("id")
required_name = required.get("name")
required_api = required.get("api")
required_context = required.get("contextWindow")
required_max_tokens = required.get("maxTokens")
required_developer_role = required.get("compat", {}).get("supportsDeveloperRole")

for model in current:
    if not isinstance(model, dict):
        continue
    compat = model.get("compat", {})
    if not isinstance(compat, dict):
        compat = {}
    try:
        context_matches = int(model.get("contextWindow")) == int(required_context)
    except Exception:
        context_matches = model.get("contextWindow") == required_context
    try:
        max_tokens_matches = int(model.get("maxTokens")) == int(required_max_tokens)
    except Exception:
        max_tokens_matches = model.get("maxTokens") == required_max_tokens

    if (
        model.get("id") == required_id
        and model.get("name") == required_name
        and model.get("api") == required_api
        and context_matches
        and max_tokens_matches
        and compat.get("supportsDeveloperRole") == required_developer_role
    ):
        raise SystemExit(0)

raise SystemExit(1)
PY
}

openclaw_config_value_matches_for_key() {
  local key="$1" current="$2" desired="$3"

  case "$key" in
    agents.defaults.memorySearch.remote.apiKey)
      if [ "$current" = '__OPENCLAW_REDACTED__' ]; then
        return 0
      fi
      ;;
    models.providers.*.models)
      openclaw_config_model_array_matches "$current" "$desired" && return 0
      ;;
  esac

  openclaw_config_value_matches "$current" "$desired"
}

openclaw_config_model_array() {
  python3 - "${OPENCLAW_DEFAULT_MODEL:-local}" "${LLAMA_CTX:-16384}" <<'PY'
import json, sys
try:
    context = max(16384, int(sys.argv[2]))
except ValueError:
    context = 16384
print(json.dumps([{"id": sys.argv[1], "name": sys.argv[1], "contextWindow": context,
                  "maxTokens": 2048, "compat": {"supportsDeveloperRole": False},
                  "api": "openai-completions"}], separators=(",", ":")))
PY
}

openclaw_config_desired_entries_for_scope() {
  local scope="${1:-all}"
  local provider="${OPENCLAW_PROVIDER_NAME:-clawbox}" models=''

  if [ "$scope" = all ] || [ "$scope" = primary ]; then
    models="$(openclaw_config_model_array)" || return 1
    printf '%s\t%s\n' 'agents.defaults.model.primary' "$provider/${OPENCLAW_DEFAULT_MODEL:-local}"
    printf '%s\t%s\n' "models.providers.$provider.baseUrl" "${LLAMA_BASE_URL:-}"
    printf '%s\t%s\n' "models.providers.$provider.api" 'openai-completions'
    printf '%s\t%s\n' "models.providers.$provider.models" "$models"
  fi

  if { [ "$scope" = all ] || [ "$scope" = memorySearch ]; } \
    && [ "${EMBEDDINGS_ENABLED:-false}" = true ] \
    && [ -n "${EMBEDDINGS_MODEL_PATH:-}" ]
  then
    printf '%s\t%s\n' 'agents.defaults.memorySearch.enabled' 'true'
    printf '%s\t%s\n' 'agents.defaults.memorySearch.provider' 'openai-compatible'
    printf '%s\t%s\n' 'agents.defaults.memorySearch.model' "$(basename "$EMBEDDINGS_MODEL_PATH")"
    printf '%s\t%s\n' 'agents.defaults.memorySearch.remote.baseUrl' "${EMBEDDINGS_LLAMA_BASE_URL:-}"
    printf '%s\t%s\n' 'agents.defaults.memorySearch.remote.apiKey' 'ollama-local'
  fi
}

openclaw_config_desired_entries() {
  openclaw_config_desired_entries_for_scope all
}

apply_targeted_openclaw_config_updates() {
  local scope="${1:-all}"
  local key='' desired='' current='' drift=''
  CONFIG_OVERWRITTEN=false
  CONFIG_TARGETED_UPDATED=false

  while IFS=$'\t' read -r key desired; do
    [ -n "$key" ] || continue
    current="$(openclaw_config_remote_get "$key" 2>/dev/null || true)"
    if ! openclaw_config_value_matches_for_key "$key" "$current" "$desired"; then
      drift="${drift}${key}\n"
    fi
  done <<EOF
$(openclaw_config_desired_entries_for_scope "$scope")
EOF

  if [ -z "$drift" ]; then
    out 'OpenClaw config already matches ClawBox-managed settings.'
    return 0
  fi

  out 'OpenClaw config differs only in ClawBox-managed settings:'
  printf '%b' "$drift" | while IFS= read -r key; do [ -z "$key" ] || outf '  - %s' "$key"; done
  prompt_yes_no 'Apply targeted OpenClaw config updates?' 'y'
  if ! is_yes "$REPLY"; then
    out 'OpenClaw config was not changed.'
    return 0
  fi

  while IFS=$'\t' read -r key desired; do
    [ -n "$key" ] || continue
    current="$(openclaw_config_remote_get "$key" 2>/dev/null || true)"
    openclaw_config_value_matches_for_key "$key" "$current" "$desired" && continue
    if ! openclaw_config_remote_set "$key" "$desired"; then
      error "OpenClaw config update failed for $key."
      outf 'Run manually: openclaw config set %s %q' "$key" "$desired"
      return 1
    fi
    current="$(openclaw_config_remote_get "$key" 2>/dev/null || true)"
    if ! openclaw_config_value_matches_for_key "$key" "$current" "$desired"; then
      error "OpenClaw config verification failed for $key."
      return 1
    fi
    CONFIG_TARGETED_UPDATED=true
  done <<EOF
$(openclaw_config_desired_entries_for_scope "$scope")
EOF

  if [ "$CONFIG_TARGETED_UPDATED" = true ]; then
    success 'Targeted ClawBox OpenClaw settings updated.'
    out 'OpenClaw may reload these settings automatically; no gateway was restarted.'
  fi
}

sync_openclaw_config() {
  CONFIG_OVERWRITTEN=false
  CONFIG_TARGETED_UPDATED=false
  ssh_run_quiet "mkdir -p $REMOTE_CONFIG_DIR"

  if ! ssh_exec "test -f $REMOTE_CONFIG_PATH"; then
    out 'Installing initial minimal OpenClaw config...'
    generate_openclaw_config || return $?
    scp -O -q "$CONFIG_PATH" "$VM_HOST:$REMOTE_CONFIG_PATH" </dev/null
    ssh_exec "test -f $REMOTE_CONFIG_PATH"
    return 0
  fi

  apply_targeted_openclaw_config_updates all
}

sync_openclaw_config_targeted_only() {
  local scope="${1:-all}"

  CONFIG_OVERWRITTEN=false
  CONFIG_TARGETED_UPDATED=false
  [ -n "${VM_HOST:-}" ] || { warn 'VM OpenClaw config sync skipped because VM_HOST is not configured.'; return 0; }
  if ! ssh_exec "test -f $REMOTE_CONFIG_PATH" >/dev/null 2>&1; then
    warn 'VM OpenClaw config does not exist; targeted model sync skipped.'
    out 'Run ./clawbox setup to bootstrap the initial OpenClaw config, or ./clawbox openclaw reset to replace it explicitly.'
    return 0
  fi

  apply_targeted_openclaw_config_updates "$scope"
}

offer_targeted_openclaw_config_restart() {
  [ "${CONFIG_TARGETED_UPDATED:-false}" = true ] || return 0
  prompt_yes_no 'Restart the VM OpenClaw gateway now to apply targeted config changes?' 'n'
  if ! is_yes "$REPLY"; then
    out 'OpenClaw was not restarted.'
    return 0
  fi

  if command -v openclaw_runtime_has_running_gateway_service >/dev/null 2>&1 \
    && openclaw_runtime_has_running_gateway_service
  then
    if command -v restart_clawbox_managed_openclaw_gateway >/dev/null 2>&1 \
      && restart_clawbox_managed_openclaw_gateway
    then
      success 'ClawBox-managed OpenClaw gateway restarted and verified.'
    else
      warn 'ClawBox-managed OpenClaw gateway restart was not verified.'
    fi
    return 0
  fi

  if command -v openclaw_runtime_has_running_native_gateway_service >/dev/null 2>&1 \
    && openclaw_runtime_has_running_native_gateway_service
  then
    warn 'Native OpenClaw LaunchAgent restart requested explicitly.'
    if ssh_exec_zsh 'uid=$(id -u); launchctl kickstart -k "gui/$uid/ai.openclaw.gateway"' \
      && openclaw_runtime_has_running_native_gateway_service
    then
      success 'Native OpenClaw gateway restarted and verified.'
    else
      warn 'Native OpenClaw gateway restart was not verified.'
    fi
    return 0
  fi

  warn 'OpenClaw gateway ownership is unknown; it was not restarted.'
  outf "Restart it manually on the VM: ssh %s 'zsh -lc \"openclaw gateway restart\"'" "$VM_HOST"
}
