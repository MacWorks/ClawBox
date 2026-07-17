#!/usr/bin/env bash

# Host-side qualification history, comparison, reports, badges, and metadata.
# Callers must define BASE_DIR and source lib/output.sh first.

QUALIFY_HISTORY_SCHEMA_VERSION="1"

qualify_history_data_dir() {
  printf '%s\n' "${CLAWBOX_QUALIFY_DATA_DIR:-$BASE_DIR/data/qualification}"
}

qualify_history_runs_dir() {
  printf '%s\n' "$(qualify_history_data_dir)/runs"
}

qualify_history_models_file() {
  printf '%s\n' "$(qualify_history_data_dir)/models.json"
}

qualify_history_lock_dir() {
  printf '%s\n' "$(qualify_history_data_dir)/.lock"
}

qualify_history_require_python() {
  command -v python3 >/dev/null 2>&1 || {
    error 'python3 is required for qualification history operations.'
    return 2
  }
}

qualify_history_init() {
  local data_dir runs_dir
  data_dir="$(qualify_history_data_dir)"
  runs_dir="$(qualify_history_runs_dir)"
  mkdir -p "$runs_dir" || return 1
  if [ ! -f "$(qualify_history_models_file)" ]; then
    qualify_history_python init-models "$(qualify_history_models_file)" || return 1
  fi
}

qualify_history_lock() {
  local lock_dir waited=0
  lock_dir="$(qualify_history_lock_dir)"
  mkdir -p "$(dirname "$lock_dir")" || return 1
  while ! mkdir "$lock_dir" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -le 50 ] || {
      error "Unable to acquire qualification history lock: $lock_dir"
      return 1
    }
    sleep 0.1
  done
  QUALIFY_HISTORY_LOCK_HELD="$lock_dir"
}

qualify_history_unlock() {
  if [ -n "${QUALIFY_HISTORY_LOCK_HELD:-}" ]; then
    rmdir "$QUALIFY_HISTORY_LOCK_HELD" 2>/dev/null || true
    QUALIFY_HISTORY_LOCK_HELD=''
  fi
}

qualify_history_index_aggregate() {
  local aggregate_file="$1" artifact_dir="${2:-}" warning_file="${3:-}"
  local data_dir runs_dir models_file status=0 output=''

  qualify_history_require_python || return 2
  qualify_history_init || return 1
  data_dir="$(qualify_history_data_dir)"
  runs_dir="$(qualify_history_runs_dir)"
  models_file="$(qualify_history_models_file)"

  qualify_history_lock || return 1
  set +e
  output="$(qualify_history_python index "$aggregate_file" "$runs_dir" "$models_file" "$artifact_dir" 2>&1)"
  status=$?
  set -e
  qualify_history_unlock

  if [ "$status" -ne 0 ]; then
    [ -z "$warning_file" ] || printf '%s\n' "$output" >"$warning_file"
    return "$status"
  fi
  return 0
}

qualify_history_usage() {
  cat <<'EOF'
Usage:
  ./clawbox qualify history [--json] [--model <name-or-path>] [--profile fast|full] [--limit <n>] [--latest] [--refresh]
  ./clawbox qualify compare [--models <model-a>,<model-b>] [--run <run-id>] [--run <run-id>] [--profile fast|full] [--json]
  ./clawbox qualify report --latest [--format markdown] [--output <path>] [--force]
  ./clawbox qualify report --run <run-id> [--format markdown] [--output <path>] [--force]
  ./clawbox qualify badge --latest [--model <model>] [--run <run-id>] [--format text|markdown|json]
EOF
}

qualify_history_dispatch() {
  local subcommand="$1"
  shift || true
  case "$subcommand" in
    history) qualify_history_command "$@" ;;
    compare) qualify_compare_command "$@" ;;
    report) qualify_report_command "$@" ;;
    badge) qualify_badge_command "$@" ;;
    *) return 2 ;;
  esac
}

