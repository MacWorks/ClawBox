clawbox_positive_integer() {
  case "${1:-}" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  [ "$1" -gt 0 ] 2>/dev/null
}

clawbox_bool_enabled() {
  case "${1:-}" in
    true|TRUE|yes|YES|1|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

llama_default_context_window() {
  printf '32768\n'
}

llama_context_safe_default() {
  local current_value="${1:-}"
  local native_context="${2:-}"
  local fallback_value="${3:-$(llama_default_context_window)}"
  local default_value="$fallback_value"

  if clawbox_positive_integer "$current_value"; then
    default_value="$current_value"
  fi

  if clawbox_positive_integer "$native_context" \
    && clawbox_positive_integer "$default_value" \
    && [ "$default_value" -gt "$native_context" ]
  then
    default_value="$native_context"
  fi

  REPLY="$default_value"
}

model_context_validate_native_value() {
  local context_value="$1"
  local native_context="${2:-}"
  local source_label="${3:-configuration}"
  local setting_label="${4:-context size}"

  if ! clawbox_positive_integer "$context_value"; then
    error "Invalid $setting_label in $source_label: $context_value"
    error 'Set the context size to a positive integer.'
    return 1
  fi

  if clawbox_positive_integer "$native_context" && [ "$context_value" -gt "$native_context" ]; then
    error "Invalid $setting_label in $source_label: $context_value exceeds model native context $native_context."
    error 'Choose a value less than or equal to the selected model native context.'
    return 1
  fi

  return 0
}

model_context_prompt_value() {
  local prompt_label="$1"
  local current_value="${2:-}"
  local native_context="${3:-}"
  local fallback_value="${4:-$(llama_default_context_window)}"
  local source_label="${5:-setup input}"
  local default_value=''

  llama_context_safe_default "$current_value" "$native_context" "$fallback_value"
  default_value="$REPLY"

  while true; do
    prompt_with_default "$prompt_label" "$default_value" || return $?
    if model_context_validate_native_value "$REPLY" "$native_context" "$source_label"; then
      return 0
    fi
  done
}

llama_context_validate_value() {
  local context_value="$1"
  local native_context="${2:-}"
  local max_tokens_value="${3:-${OPENCLAW_MAX_TOKENS:-8192}}"
  local source_label="${4:-configuration}"

  if command -v validate_openclaw_token_context_values >/dev/null 2>&1; then
    if ! validate_openclaw_token_context_values "$context_value" "$max_tokens_value" "$source_label"; then
      return 1
    fi
  else
    if ! clawbox_positive_integer "$context_value"; then
      error "Invalid LLAMA_CTX value in $source_label: $context_value"
      error 'Set LLAMA_CTX to a positive integer greater than OPENCLAW_MAX_TOKENS.'
      return 1
    fi
    if ! clawbox_positive_integer "$max_tokens_value"; then
      error "Invalid OPENCLAW_MAX_TOKENS value in $source_label: $max_tokens_value"
      error 'Set OPENCLAW_MAX_TOKENS to a positive integer less than LLAMA_CTX.'
      return 1
    fi
    if [ "$max_tokens_value" -ge "$context_value" ]; then
      error "Invalid OpenClaw token configuration in $source_label: OPENCLAW_MAX_TOKENS=$max_tokens_value must be less than LLAMA_CTX=$context_value."
      error 'Increase LLAMA_CTX or lower OPENCLAW_MAX_TOKENS, then rerun ./clawbox setup.'
      return 1
    fi
  fi

  model_context_validate_native_value "$context_value" "$native_context" "$source_label" 'LLAMA_CTX value'
}

llama_context_prompt_value() {
  local current_value="${1:-}"
  local native_context="${2:-}"
  local max_tokens_value="${3:-${OPENCLAW_MAX_TOKENS:-8192}}"
  local source_label="${4:-setup input}"
  local default_value=''

  llama_context_safe_default "$current_value" "$native_context" "$(llama_default_context_window)"
  default_value="$REPLY"

  while true; do
    prompt_with_default 'Context size for llama-server' "$default_value" || return $?
    if llama_context_validate_value "$REPLY" "$native_context" "$max_tokens_value" "$source_label"; then
      return 0
    fi
  done
}

llama_context_resolve_noninteractive() {
  local current_value="${1:-}"
  local native_context="${2:-}"
  local max_tokens_value="${3:-${OPENCLAW_MAX_TOKENS:-8192}}"
  local source_label="${4:-configuration}"

  llama_context_safe_default "$current_value" "$native_context" "$(llama_default_context_window)"
  if ! llama_context_validate_value "$REPLY" "$native_context" "$max_tokens_value" "$source_label"; then
    return 1
  fi
}

openclaw_default_provider_timeout_seconds() {
  printf '1800\n'
}

openclaw_default_stuck_session_warn_ms() {
  printf '600000\n'
}

openclaw_default_stuck_session_abort_ms() {
  local warn_ms="${1:-$(openclaw_default_stuck_session_warn_ms)}"
  local derived

  if ! clawbox_positive_integer "$warn_ms"; then
    warn_ms="$(openclaw_default_stuck_session_warn_ms)"
  fi

  derived=$((warn_ms * 3))
  if [ "$derived" -lt 300000 ]; then
    derived=300000
  fi

  printf '%s\n' "$derived"
}

openclaw_resolve_runtime_tuning_values() {
  local provider_timeout="${OPENCLAW_PROVIDER_TIMEOUT_SECONDS:-$(openclaw_default_provider_timeout_seconds)}"
  local stuck_warn="${OPENCLAW_STUCK_SESSION_WARN_MS:-$(openclaw_default_stuck_session_warn_ms)}"
  local stuck_abort="${OPENCLAW_STUCK_SESSION_ABORT_MS:-}"

  if ! clawbox_positive_integer "$provider_timeout"; then
    printf 'Invalid OPENCLAW_PROVIDER_TIMEOUT_SECONDS value: %s\n' "$provider_timeout" >&2
    return 1
  fi

  if ! clawbox_positive_integer "$stuck_warn"; then
    printf 'Invalid OPENCLAW_STUCK_SESSION_WARN_MS value: %s\n' "$stuck_warn" >&2
    return 1
  fi

  if [ -z "$stuck_abort" ]; then
    stuck_abort="$(openclaw_default_stuck_session_abort_ms "$stuck_warn")"
  fi

  if ! clawbox_positive_integer "$stuck_abort"; then
    printf 'Invalid OPENCLAW_STUCK_SESSION_ABORT_MS value: %s\n' "$stuck_abort" >&2
    return 1
  fi

  if [ "$stuck_abort" -lt "$stuck_warn" ]; then
    printf 'Invalid OpenClaw diagnostics tuning: OPENCLAW_STUCK_SESSION_ABORT_MS=%s must be greater than or equal to OPENCLAW_STUCK_SESSION_WARN_MS=%s\n' "$stuck_abort" "$stuck_warn" >&2
    return 1
  fi

  OPENCLAW_PROVIDER_TIMEOUT_SECONDS_VALUE="$provider_timeout"
  OPENCLAW_STUCK_SESSION_WARN_MS_VALUE="$stuck_warn"
  OPENCLAW_STUCK_SESSION_ABORT_MS_VALUE="$stuck_abort"
}

llama_default_parallel() {
  printf '%s\n' "${LLAMA_PARALLEL:-1}"
}

llama_managed_runtime_arg_conflicts() {
  local extra_args="${1:-${LLAMA_EXTRA_ARGS:-}}"
  local conflicts=''
  local word=''

  [ -n "$extra_args" ] || return 1

  for word in $extra_args; do
    case "$word" in
      --ctx-size|--ctx-size=*|-c|-c[0-9]*|--parallel|--parallel=*|-np|-np[0-9]*|--n-gpu-layers|--n-gpu-layers=*|-ngl|-ngl[0-9]*|--flash-attn|--flash-attn=*|-fa|--jinja|--mlock|--mmproj|--mmproj=*)
        conflicts="${conflicts}${conflicts:+ }$word"
        ;;
    esac
  done

  [ -n "$conflicts" ] || return 1
  REPLY="$conflicts"
  return 0
}

