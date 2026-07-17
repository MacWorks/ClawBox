#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/helpers/setup-harness.sh"
TEMP_DIR="$(mktemp -d)"
export CLAWBOX_QUALIFY_DATA_DIR="$TEMP_DIR/data/qualification"
trap cleanup_temp_dir EXIT

write_fixture_aggregate() {
  local path="$1" run_id="$2" model_path="$3" profile="$4" status="$5" score="$6" duration="$7" completed="$8"
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$run_id" "$model_path" "$profile" "$status" "$score" "$duration" "$completed" <<'PY'
import json, os, sys
path, run_id, model_path, profile, status, score, duration, completed = sys.argv[1:]
score_value = None if score == "null" else int(score)
profile_name = profile.title()
model_base = os.path.basename(model_path)
data = {
    "schemaVersion": "1",
    "runId": run_id,
    "startedAt": completed.replace("21:46", "20:52").replace("20:38", "20:26"),
    "completedAt": completed,
    "durationSeconds": int(duration),
    "completed": True,
    "suite": {"schemaVersion": "1", "checksum": "suite-" + profile},
    "clawbox": {"commit": "2d592bb", "dirty": False},
    "profile": {"id": profile, "name": profile_name},
    "coverage": {"profile": profile, "scenariosRun": 3, "reliabilityIterations": 3 if profile == "fast" else 10, "workflowCases": 3 if profile == "fast" else 5},
    "model": {"alias": "clawbox/local", "configured": model_base, "running": model_base, "path": model_path},
    "overallStatus": status,
    "score": score_value,
    "scoreComplete": score_value is not None,
    "categories": {"tool_correctness": {"score": score_value}},
    "warnings": ["extra verification call"] if status == "WARNING" else [],
    "failures": ["final response mismatch"] if status == "FAIL" else [],
    "performance": {"available": False, "limitations": ["timing unavailable"]},
    "artifactDirectory": "/vm/runs/" + run_id,
    "scenarios": [
        {"scenarioId": "01-tool-reliability", "scenarioName": "Tool-calling reliability", "status": status, "score": score_value, "durationSeconds": 12, "metrics": {"averageToolCalls": 1.3}},
        {"scenarioId": "02-tool-workflows", "scenarioName": "Tool workflow correctness", "status": "PASS", "score": 100, "durationSeconds": 10, "metrics": {"averageToolCalls": 1.0}},
        {"scenarioId": "03-code-repair", "scenarioName": "Code repair", "status": "PASS", "score": 100, "durationSeconds": 20, "metrics": {"testResult": "PASS"}},
    ],
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}

index_fixture() {
  local aggregate="$1"
  (
    BASE_DIR="$ROOT_DIR"
    source "$ROOT_DIR/lib/output.sh"
    source "$ROOT_DIR/lib/qualify/history.sh"
    qualify_history_index_aggregate "$aggregate" "/vm/artifacts"
  )
}

seed_history() {
  local agg1="$TEMP_DIR/qwen-full.json" agg2="$TEMP_DIR/ternary-full.json" agg3="$TEMP_DIR/qwen-fast.json"
  write_fixture_aggregate "$agg1" "20260716T205209Z-2961" "/Users/Shared/AI-Models/Qwen3.6-27B-Q5_K_M.gguf" full PASS 100 3261 "2026-07-16T21:46:00Z"
  write_fixture_aggregate "$agg2" "20260716T202639Z-8526" "/Users/Shared/AI-Models/Ternary-Bonsai-27B-Q2_g64.gguf" full FAIL 98 707 "2026-07-16T20:38:00Z"
  write_fixture_aggregate "$agg3" "20260716T195000Z-1111" "/Users/Shared/AI-Models/Qwen3.6-27B-Q5_K_M.gguf" fast WARNING 97 400 "2026-07-16T19:58:00Z"
  index_fixture "$agg1"
  index_fixture "$agg2"
  index_fixture "$agg3"
}

test_index_and_history_filters() {
  local output json latest
  seed_history
  output="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify history 2>&1)"
  assert_contains 'history shows section heading' "$output" 'Qualification History'
  assert_contains 'history lists newest Qwen run' "$output" '20260716T205209Z-2961'
  assert_contains 'history lists Ternary run' "$output" 'Ternary-Bonsai-27B-Q2_g64.gguf'
  assert_contains 'history displays historical FAIL without command failure' "$output" 'FAIL'

  json="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify history --profile fast --json)"
  python3 -m json.tool >/dev/null <<<"$json"
  assert_contains 'history json includes fast profile run' "$json" '20260716T195000Z-1111'
  assert_not_contains 'history profile filter excludes full run' "$json" '20260716T205209Z-2961'

  latest="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify history --latest --json)"
  assert_contains 'history latest returns newest run' "$latest" '20260716T205209Z-2961'
  assert_not_contains 'history latest returns one run' "$latest" '20260716T202639Z-8526'
}

test_compare_report_and_badge() {
  local compare markdown badge badge_json report_file status=0 overwrite_output
  seed_history
  compare="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify compare --profile full 2>&1)"
  assert_contains 'compare shows section heading' "$compare" 'Qualification Comparison'
  assert_contains 'compare includes Qwen model' "$compare" 'Qwen3.6-27B-Q5_K_M'
  assert_contains 'compare includes Ternary model' "$compare" 'Ternary-Bonsai-27B-Q2'
  assert_contains 'compare includes duration metric' "$compare" 'Total duration'

  markdown="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify report --latest)"
  assert_contains 'markdown report has title' "$markdown" '# ClawBox Model Qualification Report'
  assert_contains 'markdown report includes scenario table' "$markdown" '| Scenario | Status | Score | Duration |'

  report_file="$TEMP_DIR/report.md"
  CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify report --latest --output "$report_file"
  if [ -s "$report_file" ]; then pass 'report output file is written'; else fail 'report output file is written'; fi
  set +e
  overwrite_output="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify report --latest --output "$report_file" 2>&1)"
  status=$?
  set -e
  assert_equals 'report refuses overwrite without force' "$status" '1'
  assert_contains 'report overwrite failure is clear' "$overwrite_output" 'Refusing to overwrite existing file'

  badge="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify badge --latest --format markdown)"
  assert_contains 'markdown badge uses shields URL' "$badge" 'img.shields.io'
  badge_json="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify badge --latest --format json)"
  python3 -m json.tool >/dev/null <<<"$badge_json"
  assert_contains 'badge json includes status' "$badge_json" '"status":"PASS"'
}

test_metadata_command_and_model_menu_annotation() {
  local metadata menu_output models_dir
  seed_history
  metadata="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" model metadata "/Users/Shared/AI-Models/Ternary-Bonsai-27B-Q2_g64.gguf" --set-display-name "Ternary Bonsai 27B" --add-role coding --set-note "Fast interactive agent model." --preferred --json)"
  python3 -m json.tool >/dev/null <<<"$metadata"
  assert_contains 'metadata stores display name' "$metadata" 'Ternary Bonsai 27B'
  assert_contains 'metadata stores role' "$metadata" 'coding'

  models_dir="$TEMP_DIR/models"
  mkdir -p "$models_dir"
  touch "$models_dir/Qwen3.6-27B-Q5_K_M.gguf" "$models_dir/Other.gguf"
  menu_output="$({
    BASE_DIR="$ROOT_DIR"
    source "$ROOT_DIR/lib/output.sh"
    source "$ROOT_DIR/lib/setup-models.sh"
    model_qualification_summary_for_menu "$models_dir/Qwen3.6-27B-Q5_K_M.gguf"
  } 2>&1)"
  assert_contains 'model menu annotation shows full result' "$menu_output" 'Full: PASS 100/100'
  assert_contains 'model menu annotation shows qualified date' "$menu_output" 'qualified 2026-07-16'
}

test_invalid_requests_fail_clearly() {
  local output status=0
  seed_history
  set +e
  output="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify history --limit nope 2>&1)"
  status=$?
  set -e
  assert_equals 'invalid history limit exits one' "$status" '1'
  assert_contains 'invalid history limit is clear' "$output" 'Invalid limit'

  set +e
  output="$(CLAWBOX_QUALIFY_DATA_DIR="$CLAWBOX_QUALIFY_DATA_DIR" "$ROOT_DIR/clawbox" qualify compare --profile full --models Qwen3.6-27B-Q5_K_M.gguf 2>&1)"
  status=$?
  set -e
  assert_equals 'compare with fewer than two models exits one' "$status" '1'
  assert_contains 'compare fewer than two is clear' "$output" 'at least two'
}

run_test test_index_and_history_filters
run_test test_compare_report_and_badge
run_test test_metadata_command_and_model_menu_annotation
run_test test_invalid_requests_fail_clearly

if [ "$FAILURES" -eq 0 ]; then
  pass 'qualification history test suite succeeded'
else
  exit 1
fi