qualify_history_command() {
  local json=false model='' profile='' limit='' latest=false refresh=false arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      --model) [ "$#" -ge 2 ] || { error 'Missing value for --model.'; return 1; }; model="$2"; shift 2 ;;
      --profile) [ "$#" -ge 2 ] || { error 'Missing value for --profile.'; return 1; }; profile="$2"; shift 2 ;;
      --limit) [ "$#" -ge 2 ] || { error 'Missing value for --limit.'; return 1; }; limit="$2"; shift 2 ;;
      --latest) latest=true; shift ;;
      --refresh) refresh=true; shift ;;
      -h|--help) qualify_history_usage; return 0 ;;
      *) error "Unknown history option: $arg"; return 1 ;;
    esac
  done
  qualify_history_validate_profile "$profile" || return $?
  qualify_history_validate_limit "$limit" || return $?
  if [ "$refresh" = true ]; then
    qualify_history_refresh "$json" || return $?
  fi
  qualify_history_require_python || return 2
  qualify_history_python history "$(qualify_history_runs_dir)" "$json" "$model" "$profile" "$limit" "$latest"
}

qualify_compare_command() {
  local json=false profile='full' models='' runs=() arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --json) json=true; shift ;;
      --profile) [ "$#" -ge 2 ] || { error 'Missing value for --profile.'; return 1; }; profile="$2"; shift 2 ;;
      --models) [ "$#" -ge 2 ] || { error 'Missing value for --models.'; return 1; }; models="$2"; shift 2 ;;
      --run) [ "$#" -ge 2 ] || { error 'Missing value for --run.'; return 1; }; runs+=("$2"); shift 2 ;;
      -h|--help) qualify_history_usage; return 0 ;;
      *) error "Unknown compare option: $arg"; return 1 ;;
    esac
  done
  qualify_history_validate_profile "$profile" || return $?
  if [ -n "$models" ] && [ "${#runs[@]}" -gt 0 ]; then
    error 'Use either --models or --run options, not both.'
    return 1
  fi
  qualify_history_require_python || return 2
  if [ "${#runs[@]}" -gt 0 ]; then
    qualify_history_python compare "$(qualify_history_runs_dir)" "$json" "$profile" "$models" "${runs[@]}"
  else
    qualify_history_python compare "$(qualify_history_runs_dir)" "$json" "$profile" "$models"
  fi
}

qualify_report_command() {
  local run_id='' latest=false format='markdown' output='' force=false arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --latest) latest=true; shift ;;
      --run) [ "$#" -ge 2 ] || { error 'Missing value for --run.'; return 1; }; run_id="$2"; shift 2 ;;
      --format) [ "$#" -ge 2 ] || { error 'Missing value for --format.'; return 1; }; format="$2"; shift 2 ;;
      --output) [ "$#" -ge 2 ] || { error 'Missing value for --output.'; return 1; }; output="$2"; shift 2 ;;
      --force) force=true; shift ;;
      -h|--help) qualify_history_usage; return 0 ;;
      *) error "Unknown report option: $arg"; return 1 ;;
    esac
  done
  [ "$format" = markdown ] || { error "Unsupported report format: $format"; return 1; }
  if [ "$latest" = true ] && [ -n "$run_id" ]; then
    error 'Use either --latest or --run, not both.'
    return 1
  fi
  if [ "$latest" != true ] && [ -z "$run_id" ]; then
    error 'Report requires --latest or --run <run-id>.'
    return 1
  fi
  qualify_history_require_python || return 2
  qualify_history_python report "$(qualify_history_runs_dir)" "$run_id" "$latest" "$output" "$force"
}

qualify_badge_command() {
  local run_id='' model='' latest=false format='text' arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --latest) latest=true; shift ;;
      --model) [ "$#" -ge 2 ] || { error 'Missing value for --model.'; return 1; }; model="$2"; shift 2 ;;
      --run) [ "$#" -ge 2 ] || { error 'Missing value for --run.'; return 1; }; run_id="$2"; shift 2 ;;
      --format) [ "$#" -ge 2 ] || { error 'Missing value for --format.'; return 1; }; format="$2"; shift 2 ;;
      -h|--help) qualify_history_usage; return 0 ;;
      *) error "Unknown badge option: $arg"; return 1 ;;
    esac
  done
  case "$format" in text|markdown|json) ;; *) error "Unsupported badge format: $format"; return 1 ;; esac
  qualify_history_require_python || return 2
  qualify_history_python badge "$(qualify_history_runs_dir)" "$run_id" "$model" "$latest" "$format"
}

