#!/usr/bin/env bash
set -euo pipefail

case "$0" in
  */*) RUNNER_SCRIPT_DIR="${0%/*}" ;;
  *) RUNNER_SCRIPT_DIR='.' ;;
esac
SUITE_DIR="$(cd "$RUNNER_SCRIPT_DIR" && pwd)"
SCENARIO_DIR="$SUITE_DIR/scenarios"
if [ -n "${CLAWBOX_QUALIFY_RUNS_DIR:-}" ]; then
  RUNS_DIR="$CLAWBOX_QUALIFY_RUNS_DIR"
elif [ "${SUITE_DIR##*/}" = current ]; then
  RUNS_DIR="$(cd "$SUITE_DIR/.." && pwd)/runs"
else
  RUNS_DIR="$SUITE_DIR/runs"
fi
SCENARIO_FILTER=''
JSON_MODE=false
PROFILE_ID='full'
PROFILE_EXPLICIT=false

qualification_utc_date() {
  if [ -x /bin/date ]; then
    /bin/date -u "$@"
  else
    date -u "$@"
  fi
}

RUN_ID="${CLAWBOX_QUALIFY_RUN_ID:-$(qualification_utc_date '+%Y%m%dT%H%M%SZ')-$RANDOM}"
STARTED_AT="${CLAWBOX_QUALIFY_STARTED_AT:-$(qualification_utc_date '+%Y-%m-%dT%H:%M:%SZ')}"
START_EPOCH="${CLAWBOX_QUALIFY_START_EPOCH:-$(qualification_utc_date '+%s')}"

usage() { printf 'Usage: runner.sh [--profile fast|full] [--scenario <scenario-id>] [--json]\n'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      [ "$PROFILE_EXPLICIT" = false ] || { printf 'Duplicate --profile option.\n' >&2; exit 2; }
      PROFILE_ID="$2"
      PROFILE_EXPLICIT=true
      shift 2
      ;;
    --scenario) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; SCENARIO_FILTER="$2"; shift 2 ;;
    --json) JSON_MODE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

profile_name() {
  case "$1" in
    fast) printf 'Fast\n' ;;
    full) printf 'Full\n' ;;
    *) return 1 ;;
  esac
}

profile_reliability_iterations() {
  case "$1" in
    fast) printf '3\n' ;;
    full) printf '10\n' ;;
    *) return 1 ;;
  esac
}

profile_workflow_cases() {
  case "$1" in
    fast) printf 'exact-output grounded-read absence-check\n' ;;
    full) printf 'exact-output grounded-read absence-check two-step transform\n' ;;
    *) return 1 ;;
  esac
}

profile_scenarios() {
  case "$1" in
    fast|full) printf '%s\n' '01-tool-reliability' '02-tool-workflows' '03-code-repair' ;;
    *) return 1 ;;
  esac
}

case "$PROFILE_ID" in
  fast|full) ;;
  *) printf 'Unknown qualification profile: %s\n' "$PROFILE_ID" >&2; exit 2 ;;
esac
PROFILE_NAME="$(profile_name "$PROFILE_ID")"
PROFILE_RELIABILITY_ITERATIONS="$(profile_reliability_iterations "$PROFILE_ID")"
PROFILE_WORKFLOW_CASES="$(profile_workflow_cases "$PROFILE_ID")"
export CLAWBOX_QUALIFY_PROFILE_ID="$PROFILE_ID"
export CLAWBOX_QUALIFY_PROFILE_NAME="$PROFILE_NAME"
export CLAWBOX_QUALIFY_RELIABILITY_ITERATIONS="$PROFILE_RELIABILITY_ITERATIONS"
export CLAWBOX_QUALIFY_WORKFLOW_CASES="$PROFILE_WORKFLOW_CASES"

