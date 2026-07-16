#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT_DIR/tests/helpers/setup-harness.sh"
TEMP_DIR="$(mktemp -d)"
export CLAWBOX_QUALIFY_RUNS_DIR="$TEMP_DIR/qualification-runs"
trap cleanup_temp_dir EXIT

install_fake_openclaw() {
  setup_mock_bin_dir
  export CLAWBOX_QUALIFY_SESSION_DIR="$TEMP_DIR/sessions"
  export CLAWBOX_FAKE_OPENCLAW_LOG="$TEMP_DIR/openclaw-args.log"
  mkdir -p "$CLAWBOX_QUALIFY_SESSION_DIR"
  cat > "$MOCK_BIN_DIR/openclaw" <<'MOCK_OPENCLAW'
#!/bin/bash
set -euo pipefail
printf "%s\n" "$*" >> "${CLAWBOX_FAKE_OPENCLAW_LOG:?}"
[ "${1:-}" = agent ] || exit 2
shift
session=""; timeout=""; message=""; json=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session-id) session="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --json) json=true; shift ;;
    --message) message="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$session" ] || exit 2
sessions="${CLAWBOX_QUALIFY_SESSION_DIR:?}"
mkdir -p "$sessions"
trajectory="$sessions/$session.trajectory.jsonl"
transcript="$sessions/$session.jsonl"
final_status="${CLAWBOX_FAKE_OPENCLAW_FINAL_STATUS:-success}"
tool_count="${CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT:-auto}"
reply="DONE"
if [ "$tool_count" = auto ]; then tool_count=1; fi
if printf "%s" "$message" | grep -Fq "Use exec exactly twice"; then tool_count="${CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT:-2}"; fi
if printf "%s" "$message" | grep -Fq "Use exec exactly once to create:"; then
  file="$(printf "%s\n" "$message" | awk '/Use exec exactly once to create:/{getline; print; exit}')"
  content="$(printf "%s\n" "$message" | awk '/The file must contain exactly:/{getline; print; exit}')"
  mkdir -p "$(dirname "$file")"
  if [ "${CLAWBOX_FAKE_OPENCLAW_FABRICATE:-false}" != true ]; then printf "%s" "$content" > "$file"; fi
  reply="DONE"
elif printf "%s" "$message" | grep -Fq "printf 'RED"; then
  reply=$'RED\nGREEN\nBLUE'
elif printf "%s" "$message" | grep -Fq "verification code"; then
  reply="NCC1701"
elif printf "%s" "$message" | grep -Fq "Reply with exactly ABSENT"; then
  reply="ABSENT"
elif printf "%s" "$message" | grep -Fq "Reply with exactly beta"; then
  root_file="$(printf "%s\n" "$message" | awk '/First create /{print $3; exit}')"
  out_file="$(printf "%s\n" "$message" | awk '/write it to /{for(i=1;i<=NF;i++) if($i=="to") {print $(i+1); exit}}')"
  out_file="${out_file%,}"
  mkdir -p "$(dirname "$root_file")" "$(dirname "$out_file")"
  printf "alpha\nbeta\ngamma\n" > "$root_file"
  printf "beta" > "$out_file"
  reply="beta"
elif printf "%s" "$message" | grep -Fq "Reply with exactly the printed lines"; then
  numbers="$(printf "%s\n" "$message" | awk '/First create /{print $3; exit}')"
  sorted="$(printf "%s\n" "$message" | awk '/write the result to /{for(i=1;i<=NF;i++) if($i=="to") {print $(i+1); exit}}')"
  sorted="${sorted%,}"
  mkdir -p "$(dirname "$numbers")" "$(dirname "$sorted")"
  printf "9\n3\n7\n" > "$numbers"
  printf "3\n7\n9" > "$sorted"
  reply=$'3\n7\n9'
elif printf "%s" "$message" | grep -Fq "Project directory:"; then
  project="$(printf "%s\n" "$message" | awk '/Project directory:/{getline; print; exit}')"
  if [ "${CLAWBOX_FAKE_OPENCLAW_UNRELATED_CHANGE:-false}" = true ]; then printf "oops\n" > "$project/unrelated.txt"; fi
  if [ "${CLAWBOX_FAKE_OPENCLAW_FABRICATE:-false}" != true ]; then sed -i.bak 's/\$1 - \$2/\$1 + \$2/' "$project/calculator.sh"; rm -f "$project/calculator.sh.bak"; fi
  reply=$'Root cause: subtraction was used.\nFile changed: calculator.sh\nFinal test result: PASS'
fi
if [ -n "${CLAWBOX_FAKE_OPENCLAW_REPLY:-}" ]; then
  reply="$CLAWBOX_FAKE_OPENCLAW_REPLY"
fi
if [ "${CLAWBOX_FAKE_OPENCLAW_NO_TRAJECTORY:-false}" != true ]; then
  metas="[]"
  if [ "$tool_count" -gt 0 ] 2>/dev/null; then metas="$(jq -n --argjson n "$tool_count" '[range(0;$n)|{name:"exec"}]')"; fi
  jq_args=(--arg session "$session" --arg status "$final_status" --argjson metas "$metas")
  jq_filter='{type:"trace.artifacts",session:$session,data:{finalStatus:$status,toolMetas:$metas}}'
  if [ -n "${CLAWBOX_FAKE_OPENCLAW_ERROR_TYPE:-}" ] || [ -n "${CLAWBOX_FAKE_OPENCLAW_ERROR_MESSAGE:-}" ]; then
    jq_args+=(--arg error_type "${CLAWBOX_FAKE_OPENCLAW_ERROR_TYPE:-agent_error}" --arg error_message "${CLAWBOX_FAKE_OPENCLAW_ERROR_MESSAGE:-OpenClaw agent error}" --argjson timeout "${CLAWBOX_FAKE_OPENCLAW_TIMEOUT:-false}")
    jq_filter='{type:"trace.artifacts",session:$session,data:{finalStatus:$status,toolMetas:$metas,error:{type:$error_type,message:$error_message,timeout:$timeout}}}'
  fi
  if [ "${CLAWBOX_FAKE_OPENCLAW_TRAJECTORY_PRELUDE:-false}" = true ]; then
    jq -nc --arg session "$session" '{type:"trace.step",session:$session,data:{message:"prelude"}}' > "$trajectory"
    jq -nc "${jq_args[@]}" "$jq_filter" >> "$trajectory"
  else
    jq -nc "${jq_args[@]}" "$jq_filter" > "$trajectory"
  fi
  if [ "${CLAWBOX_FAKE_OPENCLAW_MULTIPLE_TRAJECTORIES:-false}" = true ]; then cp "$trajectory" "$sessions/extra-$session.trajectory.jsonl"; fi
  if [ "${CLAWBOX_FAKE_OPENCLAW_MALFORMED_TRAJECTORY:-false}" = true ]; then printf "not-json\n" > "$trajectory"; fi
fi
if [ "${CLAWBOX_FAKE_OPENCLAW_NO_TRANSCRIPT:-false}" != true ]; then
  jq -nc --arg reply "$reply" '{type:"message",message:{role:"assistant",content:[{type:"text",text:$reply}]}}' > "$transcript"
  if [ "${CLAWBOX_FAKE_OPENCLAW_MALFORMED_TRANSCRIPT:-false}" = true ]; then printf "not-json\n" > "$transcript"; fi
fi
printf '{"ok":true}\n'
exit "${CLAWBOX_FAKE_OPENCLAW_EXIT_STATUS:-0}"
MOCK_OPENCLAW
  chmod +x "$MOCK_BIN_DIR/openclaw"
}

test_root_help_lists_qualify() {
  local output
  output="$(bash "$ROOT_DIR/clawbox" help 2>&1)"
  assert_contains 'root help lists qualify command' "$output" 'qualify'
  assert_contains 'root help shows qualify example' "$output" './clawbox qualify'
}

test_qualification_entrypoint_modes() {
  local payload_dir="$TEMP_DIR/qualification-payload-modes"

  if [ -x "$ROOT_DIR/scripts/qualify.sh" ]; then
    pass 'repository qualify command entrypoint is executable'
  else
    fail 'repository qualify command entrypoint should be executable'
  fi

  if [ -x "$ROOT_DIR/vm/qualification/runner.sh" ]; then
    pass 'repository VM qualification runner is executable'
  else
    fail 'repository VM qualification runner should be executable'
  fi

  for scenario in \
    "$ROOT_DIR/vm/qualification/scenarios/01-tool-reliability.sh" \
    "$ROOT_DIR/vm/qualification/scenarios/02-tool-workflows.sh" \
    "$ROOT_DIR/vm/qualification/scenarios/03-code-repair.sh"
  do
    if [ -x "$scenario" ]; then
      pass "repository VM scenario is executable: ${scenario##*/}"
    else
      fail "repository VM scenario should be executable: ${scenario##*/}"
    fi
  done

  if [ ! -x "$ROOT_DIR/vm/qualification/lib/helpers.sh" ]; then
    pass 'VM qualification helper library is source-only'
  else
    fail 'VM qualification helper library should not require executable mode'
  fi

  mkdir -p "$payload_dir"
  tar -C "$ROOT_DIR/vm" -cf - qualification | tar -C "$payload_dir" -xf -

  if [ -x "$payload_dir/qualification/runner.sh" ]; then
    pass 'published payload preserves runner executable mode'
  else
    fail 'published payload should preserve runner executable mode'
  fi

  for scenario in \
    "$payload_dir/qualification/scenarios/01-tool-reliability.sh" \
    "$payload_dir/qualification/scenarios/02-tool-workflows.sh" \
    "$payload_dir/qualification/scenarios/03-code-repair.sh"
  do
    if [ -x "$scenario" ]; then
      pass "published payload preserves scenario executable mode: ${scenario##*/}"
    else
      fail "published payload should preserve scenario executable mode: ${scenario##*/}"
    fi
  done

  if [ ! -x "$payload_dir/qualification/lib/helpers.sh" ]; then
    pass 'published payload keeps helper library source-only'
  else
    fail 'published payload should keep helper library source-only'
  fi
}

test_qualify_help_does_not_execute_remote_commands() {
  local output
  setup_mock_bin_dir
  write_mock_command ssh '#!/bin/bash
printf "SSH_UNEXPECTED\n"
exit 99
'
  output="$(PATH="$MOCK_BIN_DIR:$PATH" "$ROOT_DIR/clawbox" qualify --help 2>&1)"
  assert_contains 'qualify help shows usage' "$output" 'Usage: ./clawbox qualify'
  assert_contains 'qualify help shows profile option' "$output" '--profile fast|full'
  assert_not_contains 'qualify help does not contact ssh' "$output" 'SSH_UNEXPECTED'
}