qualify_history_validate_profile() {
  local profile="$1"
  case "$profile" in ''|fast|full) return 0 ;; *) error "Unknown qualification profile: $profile"; return 1 ;; esac
}

qualify_history_validate_limit() {
  local limit="$1"
  [ -z "$limit" ] && return 0
  case "$limit" in *[!0-9]*|'') error "Invalid limit: $limit"; return 1 ;; esac
  [ "$limit" -gt 0 ] 2>/dev/null || { error "Invalid limit: $limit"; return 1; }
}

qualify_history_refresh() {
  local json="$1" tmp_dir output status
  if [ -z "${VM_HOST:-}" ] || [ -z "${VM_RUNTIME_PATH:-}" ]; then
    if [ -f "${ENV_FILE:-}" ]; then
      # shellcheck source=/dev/null
      source "$ENV_FILE"
    fi
  fi
  [ -n "${VM_HOST:-}" ] || { error 'VM_HOST is not configured; cannot refresh from VM artifacts.'; return 2; }
  tmp_dir="$(mktemp -d)" || return 2
  set +e
  ssh "$VM_HOST" "zsh -lc 'base=\"\$HOME/.openclaw/workspace/.clawbox/qualification/runs\"; [ -d \"\$base\" ] || exit 0; for f in \"\$base\"/**/results/aggregate.json(N); do printf \"CLAWBOX_AGGREGATE_BEGIN %s\\n\" \"\$f\"; cat \"\$f\"; printf \"\\nCLAWBOX_AGGREGATE_END\\n\"; done'" >"$tmp_dir/aggregates.stream" 2>"$tmp_dir/refresh.stderr"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    cat "$tmp_dir/refresh.stderr" >&2 2>/dev/null || true
    rm -rf "$tmp_dir"
    return 2
  fi
  qualify_history_require_python || { rm -rf "$tmp_dir"; return 2; }
  qualify_history_init || { rm -rf "$tmp_dir"; return 1; }
  qualify_history_lock || { rm -rf "$tmp_dir"; return 1; }
  set +e
  output="$(qualify_history_python refresh "$tmp_dir/aggregates.stream" "$(qualify_history_runs_dir)" "$(qualify_history_models_file)" "$json" 2>&1)"
  status=$?
  set -e
  qualify_history_unlock
  rm -rf "$tmp_dir"
  printf '%s\n' "$output"
  return "$status"
}

qualify_history_python() {
  local action="$1"
  shift
  python3 - "$action" "$@" <<'PY'
import json, os, sys, tempfile, shutil, datetime, urllib.parse

action = sys.argv[1]
args = sys.argv[2:]
SCHEMA = "1"

def die(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)

def load_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)

def atomic_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def basename(value):
    value = value or ""
    return os.path.basename(value) if "/" in value else value

def display_model(record):
    model = record.get("model") or {}
    meta = model.get("metadata") or {}
    return meta.get("displayName") or basename(model.get("running") or model.get("configured") or model.get("path") or "unknown")

def model_key(record):
    model = record.get("model") or {}
    return model.get("path") or model.get("configured") or model.get("running") or "unknown"

def duration(seconds):
    try:
        seconds = int(float(seconds))
    except Exception:
        return "unknown"
    if seconds < 60:
        return f"{seconds}s"
    minutes, rem = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes}m {rem:02d}s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h {minutes:02d}m {rem:02d}s"

def completed_at_short(value):
    if not value:
        return "unknown"
    return value.replace("T", " ").replace("Z", "")[:16]

def markdown_escape(value):
    value = "" if value is None else str(value)
    return value.replace("\\", "\\\\").replace("|", "\\|").replace("`", "\\`").replace("\n", "<br>")