llama_migrate_managed_runtime_extra_args() {
  local extra_args="${1:-${LLAMA_EXTRA_ARGS:-}}"
  local remaining_args=()
  local word=''
  local value=''

  LLAMA_MIGRATION_CTX="${LLAMA_CTX:-}"
  LLAMA_MIGRATION_PARALLEL="${LLAMA_PARALLEL:-1}"
  LLAMA_MIGRATION_GPU_LAYERS="${LLAMA_GPU_LAYERS:-}"
  LLAMA_MIGRATION_FLASH_ATTENTION="${LLAMA_FLASH_ATTENTION:-false}"
  LLAMA_MIGRATION_JINJA="${LLAMA_JINJA:-false}"
  LLAMA_MIGRATION_MLOCK="${LLAMA_MLOCK:-false}"
  LLAMA_MIGRATION_MMPROJ_PATH="${MMPROJ_PATH:-}"
  LLAMA_MIGRATION_EXTRA_ARGS="$extra_args"
  LLAMA_MIGRATION_CHANGED=false

  [ -n "$extra_args" ] || return 1

  set -f
  # LLAMA_EXTRA_ARGS is an existing shell-style passthrough. The migration is
  # intentionally conservative: it handles ordinary whitespace-separated flags
  # without eval/execution and leaves unrecognized words untouched.
  set -- $extra_args
  set +f

  while [ "$#" -gt 0 ]; do
    word="$1"
    shift || true

    case "$word" in
      --ctx-size=*)
        LLAMA_MIGRATION_CTX="${word#*=}"
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --ctx-size|-c)
        value="${1:-}"
        if [ -n "$value" ]; then
          shift || true
          LLAMA_MIGRATION_CTX="$value"
          LLAMA_MIGRATION_CHANGED=true
        else
          remaining_args+=("$word")
        fi
        ;;
      -c[0-9]*)
        LLAMA_MIGRATION_CTX="${word#-c}"
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --parallel=*)
        LLAMA_MIGRATION_PARALLEL="${word#*=}"
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --parallel|-np)
        value="${1:-}"
        if [ -n "$value" ]; then
          shift || true
          LLAMA_MIGRATION_PARALLEL="$value"
          LLAMA_MIGRATION_CHANGED=true
        else
          remaining_args+=("$word")
        fi
        ;;
      -np[0-9]*)
        LLAMA_MIGRATION_PARALLEL="${word#-np}"
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --n-gpu-layers=*)
        LLAMA_MIGRATION_GPU_LAYERS="${word#*=}"
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --n-gpu-layers|-ngl)
        value="${1:-}"
        if [ -n "$value" ]; then
          shift || true
          LLAMA_MIGRATION_GPU_LAYERS="$value"
          LLAMA_MIGRATION_CHANGED=true
        else
          remaining_args+=("$word")
        fi
        ;;
      -ngl[0-9-]*)
        LLAMA_MIGRATION_GPU_LAYERS="${word#-ngl}"
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --flash-attn=on|--flash-attn=true|--flash-attn=1|--flash-attn=yes)
        LLAMA_MIGRATION_FLASH_ATTENTION=true
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --flash-attn=off|--flash-attn=false|--flash-attn=0|--flash-attn=no)
        LLAMA_MIGRATION_FLASH_ATTENTION=false
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --flash-attn)
        LLAMA_MIGRATION_FLASH_ATTENTION=true
        LLAMA_MIGRATION_CHANGED=true
        ;;
      -fa)
        value="${1:-}"
        case "$value" in
          on|ON|true|TRUE|1|yes|YES)
            shift || true
            LLAMA_MIGRATION_FLASH_ATTENTION=true
            LLAMA_MIGRATION_CHANGED=true
            ;;
          off|OFF|false|FALSE|0|no|NO)
            shift || true
            LLAMA_MIGRATION_FLASH_ATTENTION=false
            LLAMA_MIGRATION_CHANGED=true
            ;;
          *)
            LLAMA_MIGRATION_FLASH_ATTENTION=true
            LLAMA_MIGRATION_CHANGED=true
            ;;
        esac
        ;;
      -faon|-fatrue|-fa1|-fayes)
        LLAMA_MIGRATION_FLASH_ATTENTION=true
        LLAMA_MIGRATION_CHANGED=true
        ;;
      -faoff|-fafalse|-fa0|-fano)
        LLAMA_MIGRATION_FLASH_ATTENTION=false
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --mlock)
        LLAMA_MIGRATION_MLOCK=true
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --jinja)
        LLAMA_MIGRATION_JINJA=true
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --mmproj=*)
        LLAMA_MIGRATION_MMPROJ_PATH="${word#*=}"
        LLAMA_MIGRATION_CHANGED=true
        ;;
      --mmproj)
        value="${1:-}"
        if [ -n "$value" ]; then
          shift || true
          LLAMA_MIGRATION_MMPROJ_PATH="$value"
          LLAMA_MIGRATION_CHANGED=true
        else
          remaining_args+=("$word")
        fi
        ;;
      *)
        remaining_args+=("$word")
        ;;
    esac
  done

  LLAMA_MIGRATION_EXTRA_ARGS="${remaining_args[*]-}"
  [ "$LLAMA_MIGRATION_CHANGED" = true ]
}

