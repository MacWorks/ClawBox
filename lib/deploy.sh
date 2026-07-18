source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

# Normal setup owns only these OpenClaw paths. Existing config files are never
# uploaded or regenerated here; updates go through OpenClaw's config CLI.

openclaw_config_remote_get() {
  local key="$1"
  ssh_exec "zsh -lc $(printf '%q' "openclaw config get $(printf '%q' "$key")")"
}

openclaw_config_remote_set() {
  local key="$1" value="$2"
  case "$key" in
    models.providers.*.models)
      ssh_exec "zsh -lc $(printf '%q' "openclaw config set --merge $(printf '%q' "$key") $(printf '%q' "$value")")"
      ;;
    *)
      ssh_exec "zsh -lc $(printf '%q' "openclaw config set $(printf '%q' "$key") $(printf '%q' "$value")")"
      ;;
  esac
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
required_compat = required.get("compat", {})
if not isinstance(required_compat, dict):
    required_compat = {}
required_developer_role = required_compat.get("supportsDeveloperRole")
required_unsupported = required_compat.get("unsupportedToolSchemaKeywords", [])
if not isinstance(required_unsupported, list):
    required_unsupported = []

def managed_fields_match(model, require_local_identity):
    if not isinstance(model, dict):
        return False
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

    if require_local_identity and (
        model.get("id") != required_id or model.get("name") != required_name
    ):
        return False

    unsupported = compat.get("unsupportedToolSchemaKeywords", [])
    if not isinstance(unsupported, list):
        unsupported = []

    return (
        model.get("api") == required_api
        and context_matches
        and max_tokens_matches
        and compat.get("supportsDeveloperRole") == required_developer_role
        and all(keyword in unsupported for keyword in required_unsupported)
    )

local_entries = [
    model for model in current
    if isinstance(model, dict) and model.get("id") == required_id
]

if local_entries:
    for model in local_entries:
        if managed_fields_match(model, True):
            raise SystemExit(0)
    raise SystemExit(1)

# Older ClawBox/OpenClaw configs may contain only a filename-derived provider
# model entry while agents.defaults.model.primary already points at
# clawbox/local. Treat a compatible legacy entry as acceptable metadata instead
# of forcing a replacement during ordinary model switching. The explicit reset
# command remains the full-replacement path.
for model in current:
    if managed_fields_match(model, False):
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

openclaw_config_value_for_remote_set() {
  local key="$1" current="$2" desired="$3"

  case "$key" in
    models.providers.*.models)
      python3 - "$current" "$desired" <<'PY'
import json, sys

try:
    current = json.loads(sys.argv[1])
except Exception:
    current = []

try:
    desired = json.loads(sys.argv[2])
except Exception:
    print(sys.argv[2])
    raise SystemExit(0)

if not isinstance(current, list) or not isinstance(desired, list):
    print(json.dumps(desired, separators=(",", ":")))
    raise SystemExit(0)

current_by_id = {
    model.get("id"): model
    for model in current
    if isinstance(model, dict) and model.get("id") is not None
}

merged = []
for required in desired:
    if not isinstance(required, dict):
        merged.append(required)
        continue

    model_id = required.get("id")
    existing = current_by_id.get(model_id, {})
    if not isinstance(existing, dict):
        existing = {}

    output = dict(existing)
    output.update(required)

    compat = existing.get("compat", {})
    if not isinstance(compat, dict):
        compat = {}
    required_compat = required.get("compat", {})
    if not isinstance(required_compat, dict):
        required_compat = {}

    merged_compat = dict(compat)
    merged_compat.update(required_compat)

    existing_keywords = compat.get("unsupportedToolSchemaKeywords", [])
    required_keywords = required_compat.get("unsupportedToolSchemaKeywords", [])
    if not isinstance(existing_keywords, list):
        existing_keywords = []
    if not isinstance(required_keywords, list):
        required_keywords = []

    keywords = []
    for keyword in existing_keywords + required_keywords:
        if isinstance(keyword, str) and keyword not in keywords:
            keywords.append(keyword)
    if keywords:
        merged_compat["unsupportedToolSchemaKeywords"] = keywords

    output["compat"] = merged_compat
    merged.append(output)

print(json.dumps(merged, separators=(",", ":")))
PY
      ;;
    *)
      printf '%s\n' "$desired"
      ;;
  esac
}

openclaw_config_model_array() {
  python3 - "${OPENCLAW_DEFAULT_MODEL:-local}" "${LLAMA_CTX:-16384}" <<'PY'
import json, sys
try:
    context = max(16384, int(sys.argv[2]))
except ValueError:
    context = 16384
print(json.dumps([{"id": sys.argv[1], "name": sys.argv[1], "contextWindow": context,
                  "maxTokens": 2048,
                  "compat": {
                      "supportsDeveloperRole": False,
                      "unsupportedToolSchemaKeywords": ["pattern"],
                  },
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
  CONFIG_TARGETED_NO_CHANGE=false

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
    CONFIG_TARGETED_NO_CHANGE=true
    out 'OpenClaw config already matched; no OpenClaw changes were made.'
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
    desired="$(openclaw_config_value_for_remote_set "$key" "$current" "$desired")" || return 1
    if ! openclaw_config_remote_set "$key" "$desired"; then
      error "OpenClaw config update failed for $key."
      out 'OpenClaw config was not replaced.'
      out 'Run ./clawbox setup to retry targeted config sync, or ./clawbox openclaw reset for an explicit full reset.'
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