def normalize(aggregate, artifact_dir=""):
    run_id = aggregate.get("runId")
    if not run_id:
        raise ValueError("aggregate missing runId")
    model = aggregate.get("model") or {}
    profile = aggregate.get("profile") or {}
    performance = aggregate.get("performance")
    if not isinstance(performance, dict):
        performance = {"available": False, "limitations": ["Only duration and model file size are captured in the current host history index."]}
    path = model.get("path") or model.get("configuredPath") or ""
    configured = model.get("configured") or basename(path)
    running = model.get("running") or configured
    if path and os.path.exists(path):
        try:
            performance.setdefault("modelFileSizeBytes", os.path.getsize(path))
            performance.setdefault("available", True)
        except OSError:
            pass
    return {
        "schemaVersion": SCHEMA,
        "runId": run_id,
        "model": {
            "alias": model.get("alias") or model.get("ref") or "",
            "configured": configured,
            "running": running,
            "path": path,
            "basename": basename(running or configured or path),
        },
        "profile": {
            "id": profile.get("id") or aggregate.get("profileId") or "full",
            "name": profile.get("name") or (profile.get("id") or "full").title(),
        },
        "overallStatus": aggregate.get("overallStatus") or "ERROR",
        "score": aggregate.get("score"),
        "scoreComplete": bool(aggregate.get("scoreComplete", aggregate.get("score") is not None)),
        "startedAt": aggregate.get("startedAt"),
        "completedAt": aggregate.get("completedAt"),
        "durationSeconds": aggregate.get("durationSeconds"),
        "completed": bool(aggregate.get("completed", False)),
        "coverage": aggregate.get("coverage") or {},
        "categories": aggregate.get("categories") or {},
        "warnings": aggregate.get("warnings") or [],
        "failures": aggregate.get("failures") or [],
        "performance": performance,
        "artifactDirectory": artifact_dir or aggregate.get("artifactDirectory") or "",
        "clawbox": aggregate.get("clawbox") or {},
        "suite": aggregate.get("suite") or {},
        "scenarios": aggregate.get("scenarios") or [],
    }