llama_validate_mmproj_path() {
  local mmproj_path="${1:-${MMPROJ_PATH:-}}"

  [ -n "$mmproj_path" ] || return 0

  if [ ! -f "$mmproj_path" ]; then
    llama_fail "multimodal projector not found: $mmproj_path"
    return 1
  fi

  if [ ! -r "$mmproj_path" ]; then
    llama_fail "multimodal projector is not readable: $mmproj_path"
    return 1
  fi

  case "$mmproj_path" in
    *.gguf)
      return 0
      ;;
    *)
      llama_fail "multimodal projector path must be a .gguf file: $mmproj_path"
      return 1
      ;;
  esac
}

llama_validate_managed_runtime_settings() {
  local context_value="${LLAMA_CTX:-32768}"
  local parallel_value="${LLAMA_PARALLEL:-1}"
  local gpu_layers="${LLAMA_GPU_LAYERS:-}"

  if ! clawbox_positive_integer "$context_value"; then
    llama_fail "Invalid LLAMA_CTX value: $context_value"
    return 1
  fi

  if ! clawbox_positive_integer "$parallel_value"; then
    llama_fail "Invalid LLAMA_PARALLEL value: $parallel_value"
    return 1
  fi

  if [ -n "$gpu_layers" ]; then
    case "$gpu_layers" in
      *[!0-9-]*|-)
        llama_fail "Invalid LLAMA_GPU_LAYERS value: $gpu_layers"
        return 1
        ;;
    esac
  fi

  llama_validate_mmproj_path "${MMPROJ_PATH:-}" || return 1

  if llama_managed_runtime_arg_conflicts "${LLAMA_EXTRA_ARGS:-}"; then
    llama_fail "LLAMA_EXTRA_ARGS conflicts with ClawBox-managed llama-server settings: $REPLY"
    out 'Move these flags to first-class .env settings or remove them from LLAMA_EXTRA_ARGS.'
    return 1
  fi
}