emit_preflight_error() {
  local message="$1"
  local commit="${CLAWBOX_QUALIFY_CLAWBOX_COMMIT:-}"
  local dirty="${CLAWBOX_QUALIFY_CLAWBOX_DIRTY:-null}"
  if [ "$JSON_MODE" = true ]; then
    if command -v jq >/dev/null 2>&1; then
      case "$dirty" in true|false|null) ;; *) dirty='null' ;; esac
      jq -n --arg runId "$RUN_ID" --arg startedAt "$STARTED_AT" --arg message "$message" --arg commit "$commit" --argjson dirty "$dirty" --arg profileId "$PROFILE_ID" --arg profileName "$PROFILE_NAME" '{schemaVersion:"1",runId:$runId,startedAt:$startedAt,completedAt:null,durationSeconds:null,completed:false,suite:{schemaVersion:"1",checksum:null},clawbox:{commit:(if $commit == "" then null else $commit end),dirty:$dirty},profile:{id:$profileId,name:$profileName},coverage:{profile:$profileId,scenariosRun:0,reliabilityIterations:0,workflowCases:0},model:{alias:"unknown",configured:"unknown",running:"unknown"},overallStatus:"ERROR",score:null,categories:{},warnings:[],failures:[$message],scenarios:[],artifactDirectory:null}'
    else
      local escaped
      escaped="${message//\\/\\\\}"
      escaped="${escaped//\"/\\\"}"
      printf '{"schemaVersion":"1","runId":"%s","startedAt":"%s","completedAt":null,"durationSeconds":null,"completed":false,"suite":{"schemaVersion":"1","checksum":null},"clawbox":{"commit":null,"dirty":null},"profile":{"id":"%s","name":"%s"},"coverage":{"profile":"%s","scenariosRun":0,"reliabilityIterations":0,"workflowCases":0},"model":{"alias":"unknown","configured":"unknown","running":"unknown"},"overallStatus":"ERROR","score":null,"categories":{},"warnings":[],"failures":["%s"],"scenarios":[],"artifactDirectory":null}\n' "$RUN_ID" "$STARTED_AT" "$PROFILE_ID" "$PROFILE_NAME" "$PROFILE_ID" "$escaped"
    fi
  else
    printf 'ERROR: %s\n' "$message"
  fi
  exit 2
}

command -v bash >/dev/null 2>&1 || emit_preflight_error 'Missing required dependency: bash'
command -v jq >/dev/null 2>&1 || emit_preflight_error 'Missing required dependency: jq'
command -v git >/dev/null 2>&1 || emit_preflight_error 'Missing required dependency: git'
command -v openclaw >/dev/null 2>&1 || emit_preflight_error 'Missing required dependency: openclaw'

mkdir -p "$RUNS_DIR/$RUN_ID/results"
results_dir="$RUNS_DIR/$RUN_ID/results"

suite_checksum() {
  if [ -n "${CLAWBOX_QUALIFY_SUITE_CHECKSUM:-}" ]; then
    printf '%s\n' "$CLAWBOX_QUALIFY_SUITE_CHECKSUM"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SUITE_DIR" <<'PY'
import hashlib, os, sys
root = os.path.abspath(sys.argv[1])
entries = []
for current, dirs, files in os.walk(root):
    dirs[:] = sorted(d for d in dirs if d != "runs")
    for name in sorted(files):
        path = os.path.join(current, name)
        rel = os.path.relpath(path, root)
        mode = oct(os.stat(path).st_mode & 0o777)
        with open(path, "rb") as fh:
            entries.append((rel, mode, hashlib.sha256(fh.read()).hexdigest()))
digest = hashlib.sha256()
for rel, mode, file_digest in entries:
    digest.update(rel.encode("utf-8") + b"\0" + mode.encode("ascii") + b"\0" + file_digest.encode("ascii") + b"\0")
print(digest.hexdigest())
PY
    return $?
  fi
  printf 'unknown\n'
}