test_qualify_unknown_options_and_scenarios_fail_clearly() {
  local option_output scenario_output profile_output duplicate_output status=0
  set +e; option_output="$(bash "$ROOT_DIR/scripts/qualify.sh" --bogus 2>&1)"; status=$?; set -e
  assert_equals 'unknown qualify option exits infrastructure error' "$status" '2'
  assert_contains 'unknown qualify option fails clearly' "$option_output" 'Unknown qualify option: --bogus'
  set +e; scenario_output="$(bash "$ROOT_DIR/scripts/qualify.sh" --scenario nope 2>&1)"; status=$?; set -e
  assert_equals 'unknown qualify scenario exits infrastructure error' "$status" '2'
  assert_contains 'unknown qualify scenario fails clearly' "$scenario_output" 'Unknown qualification scenario: nope'
  set +e; profile_output="$(bash "$ROOT_DIR/scripts/qualify.sh" --profile turbo 2>&1)"; status=$?; set -e
  assert_equals 'unknown qualify profile exits infrastructure error' "$status" '2'
  assert_contains 'unknown qualify profile fails clearly' "$profile_output" 'Unknown qualification profile: turbo'
  set +e; duplicate_output="$(bash "$ROOT_DIR/scripts/qualify.sh" --profile fast --profile full 2>&1)"; status=$?; set -e
  assert_equals 'duplicate qualify profile exits infrastructure error' "$status" '2'
  assert_contains 'duplicate qualify profile fails clearly' "$duplicate_output" 'Duplicate --profile option.'
}

test_qualify_runner_errors_when_openclaw_missing() {
  local output status=0 bin="$TEMP_DIR/no-openclaw-bin"
  mkdir -p "$bin"
  ln -sf /bin/bash "$bin/bash"
  ln -sf /usr/bin/jq "$bin/jq"
  ln -sf /usr/bin/git "$bin/git"
  set +e; output="$(PATH="$bin" CLAWBOX_QUALIFY_RUN_ID='missing-openclaw' bash "$ROOT_DIR/vm/qualification/runner.sh" --json 2>&1)"; status=$?; set -e
  assert_equals 'missing openclaw exits infrastructure error' "$status" '2'
  assert_contains 'missing openclaw reports dependency error' "$output" 'Missing required dependency: openclaw'
}

test_qualify_json_host_errors_keep_stdout_machine_readable() {
  local output status=0
  set +e; output="$(CLAWBOX_ENV_FILE="$TEMP_DIR/missing.env" bash "$ROOT_DIR/scripts/qualify.sh" --json --scenario 01-tool-reliability 2>"$TEMP_DIR/json-error.stderr")"; status=$?; set -e
  assert_equals 'json missing-env exits infrastructure error' "$status" '2'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data["overallStatus"] == "ERROR"
assert data["scenarios"] == []
PY
  pass 'json missing-env stdout is valid JSON only'
  assert_contains 'json missing-env diagnostic goes to stderr' "$(cat "$TEMP_DIR/json-error.stderr")" 'ERROR: Missing .env'
}

test_qualify_runner_dependency_preflight_errors() {
  local output status=0 bin="$TEMP_DIR/missing-jq-bin"
  mkdir -p "$bin"
  ln -sf /bin/bash "$bin/bash"
  ln -sf /usr/bin/git "$bin/git"
  cat > "$bin/openclaw" <<'EOF_OPENCLAW'
#!/bin/bash
exit 0
EOF_OPENCLAW
  chmod +x "$bin/openclaw"
  set +e; output="$(PATH="$bin" CLAWBOX_QUALIFY_RUN_ID='missing-jq' bash "$ROOT_DIR/vm/qualification/runner.sh" --json 2>&1)"; status=$?; set -e
  assert_equals 'missing jq exits infrastructure error' "$status" '2'
  assert_contains 'missing jq reports dependency error' "$output" 'Missing required dependency: jq'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data["overallStatus"] == "ERROR"
assert data["failures"] == ["Missing required dependency: jq"]
PY
  pass 'missing jq stdout remains valid JSON'

  bin="$TEMP_DIR/missing-git-bin"
  mkdir -p "$bin"
  ln -sf /bin/bash "$bin/bash"
  ln -sf /usr/bin/jq "$bin/jq"
  cat > "$bin/openclaw" <<'EOF_OPENCLAW'
#!/bin/bash
exit 0
EOF_OPENCLAW
  chmod +x "$bin/openclaw"
  set +e; output="$(PATH="$bin" CLAWBOX_QUALIFY_RUN_ID='missing-git' bash "$ROOT_DIR/vm/qualification/runner.sh" --json 2>&1)"; status=$?; set -e
  assert_equals 'missing git exits infrastructure error' "$status" '2'
  assert_contains 'missing git reports dependency error' "$output" 'Missing required dependency: git'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['completed'] is False
assert data['completedAt'] is None
assert data['durationSeconds'] is None
PY
  pass 'missing git preflight error does not claim completion'
}

test_qualify_runner_default_json_runs_real_scenarios_with_fake_openclaw() {
  local output status=0
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='test-run' CLAWBOX_QUALIFY_STARTED_AT='2026-07-15T13:03:52Z' CLAWBOX_QUALIFY_START_EPOCH=100 CLAWBOX_QUALIFY_COMPLETED_AT='2026-07-15T13:24:17Z' CLAWBOX_QUALIFY_COMPLETED_EPOCH=1325 CLAWBOX_QUALIFY_SUITE_CHECKSUM='suite-checksum' CLAWBOX_QUALIFY_CLAWBOX_COMMIT='abc123' CLAWBOX_QUALIFY_CLAWBOX_DIRTY=false CLAWBOX_QUALIFY_MODEL_ALIAS='clawbox/local' CLAWBOX_QUALIFY_MODEL_CONFIGURED='Configured.gguf' CLAWBOX_QUALIFY_MODEL_RUNNING='Running.gguf' CLAWBOX_QUALIFY_MODEL_WARNING='configured and running differ' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=2 bash "$ROOT_DIR/vm/qualification/runner.sh" --json)"; status=$?; set -e
  assert_equals 'runner exits success when fake model passes all scenarios' "$status" '0'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['schemaVersion']=='1'
assert data['runId']=='test-run'
assert data['startedAt']=='2026-07-15T13:03:52Z'
assert data['completedAt']=='2026-07-15T13:24:17Z'
assert data['durationSeconds']==1225
assert data['completed'] is True
assert data['suite']['schemaVersion']=='1'
assert data['suite']['checksum']=='suite-checksum'
assert data['clawbox']['commit']=='abc123'
assert data['clawbox']['dirty'] is False
assert data['profile']['id']=='full'
assert data['profile']['name']=='Full'
assert data['coverage']['profile']=='full'
assert data['coverage']['scenariosRun']==3
assert data['coverage']['reliabilityIterations']==10
assert data['coverage']['workflowCases']==5
assert data['model']['alias']=='clawbox/local'
assert data['model']['configured']=='Configured.gguf'
assert data['model']['running']=='Running.gguf'
assert 'configured and running differ' in data['warnings']
assert data['overallStatus']=='PASS'
assert len(data['scenarios'])==3
assert data['score'] is not None
PY
  pass 'runner default json is valid and includes real scenario results'
  assert_contains 'fake openclaw was invoked through agent command' "$(cat "$CLAWBOX_FAKE_OPENCLAW_LOG")" 'agent --session-id'
  assert_contains 'fake openclaw received json flag' "$(cat "$CLAWBOX_FAKE_OPENCLAW_LOG")" '--json'
}

test_qualify_profiles_select_expected_coverage() {
  local fast_output full_output fast_workflow full_workflow fast_repair scenario_default status=0
  install_fake_openclaw
  set +e; fast_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='fast-reliability' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'fast reliability exits success' "$status" '0'
  python3 - "$fast_output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['profile']['id']=='fast'
assert data['profile']['name']=='Fast'
assert data['coverage']['reliabilityIterations']==3
assert data['coverage']['workflowCases']==0
assert data['scenarios'][0]['metrics']['totalIterations']==3
assert data['scenarios'][0]['metrics']['profile']['id']=='fast'
PY
  pass 'fast profile reliability uses three iterations'

  install_fake_openclaw
  set +e; full_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='full-reliability' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile full --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'full reliability exits success' "$status" '0'
  python3 - "$full_output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['profile']['id']=='full'
assert data['coverage']['reliabilityIterations']==10
assert data['scenarios'][0]['metrics']['totalIterations']==10
PY
  pass 'full profile reliability uses ten iterations'

  install_fake_openclaw
  set +e; fast_workflow="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='fast-workflow' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --scenario 02-tool-workflows --json)"; status=$?; set -e
  assert_equals 'fast workflow exits success' "$status" '0'
  python3 - "$fast_workflow" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
cases=[case['case'] for case in data['scenarios'][0]['metrics']['cases']]
assert cases == ['exact-output', 'grounded-read', 'absence-check']
assert data['coverage']['workflowCases']==3
assert data['failures']==[]
PY
  pass 'fast profile runs only reduced workflow case set without failures'
  assert_not_contains 'fast workflow omits two-step case' "$fast_workflow" 'two-step'
  assert_not_contains 'fast workflow omits transform case' "$fast_workflow" 'transform'

  install_fake_openclaw
  set +e; full_workflow="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='full-workflow' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile full --scenario 02-tool-workflows --json)"; status=$?; set -e
  assert_equals 'full workflow exits success' "$status" '0'
  python3 - "$full_workflow" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
cases=[case['case'] for case in data['scenarios'][0]['metrics']['cases']]
assert cases == ['exact-output', 'grounded-read', 'absence-check', 'two-step', 'transform']
assert data['coverage']['workflowCases']==5
PY
  pass 'full profile runs all workflow cases'

  install_fake_openclaw
  set +e; fast_repair="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='fast-repair' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --scenario 03-code-repair --json)"; status=$?; set -e
  assert_equals 'fast code repair still runs full code repair scenario' "$status" '0'
  assert_contains 'fast code repair includes code repair scenario' "$fast_repair" '03-code-repair'

  install_fake_openclaw
  set +e; scenario_default="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='scenario-default-full' bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'scenario without profile exits success' "$status" '0'
  python3 - "$scenario_default" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['profile']['id']=='full'
assert data['coverage']['reliabilityIterations']==10
PY
  pass 'scenario without explicit profile uses full parameters'
}

test_qualify_fast_profile_aggregate_includes_all_scenarios() {
  local output status=0
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='fast-suite' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --json)"; status=$?; set -e
  assert_equals 'fast aggregate exits success' "$status" '0'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
ids=[scenario['scenarioId'] for scenario in data['scenarios']]
assert ids == ['01-tool-reliability', '02-tool-workflows', '03-code-repair']
assert data['profile']['id']=='fast'
assert data['coverage']['scenariosRun']==3
assert data['coverage']['reliabilityIterations']==3
assert data['coverage']['workflowCases']==3
assert all(s['status'] != 'SKIPPED' for s in data['scenarios'])
PY
  pass 'fast aggregate includes all three scenarios with reduced coverage'
}

create_aggregate_fixture_suite() {
  local suite="$1"
  mkdir -p "$suite/scenarios"
  cp "$ROOT_DIR/vm/qualification/runner.sh" "$suite/runner.sh"
  chmod +x "$suite/runner.sh"

  cat > "$suite/scenarios/01-tool-reliability.sh" <<'EOF_SCENARIO_01'
#!/usr/bin/env bash
set -euo pipefail
run_id="$1"; artifact_dir="$2"
mkdir -p "$artifact_dir"
status="${CLAWBOX_FIXTURE_01_STATUS:-PASS}"
score="${CLAWBOX_FIXTURE_01_SCORE:-100}"
exit_status="${CLAWBOX_FIXTURE_01_EXIT:-0}"
total="${CLAWBOX_QUALIFY_RELIABILITY_ITERATIONS:-10}"
correct="$total"; efficient="$total"; warnings='[]'; failures='[]'
if [ "$status" = WARNING ]; then
  score="${CLAWBOX_FIXTURE_01_SCORE:-97}"
  efficient=$((total - 1))
  warnings="$(jq -n '["expected 1 efficient tool call, observed 2\nwith quoted \"detail\" and unicode ✓"]')"