llama_append_managed_runtime_args() {
  local args_name="$1"
  local parallel_value="${LLAMA_PARALLEL:-1}"

  eval "$args_name+=(--ctx-size \"\${LLAMA_CTX:-32768}\")"
  eval "$args_name+=(--parallel \"\$parallel_value\")"

  if [ -n "${LLAMA_GPU_LAYERS:-}" ]; then
    eval "$args_name+=(--n-gpu-layers \"\$LLAMA_GPU_LAYERS\")"
  fi

  if clawbox_bool_enabled "${LLAMA_FLASH_ATTENTION:-false}"; then
    eval "$args_name+=(--flash-attn on)"
  else
    eval "$args_name+=(--flash-attn off)"
  fi

  if clawbox_bool_enabled "${LLAMA_JINJA:-false}"; then
    eval "$args_name+=(--jinja)"
  fi

  if [ -n "${MMPROJ_PATH:-}" ]; then
    eval "$args_name+=(--mmproj \"\$MMPROJ_PATH\")"
  fi

  if clawbox_bool_enabled "${LLAMA_MLOCK:-false}"; then
    eval "$args_name+=(--mlock)"
  fi
}

gguf_native_context_from_file() {
  local model_path="$1"

  [ -f "$model_path" ] || return 1

  python3 - "$model_path" <<'PY'
import struct
import sys

path = sys.argv[1]

TYPE_UINT8 = 0
TYPE_INT8 = 1
TYPE_UINT16 = 2
TYPE_INT16 = 3
TYPE_UINT32 = 4
TYPE_INT32 = 5
TYPE_FLOAT32 = 6
TYPE_BOOL = 7
TYPE_STRING = 8
TYPE_ARRAY = 9
TYPE_UINT64 = 10
TYPE_INT64 = 11
TYPE_FLOAT64 = 12

def read_exact(fh, n):
    data = fh.read(n)
    if len(data) != n:
        raise EOFError
    return data

def read_u64(fh):
    return struct.unpack("<Q", read_exact(fh, 8))[0]

def read_string(fh):
    size = read_u64(fh)
    if size > 1024 * 1024:
        raise ValueError("string too large")
    return read_exact(fh, size).decode("utf-8", "replace")

def skip_scalar(fh, value_type):
    sizes = {
        TYPE_UINT8: 1,
        TYPE_INT8: 1,
        TYPE_UINT16: 2,
        TYPE_INT16: 2,
        TYPE_UINT32: 4,
        TYPE_INT32: 4,
        TYPE_FLOAT32: 4,
        TYPE_BOOL: 1,
        TYPE_UINT64: 8,
        TYPE_INT64: 8,
        TYPE_FLOAT64: 8,
    }
    if value_type == TYPE_STRING:
        read_string(fh)
        return
    size = sizes.get(value_type)
    if size is None:
        raise ValueError("unknown type")
    read_exact(fh, size)

def read_numeric(fh, value_type):
    formats = {
        TYPE_UINT8: "<B",
        TYPE_INT8: "<b",
        TYPE_UINT16: "<H",
        TYPE_INT16: "<h",
        TYPE_UINT32: "<I",
        TYPE_INT32: "<i",
        TYPE_UINT64: "<Q",
        TYPE_INT64: "<q",
    }
    fmt = formats.get(value_type)
    if fmt is None:
        skip_value(fh, value_type)
        return None
    return int(struct.unpack(fmt, read_exact(fh, struct.calcsize(fmt)))[0])

def skip_value(fh, value_type):
    if value_type == TYPE_ARRAY:
        item_type = struct.unpack("<I", read_exact(fh, 4))[0]
        length = read_u64(fh)
        if length > 10000000:
            raise ValueError("array too large")
        for _ in range(length):
            skip_scalar(fh, item_type)
        return
    skip_scalar(fh, value_type)

try:
    with open(path, "rb") as fh:
        if read_exact(fh, 4) != b"GGUF":
            raise SystemExit(1)
        version = struct.unpack("<I", read_exact(fh, 4))[0]
        if version < 2:
            raise SystemExit(1)
        _tensor_count = read_u64(fh)
        kv_count = read_u64(fh)
        for _ in range(kv_count):
            key = read_string(fh)
            value_type = struct.unpack("<I", read_exact(fh, 4))[0]
            if key.endswith(".context_length") or key in ("context_length", "general.context_length"):
                value = read_numeric(fh, value_type)
                if value and value > 0:
                    print(value)
                    raise SystemExit(0)
            else:
                skip_value(fh, value_type)
except Exception:
    raise SystemExit(1)

raise SystemExit(1)
PY
}