clawbox_commit() {
  if [ -n "${CLAWBOX_QUALIFY_CLAWBOX_COMMIT:-}" ]; then
    printf '%s\n' "$CLAWBOX_QUALIFY_CLAWBOX_COMMIT"
    return 0
  fi
  git -C "$SUITE_DIR" rev-parse HEAD 2>/dev/null || true
}

clawbox_dirty_json() {
  local value="${CLAWBOX_QUALIFY_CLAWBOX_DIRTY:-}"
  case "$value" in
    true|false|null) printf '%s\n' "$value"; return 0 ;;
  esac
  if ! git -C "$SUITE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'null\n'
    return 0
  fi
  if git -C "$SUITE_DIR" diff --quiet --ignore-submodules -- 2>/dev/null \
    && git -C "$SUITE_DIR" diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
    printf 'false\n'
  else
    printf 'true\n'
  fi
}

scenario_paths() {
  case "$SCENARIO_FILTER" in
    '')
      while IFS= read -r scenario_id; do
        printf '%s/%s.sh\n' "$SCENARIO_DIR" "$scenario_id"
      done <<EOF_PROFILE_SCENARIOS
$(profile_scenarios "$PROFILE_ID")
EOF_PROFILE_SCENARIOS
      ;;
    01-tool-reliability|02-tool-workflows|03-code-repair) printf '%s/%s.sh\n' "$SCENARIO_DIR" "$SCENARIO_FILTER" ;;
    *) printf 'Unknown scenario: %s\n' "$SCENARIO_FILTER" >&2; exit 2 ;;
  esac
}

while IFS= read -r scenario; do
  [ -n "$scenario" ] || continue
  [ -x "$scenario" ] || chmod +x "$scenario"
  scenario_id="$(basename "$scenario" .sh)"
  "$scenario" "$RUN_ID" "$RUNS_DIR/$RUN_ID/$scenario_id" >"$results_dir/$scenario_id.json"
done <<EOF_SCENARIOS
$(scenario_paths)
EOF_SCENARIOS

COMPLETED_AT="${CLAWBOX_QUALIFY_COMPLETED_AT:-$(qualification_utc_date '+%Y-%m-%dT%H:%M:%SZ')}"
COMPLETED_EPOCH="${CLAWBOX_QUALIFY_COMPLETED_EPOCH:-$(qualification_utc_date '+%s')}"
DURATION_SECONDS=$((COMPLETED_EPOCH - START_EPOCH))
if [ "$DURATION_SECONDS" -lt 0 ]; then DURATION_SECONDS=0; fi
SUITE_CHECKSUM="$(suite_checksum || printf 'unknown\n')"
CLAWBOX_COMMIT="$(clawbox_commit)"
CLAWBOX_DIRTY="$(clawbox_dirty_json)"