def load_records(runs_dir):
    records = []
    if not os.path.isdir(runs_dir):
        return records
    for name in sorted(os.listdir(runs_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(runs_dir, name)
        try:
            record = load_json(path)
            if record.get("runId"):
                records.append(record)
        except Exception:
            continue
    records.sort(key=lambda r: (r.get("completedAt") or r.get("startedAt") or "", r.get("runId") or ""), reverse=True)
    return records

def update_models(models_file, runs_dir):
    try:
        models = load_json(models_file) if os.path.exists(models_file) else {"schemaVersion": SCHEMA, "models": {}}
    except Exception:
        backup = models_file + ".corrupt"
        try:
            shutil.copy2(models_file, backup)
        except Exception:
            pass
        models = {"schemaVersion": SCHEMA, "models": {}}
    models.setdefault("schemaVersion", SCHEMA)
    registry = models.setdefault("models", {})
    for record in load_records(runs_dir):
        key = model_key(record)
        entry = registry.setdefault(key, {})
        user = {k: entry.get(k) for k in ("displayName", "roles", "notes", "preferred") if k in entry}
        m = record.get("model") or {}
        p = (record.get("profile") or {}).get("id") or "full"
        q = entry.setdefault("qualification", {})
        q[p] = {
            "latestRunId": record.get("runId"),
            "latestStatus": record.get("overallStatus"),
            "latestScore": record.get("score"),
            "latestDurationSeconds": record.get("durationSeconds"),
            "lastQualifiedAt": record.get("completedAt"),
        }
        best = q[p].get("bestScore")
        score = record.get("score")
        if isinstance(score, (int, float)) and (best is None or score > best):
            q[p]["bestScore"] = score
        entry.update({
            "basename": m.get("basename") or basename(key),
            "path": m.get("path") or key,
            "lastSeenAt": record.get("completedAt") or record.get("startedAt"),
            "lastQualifiedAt": record.get("completedAt"),
            "lastQualifiedRunId": record.get("runId"),
            "latestDurationSeconds": record.get("durationSeconds"),
            "latestClawBoxCommit": (record.get("clawbox") or {}).get("commit"),
            "latestSuiteChecksum": (record.get("suite") or {}).get("checksum"),
            "indexedRunCount": sum(1 for r in load_records(runs_dir) if model_key(r) == key),
        })
        for k, v in user.items():
            if v is not None:
                entry[k] = v
    atomic_write(models_file, json.dumps(models, indent=2, sort_keys=True))

def index_one(aggregate_path, runs_dir, models_file, artifact_dir):
    record = normalize(load_json(aggregate_path), artifact_dir)
    if record.get("completed") is not True:
        raise ValueError("aggregate is not completed")
    path = os.path.join(runs_dir, f"{record['runId']}.json")
    if os.path.exists(path):
        try:
            existing = load_json(path)
            if existing.get("completed") and not record.get("completed"):
                return
        except Exception:
            pass
    atomic_write(path, json.dumps(record, indent=2, sort_keys=True))
    update_models(models_file, runs_dir)

def init_models(models_file):
    if not os.path.exists(models_file):
        atomic_write(models_file, json.dumps({"schemaVersion": SCHEMA, "models": {}}, indent=2, sort_keys=True))

def filter_records(records, model="", profile=""):
    out = []
    for r in records:
        if model:
            needle = model.lower()
            m = r.get("model") or {}
            values = [display_model(r), m.get("path"), m.get("configured"), m.get("running"), m.get("basename")]
            if not any(needle in (v or "").lower() for v in values):
                continue
        if profile and (r.get("profile") or {}).get("id") != profile:
            continue
        out.append(r)
    return out

def print_history(records, as_json):
    if as_json == "true":
        print(json.dumps({"schemaVersion": SCHEMA, "runs": records}, separators=(",", ":")))
        return
    print("-----------------------------------------")
    print(" > Qualification History")
    print("-----------------------------------------")
    print("")
    if not records:
        print("No qualification history found.")
        return
    print(f"{'Run ID':<24} {'Model':<34} {'Profile':<7} {'Result':<7} {'Score':<7} {'Duration':<9} Completed")
    for r in records:
        score = "Unrated" if r.get("score") is None else str(r.get("score"))
        print(f"{r.get('runId',''):<24} {display_model(r)[:34]:<34} {(r.get('profile') or {}).get('name',''):<7} {r.get('overallStatus',''):<7} {score:<7} {duration(r.get('durationSeconds')):<9} {completed_at_short(r.get('completedAt'))}")

def pick_latest(records, model="", profile=""):
    candidates = filter_records(records, model, profile)
    return candidates[0] if candidates else None

def scenario_score(record, scenario_id):
    for s in record.get("scenarios") or []:
        if s.get("scenarioId") == scenario_id:
            return s.get("score")
    return None

def compare_records(runs_dir, as_json, profile, models, run_ids):
    records = load_records(runs_dir)
    selected = []
    if run_ids:
        for rid in run_ids:
            match = next((r for r in records if r.get("runId") == rid), None)
            if not match:
                die(f"Run not found: {rid}", 1)
            selected.append(match)
    elif models:
        for m in [x.strip() for x in models.split(",") if x.strip()]:
            match = pick_latest(records, m, profile)
            if not match:
                die(f"No {profile} qualification history found for model: {m}", 1)
            selected.append(match)
    else:
        seen = {}
        for r in records:
            if (r.get("profile") or {}).get("id") != profile:
                continue
            key = model_key(r)
            if key not in seen:
                seen[key] = r
        selected = list(seen.values())
    if len(selected) < 2:
        die("Comparison requires at least two eligible qualification runs.", 1)
    metrics = []
    for r in selected:
        metrics.append({
            "runId": r.get("runId"),
            "model": display_model(r),
            "profile": (r.get("profile") or {}).get("id"),
            "status": r.get("overallStatus"),
            "score": r.get("score"),
            "durationSeconds": r.get("durationSeconds"),
            "toolReliability": scenario_score(r, "01-tool-reliability"),
            "workflowCorrectness": scenario_score(r, "02-tool-workflows"),
            "codeRepair": scenario_score(r, "03-code-repair"),
        })
    if as_json == "true":
        print(json.dumps({"schemaVersion": SCHEMA, "runs": selected, "metrics": metrics}, separators=(",", ":")))
        return
    print("-----------------------------------------")
    print(" > Qualification Comparison")
    print("-----------------------------------------")
    print("")
    names = [m["model"][:22] for m in metrics]
    print(f"{'Metric':<30}" + "".join(f" {n:<22}" for n in names))
    rows = [
        ("Profile", [m["profile"] for m in metrics]),
        ("Overall result", [m["status"] for m in metrics]),
        ("Overall score", ["Unrated" if m["score"] is None else m["score"] for m in metrics]),
        ("Total duration", [duration(m["durationSeconds"]) for m in metrics]),
        ("Tool reliability", [m["toolReliability"] for m in metrics]),
        ("Workflow correctness", [m["workflowCorrectness"] for m in metrics]),
        ("Code repair", [m["codeRepair"] for m in metrics]),
    ]
    for label, values in rows:
        print(f"{label:<30}" + "".join(f" {str(v if v is not None else '—'):<22}" for v in values))

def report_record(runs_dir, run_id, latest, output, force):
    records = load_records(runs_dir)
    record = records[0] if latest == "true" and records else next((r for r in records if r.get("runId") == run_id), None)
    if not record:
        die("Requested qualification run was not found.", 1)
    score = "Unrated" if record.get("score") is None else f"{record.get('score')}/100"
    lines = [
        "# ClawBox Model Qualification Report",
        "",
        "## Summary",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Model | {markdown_escape(display_model(record))} |",
        f"| Profile | {markdown_escape((record.get('profile') or {}).get('name'))} |",
        f"| Result | {markdown_escape(record.get('overallStatus'))} |",
        f"| Score | {markdown_escape(score)} |",
        f"| Duration | {markdown_escape(duration(record.get('durationSeconds')))} |",
        f"| Run ID | {markdown_escape(record.get('runId'))} |",
        f"| Completed | {markdown_escape(record.get('completedAt'))} |",
        f"| ClawBox commit | {markdown_escape((record.get('clawbox') or {}).get('commit'))} |",
        f"| Suite checksum | {markdown_escape((record.get('suite') or {}).get('checksum'))} |",
        f"| Artifacts | {markdown_escape(record.get('artifactDirectory'))} |",
        "",
        "## Scenarios",
        "",
        "| Scenario | Status | Score | Duration |",
        "|---|---:|---:|---:|",
    ]
    for s in record.get("scenarios") or []:
        score_value = "Unrated" if s.get("score") is None else f"{s.get('score')}/100"
        lines.append(f"| {markdown_escape(s.get('scenarioId'))} | {markdown_escape(s.get('status'))} | {markdown_escape(score_value)} | {markdown_escape(duration(s.get('durationSeconds')))} |")
    if record.get("warnings"):
        lines += ["", "## Warnings", ""]
        lines += [f"- {markdown_escape(w)}" for w in record.get("warnings")]
    if record.get("failures"):
        lines += ["", "## Failures", ""]
        lines += [f"- {markdown_escape(f)}" for f in record.get("failures")]
    perf = record.get("performance") or {}
    lines += ["", "## Performance", ""]
    if perf.get("available"):
        for k, v in sorted(perf.items()):
            if k != "available":
                lines.append(f"- {markdown_escape(k)}: {markdown_escape(v)}")
    else:
        lines.append("- Detailed performance metrics were not available for this run.")
    lines += ["", "Qualification results are model-dependent and evaluate ClawBox/OpenClaw agent behavior, not raw model intelligence."]
    body = "\n".join(lines) + "\n"
    if output:
        if os.path.exists(output) and force != "true":
            die(f"Refusing to overwrite existing file: {output}", 1)
        atomic_write(output, body.rstrip("\n"))
    else:
        print(body, end="")

def badge_color(status, score):
    status = status or "Unrated"
    if status == "PASS": return "brightgreen"
    if status == "WARNING": return "yellow"
    if status == "FAIL": return "red"
    return "lightgrey"

def badge(runs_dir, run_id, model, latest, fmt):
    records = load_records(runs_dir)
    record = None
    if run_id:
        record = next((r for r in records if r.get("runId") == run_id), None)
    elif model:
        record = pick_latest(records, model, "")
    elif latest == "true":
        record = records[0] if records else None
    else:
        record = records[0] if records else None
    if not record:
        die("Requested qualification run was not found.", 1)
    status = record.get("overallStatus") or "Unrated"
    score = record.get("score")
    profile = (record.get("profile") or {}).get("name") or "Unknown"
    model_name = display_model(record)
    score_text = "Unrated" if score is None else f"{score}/100"
    label = f"ClawBox {profile}"
    message = f"{status} {score_text}"
    color = badge_color(status, score)
    url = f"https://img.shields.io/badge/{urllib.parse.quote(label, safe='')}-{urllib.parse.quote(message, safe='')}-{color}"
    markdown = f"![ClawBox Qualification: {message}]({url})"
    data = {"runId": record.get("runId"), "model": model_name, "profile": (record.get("profile") or {}).get("id"), "status": status, "score": score, "label": label, "message": message, "color": color, "markdown": markdown}
    if fmt == "json":
        print(json.dumps(data, separators=(",", ":")))
    elif fmt == "markdown":
        print(markdown)
    else:
        print(f"CLAWBOX QUALIFICATION · {profile} · {status} · {score_text} · {model_name}")

def refresh(stream_path, runs_dir, models_file, as_json):
    imported = skipped = current = 0
    current_path = None
    buf = []
    def flush(path, lines):
        nonlocal imported, skipped, current
        if not path:
            return
        tmp = tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8")
        try:
            tmp.write("\n".join(lines).strip() + "\n")
            tmp.close()
            before = set(os.listdir(runs_dir)) if os.path.isdir(runs_dir) else set()
            try:
                index_one(tmp.name, runs_dir, models_file, os.path.dirname(os.path.dirname(path)))
                after = set(os.listdir(runs_dir))
                if after == before:
                    current += 1
                else:
                    imported += 1
            except Exception:
                skipped += 1
        finally:
            try: os.unlink(tmp.name)
            except Exception: pass
    os.makedirs(runs_dir, exist_ok=True)
    with open(stream_path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("CLAWBOX_AGGREGATE_BEGIN "):
                flush(current_path, buf)
                current_path = line.split(" ", 1)[1]
                buf = []
            elif line == "CLAWBOX_AGGREGATE_END":
                flush(current_path, buf)
                current_path = None
                buf = []
            else:
                buf.append(line)
    flush(current_path, buf)
    result = {"schemaVersion": SCHEMA, "imported": imported, "skipped": skipped, "current": current}
    if as_json == "true":
        print(json.dumps(result, separators=(",", ":")))
    else:
        print(f"History refresh complete: {imported} imported, {current} current, {skipped} skipped.")

def metadata(models_file, model, ops, as_json):
    try:
        data = load_json(models_file) if os.path.exists(models_file) else {"schemaVersion": SCHEMA, "models": {}}
    except Exception:
        data = {"schemaVersion": SCHEMA, "models": {}}
    entry = data.setdefault("models", {}).setdefault(model, {"path": model, "basename": basename(model), "qualification": {}})
    i = 0
    while i < len(ops):
        op = ops[i]
        if op == "--set-display-name":
            entry["displayName"] = ops[i+1]; i += 2
        elif op == "--add-role":
            roles = entry.setdefault("roles", [])
            if ops[i+1] not in roles: roles.append(ops[i+1])
            i += 2
        elif op == "--set-note":
            entry["notes"] = ops[i+1]; i += 2
        elif op == "--preferred":
            entry["preferred"] = True; i += 1
        else:
            die(f"Unknown metadata option: {op}", 1)
    atomic_write(models_file, json.dumps(data, indent=2, sort_keys=True))
    if as_json == "true":
        print(json.dumps(entry, separators=(",", ":")))
    else:
        print(f"Model metadata for {basename(model)}")
        for key in ("displayName", "roles", "notes", "preferred", "lastQualifiedRunId"):
            if key in entry:
                print(f"{key}: {entry[key]}")

if action == "init-models":
    init_models(args[0])
elif action == "index":
    index_one(args[0], args[1], args[2], args[3])
elif action == "history":
    runs_dir, as_json, model, profile, limit, latest = args
    records = filter_records(load_records(runs_dir), model, profile)
    if latest == "true":
        records = records[:1]
    elif limit:
        records = records[:int(limit)]
    print_history(records, as_json)
elif action == "compare":
    runs_dir, as_json, profile, models, *run_ids = args
    compare_records(runs_dir, as_json, profile, models, run_ids)
elif action == "report":
    runs_dir, run_id, latest, output, force = args
    report_record(runs_dir, run_id, latest, output, force)
elif action == "badge":
    runs_dir, run_id, model, latest, fmt = args
    badge(runs_dir, run_id, model, latest, fmt)
elif action == "refresh":
    refresh(args[0], args[1], args[2], args[3])
elif action == "metadata":
    models_file, model, as_json, *ops = args
    metadata(models_file, model, ops, as_json)
else:
    die(f"Unknown history action: {action}", 2)
PY
}