elif [ "$status" = FAIL ]; then
  score="${CLAWBOX_FIXTURE_01_SCORE:-60}"
  correct=$((total - 1))
  efficient=$((total - 1))
  failures="$(jq -n '["iteration 3 failed critical assertions\nagentStatus=error"]')"
elif [ "$status" = ERROR ]; then
  failures="$(jq -n '["scenario 01-tool-reliability did not produce valid result JSON"]')"
  jq -n \
    --arg runId "$run_id" \
    --arg artifactDir "$artifact_dir" \
    --argjson failures "$failures" \
    '{schemaVersion:"1",runId:$runId,scenarioId:"01-tool-reliability",scenarioName:"Tool-calling reliability",status:"ERROR",score:null,unrated:true,durationSeconds:0,assertions:[{name:"result_json",status:"ERROR",message:"fixture infrastructure error",category:"tool_correctness"}],toolCalls:{observed:null,expectedMin:null,expectedMax:null,reliable:false},metrics:{},warnings:[],failures:$failures,sessionId:"fixture-01",openclawExitStatus:null,artifacts:{directory:$artifactDir,trajectory:null,transcript:null}}'
  exit "$exit_status"
fi
jq -n \
  --arg runId "$run_id" \
  --arg status "$status" \
  --arg score "$score" \
  --arg total "$total" \
  --arg correct "$correct" \
  --arg efficient "$efficient" \
  --arg artifactDir "$artifact_dir" \
  --argjson warnings "$warnings" \
  --argjson failures "$failures" \
  '{schemaVersion:"1",runId:$runId,scenarioId:"01-tool-reliability",scenarioName:"Tool-calling reliability",status:$status,score:($score|tonumber),unrated:false,durationSeconds:3,assertions:[{name:"task_completion",status:(if $status=="FAIL" then "FAIL" else "PASS" end),message:"fixture reliability",category:"tool_correctness"}],toolCalls:{observed:1,expectedMin:1,expectedMax:1,reliable:true},metrics:{totalIterations:($total|tonumber),correctIterations:($correct|tonumber),efficientIterations:($efficient|tonumber),averageToolCalls:1.4,toolCallsReliable:true,toolCalls:1.4,expectedMin:1,expectedMax:1,iterations:[]},warnings:$warnings,failures:$failures,sessionId:"fixture-01",openclawExitStatus:0,artifacts:{directory:$artifactDir,trajectory:null,transcript:null}}'
exit "$exit_status"
EOF_SCENARIO_01

  cat > "$suite/scenarios/02-tool-workflows.sh" <<'EOF_SCENARIO_02'
#!/usr/bin/env bash
set -euo pipefail
run_id="$1"; artifact_dir="$2"
mkdir -p "$artifact_dir"
cases="${CLAWBOX_QUALIFY_WORKFLOW_CASES:-exact-output grounded-read absence-check two-step transform}"
count=0
for case_name in $cases; do count=$((count + 1)); done
jq -n \
  --arg runId "$run_id" \
  --arg artifactDir "$artifact_dir" \
  --arg selected "$cases" \
  --arg count "$count" \
  '{schemaVersion:"1",runId:$runId,scenarioId:"02-tool-workflows",scenarioName:"Tool workflow correctness",status:"PASS",score:100,unrated:false,durationSeconds:2,assertions:[{name:"workflow_cases",status:"PASS",message:"fixture workflows",category:"workflow_correctness"}],toolCalls:{observed:1.0,expectedMin:1,expectedMax:2,reliable:true},metrics:{selectedCases:($selected|split(" ")|map(select(.!=""))),totalCases:($count|tonumber),passingCases:($count|tonumber),efficientCases:($count|tonumber),averageToolCalls:1.0,toolCallsReliable:true,toolCalls:1.0,cases:[]},warnings:[],failures:[],sessionId:"fixture-02",openclawExitStatus:0,artifacts:{directory:$artifactDir,trajectory:null,transcript:null}}'
EOF_SCENARIO_02

  cat > "$suite/scenarios/03-code-repair.sh" <<'EOF_SCENARIO_03'
#!/usr/bin/env bash
set -euo pipefail
run_id="$1"; artifact_dir="$2"
mkdir -p "$artifact_dir"
reply=$'Root cause: subtraction was used.\nFile changed: calculator.sh\nFinal test result: PASS ✓'
jq -n \
  --arg runId "$run_id" \
  --arg artifactDir "$artifact_dir" \
  --arg reply "$reply" \
  '{schemaVersion:"1",runId:$runId,scenarioId:"03-code-repair",scenarioName:"Code repair",status:"PASS",score:100,unrated:false,durationSeconds:4,assertions:[{name:"final_test",status:"PASS",message:"fixture repair",category:"code_state_correctness"}],toolCalls:{observed:4,expectedMin:null,expectedMax:null,reliable:true},metrics:{toolCalls:4,expectedMin:null,expectedMax:null,toolCallsReliable:true,agentFinalStatus:"success",testResult:"PASS",calculatorValid:true,scopeValid:true,changedFiles:" M calculator.sh",finalReply:$reply},warnings:[],failures:[],sessionId:"fixture-03",openclawExitStatus:0,artifacts:{directory:$artifactDir,trajectory:null,transcript:null}}'
