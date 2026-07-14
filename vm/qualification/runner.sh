#!/usr/bin/env bash
set -euo pipefail

case "$0" in
  */*) RUNNER_SCRIPT_DIR="${0%/*}" ;;
  *) RUNNER_SCRIPT_DIR='.' ;;
esac
SUITE_DIR="$(cd "$RUNNER_SCRIPT_DIR" && pwd)"
SCENARIO_DIR="$SUITE_DIR/scenarios"
RUNS_DIR="${CLAWBOX_QUALIFY_RUNS_DIR:-$SUITE_DIR/runs}"
SCENARIO_FILTER=''
JSON_MODE=false
RUN_ID="${CLAWBOX_QUALIFY_RUN_ID:-$(date -u '+%Y%m%dT%H%M%SZ')-$RANDOM}"

usage() { printf 'Usage: runner.sh [--scenario <scenario-id>] [--json]\n'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scenario) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; SCENARIO_FILTER="$2"; shift 2 ;;
    --json) JSON_MODE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

emit_preflight_error() {
  local message="$1"
  if [ "$JSON_MODE" = true ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -n --arg runId "$RUN_ID" --arg message "$message" '{schemaVersion:"1",runId:$runId,model:{alias:"unknown",configured:"unknown",running:"unknown"},overallStatus:"ERROR",score:null,categories:{},warnings:[],failures:[$message],scenarios:[],artifactDirectory:null}'
    else
      local escaped
      escaped="${message//\\/\\\\}"
      escaped="${escaped//\"/\\\"}"
      printf '{"schemaVersion":"1","runId":"%s","model":{"alias":"unknown","configured":"unknown","running":"unknown"},"overallStatus":"ERROR","score":null,"categories":{},"warnings":[],"failures":["%s"],"scenarios":[],"artifactDirectory":null}\n' "$RUN_ID" "$escaped"
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

scenario_paths() {
  case "$SCENARIO_FILTER" in
    '') find "$SCENARIO_DIR" -maxdepth 1 -type f -name '*.sh' | LC_ALL=C sort ;;
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

jq -s \
  --arg runId "$RUN_ID" \
  --arg modelAlias "${CLAWBOX_QUALIFY_MODEL_ALIAS:-${CLAWBOX_QUALIFY_MODEL_REF:-unknown}}" \
  --arg modelConfigured "${CLAWBOX_QUALIFY_MODEL_CONFIGURED:-unknown}" \
  --arg modelRunning "${CLAWBOX_QUALIFY_MODEL_RUNNING:-unknown}" \
  --arg modelWarning "${CLAWBOX_QUALIFY_MODEL_WARNING:-}" \
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
  | {schemaVersion:"1",runId:$runId,model:{alias:$modelAlias,configured:$modelConfigured,running:$modelRunning},overallStatus:$overall,score:(if ($scores|length)>0 then (($scores|add / length)|round) else null end),categories:{"Tool correctness": category_status(["tool_correctness"]),"Grounding": category_status(["grounding"]),"Workflow correctness": category_status(["workflow_correctness"]),"Instruction following": category_status(["instruction_following"]),"Code and state correctness": category_status(["code_state_correctness"]),"Hallucination avoidance": category_status(["hallucination_avoidance"]),"Efficiency": category_status(["efficiency"])},warnings:($modelWarnings + ($scenarios|map(.warnings[]?) )),failures:($scenarios|map(.failures[]?) ),scenarios:$scenarios,artifactDirectory:$artifactDir}' "$results_dir"/*.json >"$results_dir/aggregate.json"

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