openclaw_context_reserve_for_context() {
  local context_value="$1"
  python3 - "$context_value" <<'PY'
import sys
ctx = int(sys.argv[1])
reserve = min(8192, max(2048, ctx // 4))
if reserve >= ctx:
    reserve = max(1, ctx // 2)
print(reserve)
PY
}

openclaw_validate_token_budget_values() {
  local context_value="$1"
  local max_tokens="$2"
  local reserve_tokens="$3"
  local reserve_floor="$4"

  clawbox_positive_integer "$context_value" || return 1
  clawbox_positive_integer "$max_tokens" || return 1
  clawbox_positive_integer "$reserve_tokens" || return 1
  clawbox_positive_integer "$reserve_floor" || return 1

  [ "$max_tokens" -lt "$context_value" ] || return 1
  [ "$reserve_tokens" -lt "$context_value" ] || return 1
  [ "$reserve_floor" -lt "$context_value" ] || return 1
  [ $((context_value - reserve_tokens)) -gt 0 ] || return 1
  [ $((context_value - reserve_floor)) -gt 0 ] || return 1
}

openclaw_managed_token_budget_entries() {
  local context_value="$1"
  local max_tokens="${2:-${OPENCLAW_MAX_TOKENS:-8192}}"
  local reserve=''

  reserve="$(openclaw_context_reserve_for_context "$context_value")" || return 1
  if ! openclaw_validate_token_budget_values "$context_value" "$max_tokens" "$reserve" "$reserve"; then
    return 1
  fi

  printf 'agents.defaults.compaction.reserveTokens\t%s\n' "$reserve"
  printf 'agents.defaults.compaction.reserveTokensFloor\t%s\n' "$reserve"
}

llama_runtime_json_value() {
  local json="$1"
  local path="$2"

  python3 - "$json" "$path" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
cur = data
for part in sys.argv[2].split("."):
    if part == "":
        continue
    if isinstance(cur, list):
        cur = cur[int(part)]
    else:
        cur = cur[part]
print(cur)
PY
}

llama_runtime_context_from_props_json() {
  local json="$1"

  python3 - "$json" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
for path in (
    ("default_generation_settings", "n_ctx"),
    ("n_ctx",),
    ("context_size",),
    ("contextWindow",),
):
    cur = data
    try:
        for part in path:
            cur = cur[part]
        if isinstance(cur, bool):
            continue
        if isinstance(cur, (int, float)):
            print(int(cur))
            raise SystemExit(0)
    except Exception:
        continue
raise SystemExit(1)
PY
}

llama_runtime_total_slots_from_props_json() {
  local json="$1"

  python3 - "$json" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
for key in ("total_slots", "slots", "slot_count"):
    value = data.get(key) if isinstance(data, dict) else None
    if isinstance(value, bool):
        continue
    if isinstance(value, (int, float)):
        print(int(value))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

llama_runtime_slot_context_from_slots_json() {
  local json="$1"

  python3 - "$json" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
items = data
if isinstance(data, dict):
    items = data.get("slots", [])
if not isinstance(items, list):
    raise SystemExit(1)
contexts = []
for item in items:
    if not isinstance(item, dict):
        raise SystemExit(1)
    found = None
    for key in ("n_ctx", "ctx_size", "context_size"):
        value = item.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)):
            found = int(value)
            break
    if found is None:
        raise SystemExit(1)
    contexts.append(found)
if not contexts:
    raise SystemExit(1)
if any(value != contexts[0] for value in contexts):
    raise SystemExit(1)
print(contexts[0])
PY
}

llama_runtime_slot_count_from_slots_json() {
  local json="$1"

  python3 - "$json" <<'PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
items = data
if isinstance(data, dict):
    items = data.get("slots", [])
if not isinstance(items, list):
    raise SystemExit(1)
print(len(items))
PY
}

openclaw_model_numeric_field_from_models_json() {
  local models="$1"
  local default_model="${2:-local}"
  local field="$3"

  python3 - "$models" "$default_model" "$field" <<'PY'
import json, sys
try:
    models = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)
default_model = sys.argv[2] or "local"
field = sys.argv[3]
for model in models if isinstance(models, list) else []:
    if isinstance(model, dict) and model.get("id") == default_model:
        value = model.get(field)
        if isinstance(value, bool) or value is None:
            raise SystemExit(1)
        print(int(value))
        raise SystemExit(0)
raise SystemExit(1)
PY
}

openclaw_prompt_budget_before_reserve() {
  local context_window="$1"
  local reserve_tokens="$2"

  clawbox_positive_integer "$context_window" || return 1
  clawbox_positive_integer "$reserve_tokens" || return 1
  [ "$context_window" -gt "$reserve_tokens" ] || return 1
  printf '%s\n' $((context_window - reserve_tokens))
}