EOF_SCENARIO_03

  chmod +x "$suite"/scenarios/*.sh
}

test_runner_aggregates_fast_and_full_fixture_results_robustly() {
  local suite="$TEMP_DIR/aggregate-fixture-suite" runs="$TEMP_DIR/aggregate-fixture-runs"
  local output status=0
  setup_mock_bin_dir
  write_mock_command openclaw '#!/bin/bash
exit 0
'
  create_aggregate_fixture_suite "$suite"

  set +e
  output="$(cd "$suite" && PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUNS_DIR="$runs" CLAWBOX_QUALIFY_RUN_ID='fixture-fast-pass' ./runner.sh --profile fast --json)"
  status=$?
  set -e
  assert_equals 'fixture fast PASS aggregate exits success' "$status" '0'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['overallStatus']=='PASS'
assert data['profile']['id']=='fast'
assert [s['scenarioId'] for s in data['scenarios']] == ['01-tool-reliability','02-tool-workflows','03-code-repair']
assert data['coverage']['scenariosRun']==3
assert data['coverage']['reliabilityIterations']==3
assert data['coverage']['workflowCases']==3
assert data['scenarios'][0]['metrics']['averageToolCalls'] == 1.4
assert 'Final test result: PASS' in data['scenarios'][2]['metrics']['finalReply']
PY
  pass 'fixture fast PASS aggregate preserves numeric and multiline fields'

  set +e
  output="$(cd "$suite" && PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUNS_DIR="$runs" CLAWBOX_QUALIFY_RUN_ID='fixture-fast-warning' CLAWBOX_FIXTURE_01_STATUS=WARNING ./runner.sh --profile fast --json)"
  status=$?
  set -e
  assert_equals 'fixture fast WARNING aggregate exits success' "$status" '0'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['overallStatus']=='WARNING'
assert data['warnings']
assert 'quoted "detail"' in data['warnings'][0]
PY
  pass 'fixture fast WARNING aggregate keeps valid warning JSON'

  set +e
  output="$(cd "$suite" && PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUNS_DIR="$runs" CLAWBOX_QUALIFY_RUN_ID='fixture-fast-fail' CLAWBOX_FIXTURE_01_STATUS=FAIL CLAWBOX_FIXTURE_01_EXIT=1 ./runner.sh --profile fast --json)"
  status=$?
  set -e
  assert_equals 'fixture fast valid FAIL aggregate returns model failure' "$status" '1'
  python3 - "$output" "$runs/fixture-fast-fail/results/aggregate-inputs/scenario-statuses.tsv" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['overallStatus']=='FAIL'
assert data['scenarios'][0]['status']=='FAIL'
assert 'iteration 3 failed critical assertions' in data['failures'][0]
with open(sys.argv[2], encoding='utf-8') as fh:
    statuses=fh.read()
assert '01-tool-reliability\t1' in statuses
PY
  pass 'fixture fast valid FAIL aggregates despite scenario process exit 1'

  set +e
  output="$(cd "$suite" && PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUNS_DIR="$runs" CLAWBOX_QUALIFY_RUN_ID='fixture-fast-error' CLAWBOX_FIXTURE_01_STATUS=ERROR CLAWBOX_FIXTURE_01_EXIT=2 ./runner.sh --profile fast --json)"
  status=$?
  set -e
  assert_equals 'fixture fast ERROR aggregate returns infrastructure error' "$status" '2'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['overallStatus']=='ERROR'
assert data['score'] is None
assert data['scoreComplete'] is False
assert data['ratedScenarios']==2
assert data['requiredScenarios']==3
assert data['coverage']['reliabilityIterations']==3
assert data['coverage']['workflowCases']==3
PY
  pass 'fixture fast ERROR aggregate is unrated while preserving configured coverage'

  set +e
  output="$(cd "$suite" && PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUNS_DIR="$runs" CLAWBOX_QUALIFY_RUN_ID='fixture-full-pass' ./runner.sh --profile full --json)"
  status=$?
  set -e
  assert_equals 'fixture full PASS aggregate exits success' "$status" '0'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['profile']['id']=='full'
assert data['coverage']['reliabilityIterations']==10
assert data['coverage']['workflowCases']==5
assert data['coverage']['scenariosRun']==3
PY
  pass 'fixture full aggregate uses full profile coverage'
}

test_tool_reliability_serializes_multi_record_trajectories() {
  local output status=0 stderr_file="$TEMP_DIR/multi-record-fast.stderr"
  install_fake_openclaw
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" \
    CLAWBOX_QUALIFY_RUN_ID='multi-record-fast-pass' \
    CLAWBOX_FAKE_OPENCLAW_TRAJECTORY_PRELUDE=true \
    bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --scenario 01-tool-reliability --json 2>"$stderr_file")"
  status=$?
  set -e
  assert_equals 'fast reliability with multi-record trajectories exits success' "$status" '0'
  python3 - "$output" "$CLAWBOX_QUALIFY_RUNS_DIR/multi-record-fast-pass/01-tool-reliability/iterations-array.json" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['overallStatus']=='PASS'
scenario=data['scenarios'][0]
assert scenario['metrics']['totalIterations']==3
assert len(scenario['metrics']['iterations'])==3
assert scenario['metrics']['averageToolCalls']==1
with open(sys.argv[2], encoding='utf-8') as fh:
    iterations=json.load(fh)
assert isinstance(iterations, list)
assert len(iterations)==3
assert all(item['error']['type'] is None for item in iterations)
PY
  pass 'fast reliability serializes three iterations from multi-record trajectories'
  assert_contains 'fast reliability emits first progress event' "$(cat "$stderr_file")" $'CLAWBOX_PROGRESS\t1\t3\t01-tool-reliability\titeration 1'
  assert_contains 'fast reliability emits final progress event' "$(cat "$stderr_file")" $'CLAWBOX_PROGRESS\t3\t3\t01-tool-reliability\titeration 3'

  install_fake_openclaw
  stderr_file="$TEMP_DIR/multi-record-full.stderr"
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" \
    CLAWBOX_QUALIFY_RUN_ID='multi-record-full-pass' \
    CLAWBOX_FAKE_OPENCLAW_TRAJECTORY_PRELUDE=true \
    bash "$ROOT_DIR/vm/qualification/runner.sh" --profile full --scenario 01-tool-reliability --json 2>"$stderr_file")"
  status=$?
  set -e
  assert_equals 'full reliability with multi-record trajectories exits success' "$status" '0'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['overallStatus']=='PASS'
assert data['scenarios'][0]['metrics']['totalIterations']==10
assert len(data['scenarios'][0]['metrics']['iterations'])==10
PY
  pass 'full reliability serializes ten iterations from multi-record trajectories'
  assert_contains 'full reliability emits final progress event' "$(cat "$stderr_file")" $'CLAWBOX_PROGRESS\t10\t10\t01-tool-reliability\titeration 10'
}

test_vm_progress_events_cover_profiles_and_scenarios() {
  local output status=0 stderr_file="$TEMP_DIR/progress-fast-suite.stderr"
  install_fake_openclaw
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='progress-fast-suite' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --json 2>"$stderr_file")"
  status=$?
  set -e
  assert_equals 'fast suite with progress exits success' "$status" '0'
  assert_contains 'fast suite progress total is seven' "$(cat "$stderr_file")" $'CLAWBOX_PROGRESS\t7\t7\t03-code-repair\tcompleted'
  assert_contains 'fast workflow progress includes grounded-read' "$(cat "$stderr_file")" $'CLAWBOX_PROGRESS\t5\t7\t02-tool-workflows\tgrounded-read'
  python3 - "$stderr_file" <<'PY'
import sys
completed=[]
with open(sys.argv[1], encoding='utf-8') as fh:
    for line in fh:
        if line.startswith('CLAWBOX_PROGRESS\t'):
            _, c, t, *_ = line.rstrip('\n').split('\t')
            c, t = int(c), int(t)
            assert c <= t
            completed.append(c)
assert completed == sorted(completed)
assert completed[-1] == 7
PY
  pass 'fast suite progress is monotonic and bounded'

  install_fake_openclaw
  stderr_file="$TEMP_DIR/progress-full-suite.stderr"
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='progress-full-suite' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile full --json 2>"$stderr_file")"
  status=$?
  set -e
  assert_equals 'full suite with progress exits success' "$status" '0'
  assert_contains 'full suite progress total is sixteen' "$(cat "$stderr_file")" $'CLAWBOX_PROGRESS\t16\t16\t03-code-repair\tcompleted'

  install_fake_openclaw
  stderr_file="$TEMP_DIR/progress-fast-workflows.stderr"
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='progress-fast-workflows' bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --scenario 02-tool-workflows --json 2>"$stderr_file")"
  status=$?
  set -e
  assert_equals 'fast workflows selected scenario exits success' "$status" '0'
  assert_contains 'fast workflows selected scenario total is three' "$(cat "$stderr_file")" $'CLAWBOX_PROGRESS\t3\t3\t02-tool-workflows\tabsence-check'

  install_fake_openclaw
  stderr_file="$TEMP_DIR/progress-code-repair.stderr"
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='progress-code-repair' bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 03-code-repair --json 2>"$stderr_file")"
  status=$?
  set -e
  assert_equals 'code repair selected scenario exits success' "$status" '0'
  assert_contains 'code repair selected scenario total is one' "$(cat "$stderr_file")" $'CLAWBOX_PROGRESS\t1\t1\t03-code-repair\tcompleted'
}

test_tool_reliability_model_failures_continue_all_iterations() {
  local output status=0
  install_fake_openclaw
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" \
    CLAWBOX_QUALIFY_RUN_ID='reliability-fail-continues' \
    CLAWBOX_FAKE_OPENCLAW_TRAJECTORY_PRELUDE=true \
    CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=0 \
    CLAWBOX_FAKE_OPENCLAW_FABRICATE=true \
    bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --scenario 01-tool-reliability --json)"
  status=$?
  set -e
  assert_equals 'fast reliability model failures return model failure' "$status" '1'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
scenario=data['scenarios'][0]
assert data['overallStatus']=='FAIL'
assert 0 < data['score'] < 80
assert scenario['metrics']['totalIterations']==3
assert len(scenario['metrics']['iterations'])==3
assert all(item['status']=='FAIL' for item in scenario['metrics']['iterations'])
assert scenario['metrics']['requiredToolIterations'] == 0
assert scenario['metrics']['fileCorrectIterations'] == 0
assert scenario['metrics']['replyCorrectIterations'] == 3
assert scenario['metrics']['groundedIterations'] == 0
assert all(item['error']['message'] == '' for item in scenario['metrics']['iterations'])
assert all(item['error']['type'] is None for item in scenario['metrics']['iterations'])
PY
  pass 'model-attributable reliability failures continue through all fast iterations with valid empty error objects'
}

test_qualify_runner_records_null_git_provenance_outside_checkout() {
  local suite_copy="$TEMP_DIR/suite-copy" output status=0
  install_fake_openclaw
  mkdir -p "$suite_copy"
  cp -R "$ROOT_DIR/vm/qualification"/. "$suite_copy"/
  set +e; output="$(cd "$suite_copy" && PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='outside-git' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 ./runner.sh --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'qualification runner works outside a Git checkout' "$status" '0'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['clawbox']['commit'] is None
assert data['clawbox']['dirty'] is None
assert data['suite']['checksum']
PY
  pass 'outside checkout records null git provenance and suite checksum'
}

test_qualify_command_self_heals_without_setup() {
  local env_file="$TEMP_DIR/qualify.env" output status=0
  local remote_root="$TEMP_DIR/fake-remote" remote_runtime="$TEMP_DIR/fake remote runtime" remote_home='' log_file="$TEMP_DIR/self-heal.log"
  remote_home="$remote_root/home/vm-user"
  setup_mock_bin_dir
  mkdir -p "$remote_root" "$remote_runtime" "$remote_home"
  cat > "$env_file" <<EOF_ENV
VM_HOST="vm-user@192.168.64.8"
VM_RUNTIME_PATH="$remote_runtime"
LLAMA_BASE_URL="http://127.0.0.1:11434/v1"
MODEL_PATH="/Users/Shared/AI-Models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
EOF_ENV
  export CLAWBOX_FAKE_REMOTE_ROOT="$remote_root"
  export CLAWBOX_FAKE_REMOTE_HOME="$remote_home"
  export CLAWBOX_FAKE_REMOTE_RUNTIME="$remote_runtime"
  export CLAWBOX_HOST_REPO_ROOT="$ROOT_DIR"
  export CLAWBOX_FAKE_SSH_LOG="$log_file"
  mkdir -p "$remote_home/.openclaw/workspace/.clawbox/qualification/runs/old-run-a" \
    "$remote_home/.openclaw/workspace/.clawbox/qualification/runs/old-run-b"
  printf 'keep-a\n' > "$remote_home/.openclaw/workspace/.clawbox/qualification/runs/old-run-a/sentinel.txt"
  printf 'keep-b\n' > "$remote_home/.openclaw/workspace/.clawbox/qualification/runs/old-run-b/sentinel.txt"
  write_mock_command curl '#!/bin/bash
printf "{\"data\":[{\"id\":\"/Users/Shared/AI-Models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf\"}]}\n"
exit 0
'
  write_mock_command scp '#!/bin/bash
set -euo pipefail
src=""
dest=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -*) shift ;;
    *) if [ -z "$src" ]; then src="$1"; else dest="$1"; fi; shift ;;
  esac
done
rel="${dest#*:}"
case "$rel" in
  ~/*) out="$CLAWBOX_FAKE_REMOTE_HOME/${rel#~/}" ;;
  .clawbox/*) out="$CLAWBOX_FAKE_REMOTE_HOME/$rel" ;;
  *) out="$CLAWBOX_FAKE_REMOTE_ROOT/$rel" ;;
esac
mkdir -p "$(dirname "$out")"
cp "$src" "$out"
'
  write_mock_command ssh '#!/bin/bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|-o) if [ "$1" = "-o" ]; then shift 2; else shift; fi ;;
    *) break ;;
  esac
done
host="$1"
shift
command="$*"
printf "%s\n" "$command" >> "$CLAWBOX_FAKE_SSH_LOG"
if [ "$command" = "echo ok" ]; then exit 0; fi
if [[ "$command" == mkdir\ -p\ ~/.clawbox/tmp* ]]; then exit 0; fi
if [[ "$command" == rm\ -f* ]]; then exit 0; fi
if [[ "$command" == *"tar -C"* ]]; then
  if [[ "$command" == *"$CLAWBOX_HOST_REPO_ROOT"* ]]; then
    printf "host repository path leaked into remote publish command\n" >&2
    exit 71
  fi
  rm -rf "$CLAWBOX_FAKE_REMOTE_RUNTIME/qualification"
  mkdir -p "$CLAWBOX_FAKE_REMOTE_RUNTIME"
  tar -C "$CLAWBOX_FAKE_REMOTE_RUNTIME" -xf -
  test -x "$CLAWBOX_FAKE_REMOTE_RUNTIME/qualification/runner.sh"
  test -x "$CLAWBOX_FAKE_REMOTE_RUNTIME/qualification/scenarios/01-tool-reliability.sh"
  printf "PUBLISH\n" >> "$CLAWBOX_FAKE_SSH_LOG"
  exit 0
fi
if [[ "$command" == *"runner.sh"* ]]; then
  printf "RUNNER\n" >> "$CLAWBOX_FAKE_SSH_LOG"
  [[ "$command" == *"./runner.sh --profile full --scenario 01-tool-reliability --json"* ]]
  [[ "$command" == *"CLAWBOX_QUALIFY_MODEL_ALIAS=clawbox/local"* ]]
  [[ "$command" == *"CLAWBOX_QUALIFY_MODEL_CONFIGURED=Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"* ]]
  [[ "$command" == *"CLAWBOX_QUALIFY_MODEL_RUNNING=Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"* ]]
  [[ "$command" == *"CLAWBOX_QUALIFY_PROFILE_ID=full"* ]]
  [[ "$command" == *"CLAWBOX_QUALIFY_SUITE_CHECKSUM="* ]]
  [[ "$command" == *"CLAWBOX_QUALIFY_CLAWBOX_COMMIT="* ]]
  printf "CLAWBOX_PROGRESS\t1\t10\t01-tool-reliability\titeration 1\n" >&2
  printf "remote diagnostic line\n" >&2
  printf "CLAWBOX_PROGRESS\t10\t10\t01-tool-reliability\titeration 10\n" >&2
  printf "{\"schemaVersion\":\"1\",\"runId\":\"self-heal\",\"profile\":{\"id\":\"full\",\"name\":\"Full\"},\"coverage\":{\"profile\":\"full\",\"scenariosRun\":1,\"reliabilityIterations\":10,\"workflowCases\":0},\"model\":{\"alias\":\"clawbox/local\",\"configured\":\"Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf\",\"running\":\"Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf\"},\"overallStatus\":\"PASS\",\"score\":100,\"categories\":{},\"warnings\":[],\"failures\":[],\"scenarios\":[{\"scenarioId\":\"01-tool-reliability\",\"status\":\"PASS\"}],\"artifactDirectory\":\"runs/self-heal\"}\n"
  exit 0
fi
if [[ "$command" == *"zsh -l"* ]]; then
  remote_path="${command#*zsh -l }"
  remote_path="${remote_path%\"}"
  remote_path="${remote_path#\"}"
  remote_path="${remote_path#\$HOME/}"
  script="$CLAWBOX_FAKE_REMOTE_HOME/$remote_path"
  if grep -Fq "target_dir=" "$script"; then
    if grep -Fq "$CLAWBOX_HOST_REPO_ROOT" "$script"; then
      printf "host repository path leaked into remote installer\n" >&2
      exit 72
    fi
    HOME="$CLAWBOX_FAKE_REMOTE_HOME" zsh "$script"
    test -x "$CLAWBOX_FAKE_REMOTE_HOME/.openclaw/workspace/.clawbox/qualification/current/runner.sh"
    test -x "$CLAWBOX_FAKE_REMOTE_HOME/.openclaw/workspace/.clawbox/qualification/current/scenarios/01-tool-reliability.sh"
    test -f "$CLAWBOX_FAKE_REMOTE_HOME/.openclaw/workspace/.clawbox/qualification/runs/old-run-a/sentinel.txt"
    test -f "$CLAWBOX_FAKE_REMOTE_HOME/.openclaw/workspace/.clawbox/qualification/runs/old-run-b/sentinel.txt"
    printf "INSTALL\n" >> "$CLAWBOX_FAKE_SSH_LOG"
    exit 0
  fi
  if grep -Fq ".clawbox-manifest.json" "$script"; then exit 1; fi
  if grep -Fq "openclaw config get agents.defaults.model.primary" "$script"; then printf "clawbox/local\n"; exit 0; fi
  if grep -Fq "command -v openclaw" "$script"; then exit 0; fi
fi
exit 0
'
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" bash "$ROOT_DIR/scripts/qualify.sh" --json --scenario 01-tool-reliability 2>"$TEMP_DIR/self-heal.stderr")"
  status=$?
  set -e
  assert_equals 'qualify self-heal command exits success without mocked setup' "$status" '0'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data["overallStatus"] == "PASS"
assert data["model"]["alias"] == "clawbox/local"
assert data["model"]["configured"] == "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
assert data["model"]["running"] == "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
assert data["profile"]["id"] == "full"
assert data["scenarios"][0]["scenarioId"] == "01-tool-reliability"
PY
  pass 'qualify self-heal stdout remains JSON'
  assert_contains 'qualify self-heal publishes missing suite' "$(cat "$log_file")" 'PUBLISH'
  assert_contains 'qualify self-heal installs missing suite' "$(cat "$log_file")" 'INSTALL'
  assert_contains 'qualify self-heal executes requested scenario' "$(cat "$log_file")" 'RUNNER'
  assert_contains 'qualify self-heal passes default full profile to remote runner' "$(cat "$log_file")" 'CLAWBOX_QUALIFY_PROFILE_ID=full'
  assert_contains 'qualify self-heal passes suite checksum to remote runner' "$(cat "$log_file")" 'CLAWBOX_QUALIFY_SUITE_CHECKSUM='
  assert_contains 'qualify self-heal passes ClawBox commit to remote runner' "$(cat "$log_file")" 'CLAWBOX_QUALIFY_CLAWBOX_COMMIT='
  assert_contains 'qualify self-heal progress stays on stderr' "$(cat "$TEMP_DIR/self-heal.stderr")" 'Publishing qualification suite to VM'
  assert_contains 'json mode progress is line-oriented on stderr' "$(cat "$TEMP_DIR/self-heal.stderr")" 'Qualification progress: 1/10'
  assert_contains 'json mode progress reaches final unit on stderr' "$(cat "$TEMP_DIR/self-heal.stderr")" 'Qualification progress: 10/10'
  assert_not_contains 'json stdout is uncontaminated by progress protocol' "$output" 'CLAWBOX_PROGRESS'
  assert_not_contains 'json stdout is uncontaminated by progress text' "$output" 'Qualification progress'
  assert_contains 'qualify reports actual running model separately from alias' "$(cat "$TEMP_DIR/self-heal.stderr")" 'Model under qualification: Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
  assert_contains 'qualify reports OpenClaw alias separately' "$(cat "$TEMP_DIR/self-heal.stderr")" 'OpenClaw alias: clawbox/local'
  assert_equals 'qualify self-heal preserves first historical run sentinel' "$(cat "$remote_home/.openclaw/workspace/.clawbox/qualification/runs/old-run-a/sentinel.txt")" 'keep-a'
  assert_equals 'qualify self-heal preserves second historical run sentinel' "$(cat "$remote_home/.openclaw/workspace/.clawbox/qualification/runs/old-run-b/sentinel.txt")" 'keep-b'
}

test_qualify_human_output_is_polished() {
  local env_file="$TEMP_DIR/qualify-human.env" output suite_output status=0
  local remote_root="$TEMP_DIR/human-remote" remote_home="$TEMP_DIR/human-remote/home" log_file="$TEMP_DIR/human.log"
  setup_mock_bin_dir
  mkdir -p "$remote_root" "$remote_home"
  cat > "$env_file" <<EOF_ENV
VM_HOST="vm-user@192.168.64.8"
VM_RUNTIME_PATH="$TEMP_DIR/human-runtime"
LLAMA_BASE_URL="http://127.0.0.1:11434/v1"
MODEL_PATH="/Users/Shared/AI-Models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
EOF_ENV
  export CLAWBOX_FAKE_REMOTE_HOME="$remote_home"
  export CLAWBOX_FAKE_SSH_LOG="$log_file"
  write_mock_command curl '#!/bin/bash
printf "{\"data\":[{\"id\":\"/Users/Shared/AI-Models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf\"}]}\n"
exit 0
'
  write_mock_command scp '#!/bin/bash
set -euo pipefail
src=""; dest=""
while [ "$#" -gt 0 ]; do case "$1" in -*) shift ;; *) if [ -z "$src" ]; then src="$1"; else dest="$1"; fi; shift ;; esac; done
rel="${dest#*:}"; rel="${rel#~/}"
mkdir -p "$CLAWBOX_FAKE_REMOTE_HOME/$(dirname "$rel")"
cp "$src" "$CLAWBOX_FAKE_REMOTE_HOME/$rel"
'
  write_mock_command ssh '#!/bin/bash
set -euo pipefail
while [ "$#" -gt 0 ]; do case "$1" in -n|-o) if [ "$1" = "-o" ]; then shift 2; else shift; fi ;; *) break ;; esac; done
host="$1"; shift; command="$*"
printf "%s\n" "$command" >> "$CLAWBOX_FAKE_SSH_LOG"
if [ "$command" = "echo ok" ]; then exit 0; fi
if [[ "$command" == mkdir\ -p\ ~/.clawbox/tmp* ]]; then exit 0; fi
if [[ "$command" == rm\ -f* ]]; then exit 0; fi
if [[ "$command" == *"runner.sh"* ]]; then
  if [[ "$command" == *"01-tool-reliability"* ]]; then
    printf "CLAWBOX_PROGRESS\t1\t10\t01-tool-reliability\titeration 1\n" >&2
    printf "not a progress line\n" >&2
    printf "CLAWBOX_PROGRESS\t10\t10\t01-tool-reliability\titeration 10\n" >&2
  else
    printf "CLAWBOX_PROGRESS\t3\t16\t01-tool-reliability\titeration 3\n" >&2
    printf "CLAWBOX_PROGRESS\t11\t16\t02-tool-workflows\texact-output\n" >&2
    printf "CLAWBOX_PROGRESS\t16\t16\t03-code-repair\tcompleted\n" >&2
  fi
  printf "{\"schemaVersion\":\"1\",\"runId\":\"human-run\",\"startedAt\":\"2026-07-15T13:03:52Z\",\"completedAt\":\"2026-07-15T13:24:17Z\",\"durationSeconds\":1225,\"completed\":true,\"suite\":{\"schemaVersion\":\"1\",\"checksum\":\"suite-checksum\"},\"clawbox\":{\"commit\":\"abc123\",\"dirty\":false},\"profile\":{\"id\":\"full\",\"name\":\"Full\"},\"coverage\":{\"profile\":\"full\",\"scenariosRun\":1,\"reliabilityIterations\":10,\"workflowCases\":0},\"model\":{\"alias\":\"clawbox/local\",\"configured\":\"Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf\",\"running\":\"Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf\"},\"overallStatus\":\"WARNING\",\"score\":97,\"categories\":{},\"warnings\":[\"expected 1 efficient tool call, observed 2\"],\"failures\":[],\"scenarios\":[{\"scenarioId\":\"01-tool-reliability\",\"scenarioName\":\"Tool-calling reliability\",\"status\":\"WARNING\",\"score\":97,\"durationSeconds\":714,\"metrics\":{\"totalIterations\":10,\"correctIterations\":10,\"efficientIterations\":9,\"averageToolCalls\":1.1},\"warnings\":[\"expected 1 efficient tool call, observed 2\"],\"failures\":[]}],\"artifactDirectory\":\"runs/human-run\"}\n"
  exit 0
fi
if [[ "$command" == *"zsh -l"* ]]; then
  remote_path="${command#*zsh -l }"; remote_path="${remote_path%\"}"; remote_path="${remote_path#\"}"; remote_path="${remote_path#\$HOME/}"
  script="$CLAWBOX_FAKE_REMOTE_HOME/$remote_path"
  if grep -Fq ".clawbox-manifest.json" "$script"; then exit 0; fi
  if grep -Fq "openclaw config get agents.defaults.model.primary" "$script"; then printf "clawbox/local\n"; exit 0; fi
  if grep -Fq "command -v openclaw" "$script"; then exit 0; fi
fi
exit 0
'
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" bash "$ROOT_DIR/scripts/qualify.sh" --scenario 01-tool-reliability 2>&1)"
  status=$?
  set -e
  assert_equals 'human qualify warning exits success' "$status" '0'
  assert_contains 'human output checks host endpoint with final marker' "$output" 'Checking host inference endpoint... ✓'
  assert_contains 'human output checks configured/running model match' "$output" 'Checking configured model matches running model... ✓'
  assert_not_contains 'compact progress has no blank line between completed operations' "$output" $'Checking host inference endpoint... ✓\n\nChecking VM SSH access'
  assert_contains 'human output shows selected scenario running progress' "$output" 'Running 01-tool-reliability qualification...'
  assert_contains 'human output shows line-oriented qualification progress' "$output" 'Qualification progress: 1/10'
  assert_contains 'human output shows final progress count' "$output" '[████████████████] 10/10 !'
  assert_contains 'human output shows compact model identity' "$output" 'Model under qualification: Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
  assert_contains 'human output shows OpenClaw alias' "$output" 'OpenClaw alias: clawbox/local'
  assert_contains 'human output shows qualification profile metadata' "$output" 'Qualification profile: Full'
  assert_contains 'human output separates checks from model metadata' "$output" $'Checking configured model matches running model... ✓\n\nModel under qualification:'
  assert_contains 'human output separates metadata from execution group once' "$output" $'Qualification profile: Full\n\nRunning 01-tool-reliability qualification'
  assert_not_contains 'human output does not over-separate metadata from execution group' "$output" $'Qualification profile: Full\n\n\nRunning 01-tool-reliability qualification'
  assert_not_contains 'human output omits redundant configured model line' "$output" 'Configured model:'
  assert_not_contains 'human output omits redundant running model line' "$output" 'Running model:'
  assert_contains 'human report uses shared section heading' "$output" ' > Model Qualification Report'
  assert_contains 'human report has one blank line before heading' "$output" $'Running 01-tool-reliability qualification... [████████████████] 10/10 !\n\n-----------------------------------------'
  assert_not_contains 'human report no longer prints model row' "$output" 'Model: Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf'
  assert_contains 'human report shows scenario id' "$output" '01-tool-reliability'
  assert_contains 'human report shows selected profile' "$output" 'Profile'
  assert_contains 'human report shows coverage for selected profile' "$output" 'Full profile'
  assert_contains 'human report shows scenario score' "$output" 'Scenario Score'
  assert_contains 'human report shows scenario duration' "$output" 'Duration'
  assert_contains 'human report formats long duration compactly' "$output" '11m 54s'
  assert_contains 'human report shows correct iterations' "$output" 'Correct iterations'
  assert_contains 'human report formats average tool calls consistently' "$output" 'Average tool calls'
  assert_contains 'human report shows one-decimal average tool call value' "$output" '1.1'
  assert_contains 'human report explains score deduction' "$output" 'Deductions reflect the warnings listed below.'
  assert_contains 'human report exposes warning reason' "$output" 'expected 1 efficient tool call, observed 2'
  assert_not_contains 'human report does not duplicate warning inline' "$output" 'Warning ........................'
  if [ "$(printf '%s\n' "$output" | grep -F 'expected 1 efficient tool call, observed 2' | wc -l | tr -d '[:space:]')" = '1' ]; then
    pass 'human report shows each warning once'
  else
    fail 'human report shows each warning once'
  fi
  assert_contains 'human report shows overall warning result' "$output" 'Overall Result'
  assert_contains 'human report identifies run id' "$output" 'Run ID'
  assert_contains 'human report labels artifacts compactly' "$output" 'Artifacts'

  set +e
  suite_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" bash "$ROOT_DIR/scripts/qualify.sh" 2>&1)"
  status=$?
  set -e
  assert_equals 'human qualify full-suite warning exits success' "$status" '0'
  assert_contains 'human output shows complete suite running progress' "$suite_output" 'Running full model qualification...'
  assert_contains 'human output shows complete suite progress total' "$suite_output" '[████████████████] 16/16 !'
}

test_qualify_renders_valid_remote_results_before_returning_status() {
  local env_file="$TEMP_DIR/qualify-render.env" output status=0
  local remote_home="$TEMP_DIR/render-remote/home" log_file="$TEMP_DIR/render.log"
  setup_mock_bin_dir
  mkdir -p "$remote_home"
  cat > "$env_file" <<EOF_ENV
VM_HOST="vm-user@192.168.64.8"
VM_RUNTIME_PATH="$TEMP_DIR/render-runtime"
LLAMA_BASE_URL="http://127.0.0.1:11434/v1"
MODEL_PATH="/Users/Shared/AI-Models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
EOF_ENV
  export CLAWBOX_FAKE_REMOTE_HOME="$remote_home"
  export CLAWBOX_FAKE_SSH_LOG="$log_file"
  write_mock_command curl '#!/bin/bash
printf "{\"data\":[{\"id\":\"/Users/Shared/AI-Models/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf\"}]}\n"
exit 0
'
  write_mock_command scp '#!/bin/bash
set -euo pipefail
src=""; dest=""
while [ "$#" -gt 0 ]; do case "$1" in -*) shift ;; *) if [ -z "$src" ]; then src="$1"; else dest="$1"; fi; shift ;; esac; done
rel="${dest#*:}"; rel="${rel#~/}"
mkdir -p "$CLAWBOX_FAKE_REMOTE_HOME/$(dirname "$rel")"
cp "$src" "$CLAWBOX_FAKE_REMOTE_HOME/$rel"
'
  write_mock_command ssh '#!/bin/bash
set -euo pipefail
while [ "$#" -gt 0 ]; do case "$1" in -n|-o) if [ "$1" = "-o" ]; then shift 2; else shift; fi ;; *) break ;; esac; done
host="$1"; shift; command="$*"
printf "%s\n" "$command" >> "$CLAWBOX_FAKE_SSH_LOG"
if [ "$command" = "echo ok" ]; then exit 0; fi
if [[ "$command" == mkdir\ -p\ ~/.clawbox/tmp* ]]; then exit 0; fi
if [[ "$command" == rm\ -f* ]]; then exit 0; fi
if [[ "$command" == *"runner.sh"* ]]; then
  printf "CLAWBOX_PROGRESS\t1\t10\t01-tool-reliability\titeration 1\n" >&2
  printf "CLAWBOX_PROGRESS\t10\t10\t01-tool-reliability\titeration 10\n" >&2
  if [ "${CLAWBOX_FAKE_REMOTE_MALFORMED_AGGREGATE:-false}" = true ]; then
    printf "not-json\n"
    exit 0
  fi
  status="${CLAWBOX_FAKE_REMOTE_OVERALL_STATUS:-PASS}"
  score="${CLAWBOX_FAKE_REMOTE_SCORE:-100}"
  failure="${CLAWBOX_FAKE_REMOTE_FAILURE:-iteration 3 failed critical assertions}"
  warning="${CLAWBOX_FAKE_REMOTE_WARNING:-expected 1 efficient tool call, observed 2}"
  python3 - "$status" "$score" "$failure" "$warning" <<PY
import json, sys
status, score_arg, failure, warning = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
score = None if score_arg == "null" else int(score_arg)
scenario_status = status if status in ("FAIL", "ERROR", "WARNING") else "PASS"
data = {
  "schemaVersion":"1","runId":"render-run","startedAt":"2026-07-15T13:03:52Z","completedAt":"2026-07-15T13:24:17Z","durationSeconds":1225,"completed": status != "ERROR",
  "suite":{"schemaVersion":"1","checksum":"suite-checksum"},"clawbox":{"commit":"abc123","dirty":False},
  "profile":{"id":"full","name":"Full"},"coverage":{"profile":"full","scenariosRun":1,"reliabilityIterations":10,"workflowCases":0},
  "model":{"alias":"clawbox/local","configured":"Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf","running":"Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"},
  "overallStatus":status,"score":score,"scoreComplete": score is not None,"categories":{},"warnings":[],"failures":[],"scenarios":[{"scenarioId":"01-tool-reliability","scenarioName":"Tool-calling reliability","status":scenario_status,"score":score,"durationSeconds":714,"metrics":{"totalIterations":10,"correctIterations":6,"efficientIterations":6,"averageToolCalls":1.0},"warnings":[],"failures":[]}],
  "artifactDirectory":"runs/render-run"
}
if status == "WARNING":
    data["warnings"].append(warning)
    data["scenarios"][0]["warnings"].append(warning)
if status in ("FAIL", "ERROR"):
    data["failures"].append(failure)
    data["scenarios"][0]["failures"].append(failure)
print(json.dumps(data))
PY
  exit "${CLAWBOX_FAKE_REMOTE_EXIT_STATUS:-0}"
fi
if [[ "$command" == *"zsh -l"* ]]; then
  remote_path="${command#*zsh -l }"; remote_path="${remote_path%\"}"; remote_path="${remote_path#\"}"; remote_path="${remote_path#\$HOME/}"
  script="$CLAWBOX_FAKE_REMOTE_HOME/$remote_path"
  if grep -Fq ".clawbox-manifest.json" "$script"; then exit 0; fi
  if grep -Fq "openclaw config get agents.defaults.model.primary" "$script"; then printf "clawbox/local\n"; exit 0; fi
  if grep -Fq "command -v openclaw" "$script"; then exit 0; fi
fi
exit 0
'

  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" CLAWBOX_FAKE_REMOTE_OVERALL_STATUS=PASS CLAWBOX_FAKE_REMOTE_SCORE=100 CLAWBOX_FAKE_REMOTE_EXIT_STATUS=0 bash "$ROOT_DIR/scripts/qualify.sh" --scenario 01-tool-reliability 2>&1)"
  status=$?
  set -e
  assert_equals 'remote exit 0 PASS aggregate returns success' "$status" '0'
  assert_contains 'remote exit 0 PASS renders report' "$output" 'Model Qualification Report'
  assert_contains 'remote exit 0 PASS report shows PASS' "$output" 'PASS'

  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" CLAWBOX_FAKE_REMOTE_OVERALL_STATUS=WARNING CLAWBOX_FAKE_REMOTE_SCORE=97 CLAWBOX_FAKE_REMOTE_EXIT_STATUS=0 bash "$ROOT_DIR/scripts/qualify.sh" --scenario 01-tool-reliability 2>&1)"
  status=$?
  set -e
  assert_equals 'remote exit 0 WARNING aggregate returns success' "$status" '0'
  assert_contains 'remote exit 0 WARNING renders report' "$output" 'Model Qualification Report'
  assert_contains 'remote exit 0 WARNING report shows warning reason' "$output" 'expected 1 efficient tool call'

  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" CLAWBOX_FAKE_REMOTE_OVERALL_STATUS=FAIL CLAWBOX_FAKE_REMOTE_SCORE=60 CLAWBOX_FAKE_REMOTE_EXIT_STATUS=1 bash "$ROOT_DIR/scripts/qualify.sh" --scenario 01-tool-reliability 2>&1)"
  status=$?
  set -e
  assert_equals 'remote exit 1 FAIL aggregate returns model failure after rendering' "$status" '1'
  assert_contains 'remote exit 1 FAIL renders full report before exit' "$output" 'Model Qualification Report'
  assert_contains 'remote exit 1 FAIL report keeps successful report fields' "$output" '01-tool-reliability'
  assert_contains 'remote exit 1 FAIL report shows failure reason' "$output" 'iteration 3 failed critical assertions'
  assert_contains 'remote exit 1 FAIL progress uses non-success marker' "$output" 'Running 01-tool-reliability qualification... [████████████████] 10/10 !'

  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" CLAWBOX_FAKE_REMOTE_OVERALL_STATUS=FAIL CLAWBOX_FAKE_REMOTE_SCORE=80 CLAWBOX_FAKE_REMOTE_EXIT_STATUS=1 CLAWBOX_FAKE_REMOTE_FAILURE='iteration 1: final response mismatch; expected "DONE", received "Done."' bash "$ROOT_DIR/scripts/qualify.sh" --scenario 01-tool-reliability 2>&1)"
  status=$?
  set -e
  assert_equals 'remote reply mismatch aggregate returns model failure after rendering' "$status" '1'
  assert_contains 'remote reply mismatch report shows expected actual reply' "$output" 'expected "DONE", received "Done."'

  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" CLAWBOX_FAKE_REMOTE_OVERALL_STATUS=ERROR CLAWBOX_FAKE_REMOTE_SCORE=null CLAWBOX_FAKE_REMOTE_EXIT_STATUS=2 bash "$ROOT_DIR/scripts/qualify.sh" --scenario 01-tool-reliability 2>&1)"
  status=$?
  set -e
  assert_equals 'remote exit 2 valid ERROR aggregate returns infrastructure error after rendering' "$status" '2'
  assert_contains 'remote exit 2 ERROR renders diagnostic report' "$output" 'Model Qualification Report'
  assert_contains 'remote exit 2 ERROR report shows failure reason' "$output" 'iteration 3 failed critical assertions'
  assert_contains 'remote exit 2 ERROR report shows unrated score' "$output" 'Unrated'

  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" CLAWBOX_FAKE_REMOTE_MALFORMED_AGGREGATE=true CLAWBOX_FAKE_REMOTE_EXIT_STATUS=0 bash "$ROOT_DIR/scripts/qualify.sh" --scenario 01-tool-reliability 2>&1)"
  status=$?
  set -e
  assert_equals 'malformed aggregate remains infrastructure error' "$status" '2'
  assert_contains 'malformed aggregate reports infrastructure failure' "$output" 'VM qualification runner did not produce valid aggregate JSON.'
}

test_qualify_model_mismatch_stops_before_publish() {
  local env_file="$TEMP_DIR/qualify-mismatch.env" stdout_file="$TEMP_DIR/mismatch.json" stderr_file="$TEMP_DIR/mismatch.progress" status=0
  local remote_home="$TEMP_DIR/mismatch-remote/home" log_file="$TEMP_DIR/mismatch.log"
  setup_mock_bin_dir
  mkdir -p "$remote_home"
  cat > "$env_file" <<EOF_ENV
VM_HOST="vm-user@192.168.64.8"
VM_RUNTIME_PATH="$TEMP_DIR/mismatch-runtime"
LLAMA_BASE_URL="http://127.0.0.1:11434/v1"
MODEL_PATH="/Users/Shared/AI-Models/Configured.gguf"
OPENCLAW_PROVIDER_NAME="clawbox"
OPENCLAW_DEFAULT_MODEL="local"
EOF_ENV
  export CLAWBOX_FAKE_REMOTE_HOME="$remote_home"
  export CLAWBOX_FAKE_SSH_LOG="$log_file"
  : > "$log_file"
  write_mock_command curl '#!/bin/bash
printf "{\"data\":[{\"id\":\"/Users/Shared/AI-Models/Running.gguf\"}]}\n"
exit 0
'
  write_mock_command scp '#!/bin/bash
set -euo pipefail
src=""; dest=""
while [ "$#" -gt 0 ]; do case "$1" in -*) shift ;; *) if [ -z "$src" ]; then src="$1"; else dest="$1"; fi; shift ;; esac; done
rel="${dest#*:}"; rel="${rel#~/}"
mkdir -p "$CLAWBOX_FAKE_REMOTE_HOME/$(dirname "$rel")"
cp "$src" "$CLAWBOX_FAKE_REMOTE_HOME/$rel"
'
  write_mock_command ssh '#!/bin/bash
set -euo pipefail
while [ "$#" -gt 0 ]; do case "$1" in -n|-o) if [ "$1" = "-o" ]; then shift 2; else shift; fi ;; *) break ;; esac; done
host="$1"; shift; command="$*"
printf "%s\n" "$command" >> "$CLAWBOX_FAKE_SSH_LOG"
if [ "$command" = "echo ok" ]; then exit 0; fi
if [[ "$command" == mkdir\ -p\ ~/.clawbox/tmp* ]]; then exit 0; fi
if [[ "$command" == rm\ -f* ]]; then exit 0; fi
if [[ "$command" == *"tar -C"* ]] || [[ "$command" == *"runner.sh"* ]]; then exit 88; fi
if [[ "$command" == *"zsh -l"* ]]; then
  remote_path="${command#*zsh -l }"; remote_path="${remote_path%\"}"; remote_path="${remote_path#\"}"; remote_path="${remote_path#\$HOME/}"
  script="$CLAWBOX_FAKE_REMOTE_HOME/$remote_path"
  if grep -Fq "openclaw config get agents.defaults.model.primary" "$script"; then printf "clawbox/local\n"; exit 0; fi
  if grep -Fq "command -v openclaw" "$script"; then exit 0; fi
  if grep -Fq ".clawbox-manifest.json" "$script"; then exit 0; fi
fi
exit 0
'
  set +e
  PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_ENV_FILE="$env_file" bash "$ROOT_DIR/scripts/qualify.sh" --json --scenario 01-tool-reliability >"$stdout_file" 2>"$stderr_file"
  status=$?
  set -e
  assert_equals 'model mismatch exits infrastructure error' "$status" '2'
  python3 - "$stdout_file" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as fh:
    data=json.load(fh)
assert data['overallStatus']=='ERROR'
assert data['errorCode']=='MODEL_MISMATCH'
assert data['model']['configured']=='Configured.gguf'
assert data['model']['running']=='Running.gguf'
PY
  pass 'model mismatch stdout remains valid JSON with model details'
  assert_contains 'model mismatch progress shows failed consistency check' "$(cat "$stderr_file")" 'Checking configured model matches running model... ✗'
  assert_contains 'model mismatch stderr is actionable' "$(cat "$stderr_file")" 'Resolve the model inconsistency before running qualification.'
  assert_not_contains 'model mismatch prevents publication' "$(cat "$log_file")" 'tar -C'
  assert_not_contains 'model mismatch prevents remote runner execution' "$(cat "$log_file")" 'runner.sh'
  assert_not_contains 'model mismatch JSON stdout has no progress' "$(cat "$stdout_file")" 'Checking host inference endpoint'
  assert_not_contains 'model mismatch JSON stdout has no spinner marker' "$(cat "$stdout_file")" '✓'
}

test_tool_reliability_extra_calls_warn_but_do_not_fail() {
  local output status=0
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='warning-run' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=2 bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'extra verification calls warning exits success' "$status" '0'
  assert_contains 'extra tool calls produce warning result' "$output" '"overallStatus": "WARNING"'
  assert_contains 'tool reliability reports efficient rate separately' "$output" '"efficientCallRate"'
}

test_tool_reliability_reply_mismatch_is_precise_failure() {
  local output status=0 warning_output fabricated_output
  install_fake_openclaw
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='reply-mismatch-run' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_REPLY='Done.' bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"
  status=$?
  set -e
  assert_equals 'reply mismatch exits model failure' "$status" '1'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
scenario=data['scenarios'][0]
iteration=scenario['metrics']['iterations'][0]
assert data['overallStatus']=='FAIL'
assert scenario['score'] == 80
assert scenario['metrics']['requiredToolIterations'] == 1
assert scenario['metrics']['fileCorrectIterations'] == 1
assert scenario['metrics']['replyCorrectIterations'] == 0
assert scenario['metrics']['groundedIterations'] == 1
assert iteration['requiredToolInvoked'] is True
assert iteration['fileCorrect'] is True
assert iteration['reply']['expected'] == 'DONE'
assert iteration['reply']['actual'] == 'Done.'
assert iteration['reply']['correct'] is False
assert any('expected "DONE", received "Done."' in item for item in data['failures'])
PY
  pass 'reply mismatch preserves tool and state pass evidence'

  install_fake_openclaw
  warning_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='warning-severity-run' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=2 bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"
  install_fake_openclaw
  fabricated_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='fabricated-severity-run' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=0 CLAWBOX_FAKE_OPENCLAW_FABRICATE=true bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json || true)"
  python3 - "$warning_output" "$output" "$fabricated_output" <<'PY'
import json, sys
warning=json.loads(sys.argv[1])['scenarios'][0]['score']
reply=json.loads(sys.argv[2])['scenarios'][0]['score']
fabricated=json.loads(sys.argv[3])['scenarios'][0]['score']
assert 100 > warning > reply > fabricated
PY
  pass 'score severity ranks warning above reply-only failure above no-tool state failure'
}

test_tool_reliability_fabricated_success_fails() {
  local output status=0
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='fabricated-run' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=0 CLAWBOX_FAKE_OPENCLAW_FABRICATE=true bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'fabricated success exits model failure' "$status" '1'
  assert_contains 'fabricated success reports FAIL' "$output" '"overallStatus": "FAIL"'
}

test_workflow_required_tool_omission_fails() {
  local output status=0 scenario_output artifact_dir
  install_fake_openclaw
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='workflow-zero-tools' CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=0 bash "$ROOT_DIR/vm/qualification/runner.sh" --profile fast --scenario 02-tool-workflows --json)"
  status=$?
  set -e
  assert_equals 'zero-call workflow exits model failure' "$status" '1'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
scenario=data['scenarios'][0]
assert data['overallStatus']=='FAIL'
assert scenario['metrics']['totalCases'] == 3
assert scenario['metrics']['requiredToolCases'] == 0
assert scenario['metrics']['efficientCases'] == 0
assert all(case['status'] == 'FAIL' for case in scenario['metrics']['cases'])
assert any('exact-output: required tool use below expected minimum' in item for item in data['failures'])
assert any(case['case'] == 'exact-output' and case['replyCorrect'] is True and case['requiredToolInvoked'] is False and case['groundingCorrect'] is False for case in scenario['metrics']['cases'])
PY
  pass 'zero-call predictable workflow output is failed as ungrounded required-tool noncompliance'

  install_fake_openclaw
  artifact_dir="$TEMP_DIR/two-step-shortfall"
  set +e
  scenario_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_WORKFLOW_CASES='two-step' CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=1 "$ROOT_DIR/vm/qualification/scenarios/02-tool-workflows.sh" 'two-step-shortfall' "$artifact_dir")"
  status=$?
  set -e
  assert_equals 'two-step shortfall scenario process completes with result JSON' "$status" '0'
  python3 - "$scenario_output" <<'PY'
import json, sys
scenario=json.loads(sys.argv[1])
case=scenario['metrics']['cases'][0]
assert scenario['status'] == 'FAIL'
assert scenario['score'] < 100
assert case['case'] == 'two-step'
assert case['toolCalls'] == 1
assert case['requiredToolInvoked'] is False
assert case['status'] == 'FAIL'
assert any('two-step: required tool use below expected minimum' in item for item in scenario['failures'])
PY
  pass 'fewer-than-required two-step calls fail instead of warning'
}

test_evidence_failures_are_errors() {
  local output status=0
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='missing-traj' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_NO_TRAJECTORY=true bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'missing trajectory exits infrastructure error' "$status" '2'
  assert_contains 'missing trajectory is ERROR' "$output" '"overallStatus": "ERROR"'
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='multiple-traj' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_MULTIPLE_TRAJECTORIES=true bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'multiple trajectories exits infrastructure error' "$status" '2'
  assert_contains 'multiple trajectories are reported' "$output" 'multiple trajectories found'
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='missing-transcript' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_NO_TRANSCRIPT=true bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'missing transcript exits infrastructure error' "$status" '2'
  assert_contains 'missing transcript is reported' "$output" 'transcript missing'
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='malformed-traj' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_MALFORMED_TRAJECTORY=true bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'malformed trajectory exits infrastructure error' "$status" '2'
  assert_contains 'malformed trajectory is reported' "$output" 'malformed trajectory'
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='malformed-transcript' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 CLAWBOX_FAKE_OPENCLAW_MALFORMED_TRANSCRIPT=true bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'malformed transcript exits infrastructure error' "$status" '2'
  assert_contains 'malformed transcript is reported' "$output" 'malformed transcript'
}

test_tool_reliability_captures_agent_error_evidence_and_classifies_it() {
  local output status=0
  install_fake_openclaw
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" \
    CLAWBOX_QUALIFY_RUN_ID='agent-timeout-fail' \
    CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 \
    CLAWBOX_FAKE_OPENCLAW_FINAL_STATUS=error \
    CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=0 \
    CLAWBOX_FAKE_OPENCLAW_FABRICATE=true \
    CLAWBOX_FAKE_OPENCLAW_EXIT_STATUS=1 \
    CLAWBOX_FAKE_OPENCLAW_ERROR_TYPE=timeout \
    CLAWBOX_FAKE_OPENCLAW_ERROR_MESSAGE='model did not complete before timeout' \
    CLAWBOX_FAKE_OPENCLAW_TIMEOUT=true \
    bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"
  status=$?
  set -e
  assert_equals 'model timeout evidence exits model failure' "$status" '1'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
it=data['scenarios'][0]['metrics']['iterations'][0]
assert data['overallStatus']=='FAIL'
assert it['status']=='FAIL'
assert it['openclawExitStatus']==1
assert it['agentStatus']=='error'
assert it['error']['type']=='timeout'
assert it['error']['timeout'] is True
assert 'model did not complete before timeout' in it['error']['message']
assert any('timed out' in item or 'timeout' in item for item in data['failures'])
PY
  pass 'model-attributable agent error captures exit status and timeout evidence'

  install_fake_openclaw
  set +e
  output="$(PATH="$MOCK_BIN_DIR:$PATH" \
    CLAWBOX_QUALIFY_RUN_ID='gateway-error' \
    CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 \
    CLAWBOX_FAKE_OPENCLAW_FINAL_STATUS=error \
    CLAWBOX_FAKE_OPENCLAW_TOOL_COUNT=0 \
    CLAWBOX_FAKE_OPENCLAW_FABRICATE=true \
    CLAWBOX_FAKE_OPENCLAW_EXIT_STATUS=1 \
    CLAWBOX_FAKE_OPENCLAW_ERROR_TYPE=gateway \
    CLAWBOX_FAKE_OPENCLAW_ERROR_MESSAGE='gateway unavailable' \
    bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"
  status=$?
  set -e
  assert_equals 'infrastructure-attributable agent error exits infrastructure error' "$status" '2'
  python3 - "$output" <<'PY'
import json, sys
data=json.loads(sys.argv[1])
assert data['overallStatus']=='ERROR'
assert data['scenarios'][0]['status']=='ERROR'
assert data['scenarios'][0]['metrics']['iterations'][0]['error']['type']=='gateway'
assert any('gateway unavailable' in item for item in data['failures'])
PY
  pass 'infrastructure-attributable agent error is classified as ERROR'
}

test_workflow_cases_and_code_repair_objective_behavior() {
  local workflow_output repair_output status=0
  install_fake_openclaw
  set +e; workflow_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='workflow-run' bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 02-tool-workflows --json)"; status=$?; set -e
  assert_equals 'workflow scenarios pass with fake openclaw' "$status" '0'
  for case_name in exact-output grounded-read absence-check two-step transform; do assert_contains "workflow output includes $case_name" "$workflow_output" "$case_name"; done
  install_fake_openclaw
  set +e; repair_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='repair-run' bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 03-code-repair --json)"; status=$?; set -e
  assert_equals 'code repair passes when only calculator is fixed' "$status" '0'
  assert_contains 'code repair records changed file scope' "$repair_output" ' M calculator.sh'
  assert_contains 'code repair perfect objective pass scores 100' "$repair_output" '"score": 100'
  install_fake_openclaw
  set +e; repair_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='repair-bad-scope' CLAWBOX_FAKE_OPENCLAW_UNRELATED_CHANGE=true bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 03-code-repair --json)"; status=$?; set -e
  assert_equals 'code repair unrelated change exits model failure' "$status" '1'
  assert_contains 'code repair unrelated change reports FAIL' "$repair_output" 'changed files were outside the intended scope'
  install_fake_openclaw
  set +e; repair_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='repair-agent-nonzero' CLAWBOX_FAKE_OPENCLAW_EXIT_STATUS=7 bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 03-code-repair --json)"; status=$?; set -e
  assert_equals 'code repair nonzero agent exit with evidence is warning-only' "$status" '0'
  assert_contains 'code repair records openclaw exit status' "$repair_output" '"openclawExitStatus": 7'
  assert_contains 'code repair nonzero agent exit is visible' "$repair_output" 'openclaw agent exited 7'
}

test_run_directories_are_isolated() {
  local sentinel="$CLAWBOX_QUALIFY_RUNS_DIR/old-run/sentinel.txt" output status=0
  mkdir -p "$(dirname "$sentinel")"
  printf 'keep\n' > "$sentinel"
  install_fake_openclaw
  set +e; output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='isolation-run' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'isolated run exits success' "$status" '0'
  if [ -f "$sentinel" ]; then pass 'one run cannot delete another run artifact'; else fail 'one run cannot delete another run artifact'; fi
  assert_contains 'isolated run records its own artifact directory' "$output" 'isolation-run'
}

test_runner_distinct_runs_preserve_previous_artifacts() {
  local first_output second_output status=0 first_dir='' second_dir='' sentinel=''
  install_fake_openclaw
  set +e; first_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='distinct-run-one' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'first distinct run exits success' "$status" '0'
  first_dir="$(python3 - "$first_output" <<'PY'
import json, sys
print(json.loads(sys.argv[1])['artifactDirectory'])
PY
)"
  sentinel="$first_dir/sentinel.txt"
  printf 'keep\n' > "$sentinel"
  install_fake_openclaw
  set +e; second_output="$(PATH="$MOCK_BIN_DIR:$PATH" CLAWBOX_QUALIFY_RUN_ID='distinct-run-two' CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL=1 bash "$ROOT_DIR/vm/qualification/runner.sh" --scenario 01-tool-reliability --json)"; status=$?; set -e
  assert_equals 'second distinct run exits success' "$status" '0'
  second_dir="$(python3 - "$second_output" <<'PY'
import json, sys
print(json.loads(sys.argv[1])['artifactDirectory'])
PY
)"
  if [ "$first_dir" != "$second_dir" ]; then pass 'two qualification runs use distinct artifact directories'; else fail 'two qualification runs use distinct artifact directories'; fi
  if [ -f "$sentinel" ]; then pass 'second run does not delete prior run artifacts'; else fail 'second run does not delete prior run artifacts'; fi
}

test_qualify_suite_manifest_drives_self_healing() {
  local output
  output="$({ BASE_DIR="$ROOT_DIR"; VM_HOST='tester@vm'; VM_RUNTIME_PATH='/Users/tester/ClawBox'; source "$ROOT_DIR/lib/output.sh"; source "$ROOT_DIR/lib/qualify/qualify.sh"; calls=''; require_vm_host(){ :; }; qualify_suite_checksum(){ printf 'checksum\n'; }; qualify_remote_manifest_matches(){ return 1; }; qualify_publish_suite_to_vm_runtime(){ calls="${calls}publish "; }; qualify_install_suite_on_vm(){ calls="${calls}install:$1 "; }; qualify_ensure_suite_installed; printf 'CALLS:%s\n' "$calls"; } 2>&1)"
  assert_contains 'stale or missing suite publishes payload' "$output" 'CALLS:publish install:checksum'
  output="$({ BASE_DIR="$ROOT_DIR"; VM_HOST='tester@vm'; VM_RUNTIME_PATH='/Users/tester/ClawBox'; source "$ROOT_DIR/lib/output.sh"; source "$ROOT_DIR/lib/qualify/qualify.sh"; calls=''; require_vm_host(){ :; }; qualify_suite_checksum(){ printf 'checksum\n'; }; qualify_remote_manifest_matches(){ return 0; }; qualify_publish_suite_to_vm_runtime(){ calls="${calls}publish "; }; qualify_install_suite_on_vm(){ calls="${calls}install "; }; qualify_ensure_suite_installed; printf 'CALLS:%s\n' "$calls"; } 2>&1)"
  assert_contains 'matching suite skips reinstall' "$output" 'CALLS:'
  assert_not_contains 'matching suite does not publish' "$output" 'publish'
  assert_not_contains 'matching suite does not install' "$output" 'install'
}

test_setup_payload_publication_includes_qualification_suite() {
  local output
  output="$({ source "$ROOT_DIR/lib/output.sh"; source "$ROOT_DIR/lib/setup-openclaw-provisioning.sh"; VM_HOST='tester@vm'; VM_RUNTIME_PATH='/Users/tester/ClawBox'; PROVISION_SCRIPT="$ROOT_DIR/vm/vm-provision.sh"; ssh_exec(){ return 0; }; qualify_publish_suite_to_vm_runtime(){ printf 'QUALIFY_PUBLISH\n'; }; ensure_vm_provision_script; } 2>&1)"
  assert_contains 'setup payload publication calls qualification publisher' "$output" 'QUALIFY_PUBLISH'
}

test_payload_excludes_prototypes_and_tests() {
  local payload
  payload="$(tar -C "$ROOT_DIR/vm" -cf - qualification | tar -tf -)"
  assert_not_contains 'payload excludes prototype references' "$payload" 'prototype/'
  assert_not_contains 'payload excludes tests' "$payload" 'tests/'
  assert_not_contains 'payload excludes test fixtures' "$payload" 'tests/fixtures/'
  assert_not_contains 'payload excludes mock executors' "$payload" 'mock-openclaw'
}

test_qualify_sources_avoid_openclaw_config_replacement() {
  local source_text
  source_text="$(cat "$ROOT_DIR/scripts/qualify.sh" "$ROOT_DIR/lib/qualify/qualify.sh")"
  assert_not_contains 'qualify command does not replace openclaw config' "$source_text" 'openclaw.json'
  assert_not_contains 'qualify command does not run onboarding' "$source_text" 'openclaw onboard'
  assert_not_contains 'qualify command does not switch models' "$source_text" 'MODEL_PATH='
}

run_test test_root_help_lists_qualify
run_test test_qualification_entrypoint_modes
run_test test_qualify_help_does_not_execute_remote_commands
run_test test_qualify_unknown_options_and_scenarios_fail_clearly
run_test test_qualify_runner_errors_when_openclaw_missing
run_test test_qualify_json_host_errors_keep_stdout_machine_readable
run_test test_qualify_runner_dependency_preflight_errors
run_test test_qualify_runner_default_json_runs_real_scenarios_with_fake_openclaw
run_test test_qualify_profiles_select_expected_coverage
run_test test_qualify_fast_profile_aggregate_includes_all_scenarios
run_test test_runner_aggregates_fast_and_full_fixture_results_robustly
run_test test_tool_reliability_serializes_multi_record_trajectories
run_test test_vm_progress_events_cover_profiles_and_scenarios
run_test test_qualify_runner_records_null_git_provenance_outside_checkout
run_test test_qualify_command_self_heals_without_setup
run_test test_qualify_human_output_is_polished
run_test test_qualify_renders_valid_remote_results_before_returning_status
run_test test_qualify_model_mismatch_stops_before_publish
run_test test_tool_reliability_extra_calls_warn_but_do_not_fail
run_test test_tool_reliability_reply_mismatch_is_precise_failure
run_test test_tool_reliability_fabricated_success_fails
run_test test_workflow_required_tool_omission_fails
run_test test_tool_reliability_model_failures_continue_all_iterations
run_test test_evidence_failures_are_errors
run_test test_tool_reliability_captures_agent_error_evidence_and_classifies_it
run_test test_workflow_cases_and_code_repair_objective_behavior
run_test test_run_directories_are_isolated
run_test test_runner_distinct_runs_preserve_previous_artifacts
run_test test_qualify_suite_manifest_drives_self_healing
run_test test_setup_payload_publication_includes_qualification_suite
run_test test_payload_excludes_prototypes_and_tests
run_test test_qualify_sources_avoid_openclaw_config_replacement

if [ "$FAILURES" -eq 0 ]; then printf 'PASS: qualify command test suite succeeded\n'; exit 0; fi
printf 'FAIL: qualify command test suite failed with %s issues\n' "$FAILURES"; exit 1