jq -s \
  --arg runId "$RUN_ID" \
  --arg startedAt "$STARTED_AT" \
  --arg completedAt "$COMPLETED_AT" \
  --arg durationSeconds "$DURATION_SECONDS" \
  --arg suiteSchemaVersion "${CLAWBOX_QUALIFY_SUITE_VERSION:-1}" \
  --arg suiteChecksum "$SUITE_CHECKSUM" \
  --arg clawboxCommit "$CLAWBOX_COMMIT" \
  --argjson clawboxDirty "$CLAWBOX_DIRTY" \
  --arg modelAlias "${CLAWBOX_QUALIFY_MODEL_ALIAS:-${CLAWBOX_QUALIFY_MODEL_REF:-unknown}}" \
  --arg modelConfigured "${CLAWBOX_QUALIFY_MODEL_CONFIGURED:-unknown}" \
  --arg modelRunning "${CLAWBOX_QUALIFY_MODEL_RUNNING:-unknown}" \
  --arg modelWarning "${CLAWBOX_QUALIFY_MODEL_WARNING:-}" \
  --arg profileId "$PROFILE_ID" \
  --arg profileName "$PROFILE_NAME" \
  --arg artifactDir "$RUNS_DIR/$RUN_ID" '
  def priority: {ERROR:0, FAIL:1, WARNING:2, SKIPPED:3, PASS:4};
  def category_status($names):
    [ .[] | .assertions[]? | select(.category as $c | $names | index($c)) | .status ] as $statuses
    | if ($statuses|length)==0 then {status:"unrated"}
      elif ($statuses|index("FAIL")) then {status:"FAIL"}
      elif ($statuses|index("WARNING")) then {status:"WARNING"}
      elif ($statuses|index("PASS")) then {status:"PASS"}
      else {status:"unrated"} end;
  . as $scenarios
  | ($scenarios | map(.status) | if length == 0 then "ERROR" else min_by(priority[.] // 99) end) as $overall
  | ($scenarios | map(select(.unrated|not) | .score) ) as $scores
  | (if $modelWarning == "" then [] else [$modelWarning] end) as $modelWarnings
  | ($scenarios | map(select(.scenarioId=="01-tool-reliability") | .metrics.totalIterations // 0) | add // 0) as $reliabilityIterations
  | ($scenarios | map(select(.scenarioId=="02-tool-workflows") | .metrics.totalCases // 0) | add // 0) as $workflowCases
  | {schemaVersion:"1",runId:$runId,startedAt:$startedAt,completedAt:$completedAt,durationSeconds:($durationSeconds|tonumber),completed:true,suite:{schemaVersion:$suiteSchemaVersion,checksum:$suiteChecksum},clawbox:{commit:(if $clawboxCommit == "" then null else $clawboxCommit end),dirty:$clawboxDirty},profile:{id:$profileId,name:$profileName},coverage:{profile:$profileId,scenariosRun:($scenarios|length),reliabilityIterations:$reliabilityIterations,workflowCases:$workflowCases},model:{alias:$modelAlias,configured:$modelConfigured,running:$modelRunning},overallStatus:$overall,score:(if ($scores|length)>0 then (($scores|add / length)|round) else null end),categories:{"Tool correctness": category_status(["tool_correctness"]),"Grounding": category_status(["grounding"]),"Workflow correctness": category_status(["workflow_correctness"]),"Instruction following": category_status(["instruction_following"]),"Code and state correctness": category_status(["code_state_correctness"]),"Hallucination avoidance": category_status(["hallucination_avoidance"]),"Efficiency": category_status(["efficiency"])},warnings:($modelWarnings + ($scenarios|map(.warnings[]?) )),failures:($scenarios|map(.failures[]?) ),scenarios:$scenarios,artifactDirectory:$artifactDir}' "$results_dir"/*.json >"$results_dir/aggregate.json"

if [ "$JSON_MODE" = true ]; then
  cat "$results_dir/aggregate.json"
else
  jq -r '
    "--------------------------------------------------",
    "Model Qualification Report",
    "--------------------------------------------------",
    "Model: \(.model.running // .model.configured // .model.alias)",
    "OpenClaw alias: \(.model.alias)",
    "Configured model: \(.model.configured)",
    "Running model: \(.model.running)",
    (.scenarios[] | "\(.scenarioId) \(.scenarioName): \(.status)"),
    "Overall Score: \(if .score == null then "unrated" else (.score|tostring) + "/100" end)",
    "Overall Result: \(.overallStatus)",
    "Artifacts: \(.artifactDirectory)",
    "--------------------------------------------------"' "$results_dir/aggregate.json"
fi

overall="$(jq -r '.overallStatus' "$results_dir/aggregate.json")"
ran_real="$(jq -r '[.scenarios[] | select(.status != "SKIPPED")] | length' "$results_dir/aggregate.json")"
if [ "$overall" = ERROR ] || [ "$ran_real" -eq 0 ]; then exit 2; fi
if [ "$overall" = FAIL ]; then exit 1; fi
exit 0
