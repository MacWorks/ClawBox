#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SUITE_DIR/lib/helpers.sh"

RUN_ID="$1"
ARTIFACT_DIR="$2"
SCENARIO_ID="03-code-repair"
SCENARIO_NAME="Code repair"
START="$(qualification_now_epoch)"
PROJECT="$ARTIFACT_DIR/project"
LOGS="$ARTIFACT_DIR/logs"
mkdir -p "$PROJECT" "$LOGS"

cat > "$PROJECT/calculator.sh" <<'CALC'
#!/usr/bin/env bash

add() {
    echo $(( $1 - $2 ))
}

add "$1" "$2"
CALC

cat > "$PROJECT/test.sh" <<'TEST'
#!/usr/bin/env bash
set -euo pipefail

actual=$(./calculator.sh 7 5)

if [[ "$actual" != "12" ]]; then
    printf 'FAIL: expected 12, got %s\n' "$actual"
    exit 1
fi

echo "PASS"
TEST

chmod +x "$PROJECT/calculator.sh" "$PROJECT/test.sh"
(
  cd "$PROJECT"
  git init -q
  git add calculator.sh test.sh
  git commit -qm "Initial broken calculator"
)

RULES='Tool-use rules:
- Use only tools and arguments required for the task.
- For exec, normally provide only the command field.
- Never set elevated=true unless explicitly requested.
- Do not use web tools for this local repository task.
- Inspect the relevant files before editing.
- Make the smallest correct change.
- Keep every change inside the specified project directory.
- Run the provided test after editing.
- If the test fails, inspect the failure and correct the implementation.
- Do not commit, push, or create unrelated files.
- Do not claim success unless the test actually passes.'

session="$(qualification_unique_session_id qualify-code-repair)"
prompt_file="$LOGS/prompt.txt"
agent_output="$LOGS/agent-output.json"
cat > "$prompt_file" <<EOF_PROMPT
$RULES

Project directory:
$PROJECT

The supplied test currently fails.

Diagnose the defect, make the smallest appropriate correction, and run the test.

When finished, report:
1. The root cause.
2. The file changed.
3. The exact final test result.
EOF_PROMPT

set +e
qualification_run_openclaw_agent "$session" 300 "$prompt_file" "$agent_output"
openclaw_exit=$?
set -e

duration=0
warnings_file="$LOGS/warnings.txt"; failures_file="$LOGS/failures.txt"
: > "$warnings_file"; : > "$failures_file"

if ! qualification_find_session_files "$session"; then
  duration=$(($(qualification_now_epoch) - START))
  qualification_error_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$ARTIFACT_DIR" "$QUALIFICATION_EVIDENCE_ERROR" "$session" "$openclaw_exit" '' '' "$duration"
  exit 0
fi
if ! final_status="$(qualification_trace_final_status "$QUALIFICATION_TRAJECTORY" 2>/dev/null)"; then
  duration=$(($(qualification_now_epoch) - START)); qualification_error_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$ARTIFACT_DIR" 'malformed trajectory finalStatus' "$session" "$openclaw_exit" "$QUALIFICATION_TRAJECTORY" "$QUALIFICATION_TRANSCRIPT" "$duration"; exit 0
fi
if ! tools="$(qualification_trace_tool_count "$QUALIFICATION_TRAJECTORY" 2>/dev/null)"; then
  duration=$(($(qualification_now_epoch) - START)); qualification_error_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$ARTIFACT_DIR" 'malformed trajectory toolMetas' "$session" "$openclaw_exit" "$QUALIFICATION_TRAJECTORY" "$QUALIFICATION_TRANSCRIPT" "$duration"; exit 0
fi
if ! reply="$(qualification_final_reply "$QUALIFICATION_TRANSCRIPT" 2>/dev/null)"; then
  duration=$(($(qualification_now_epoch) - START)); qualification_error_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$ARTIFACT_DIR" 'malformed transcript' "$session" "$openclaw_exit" "$QUALIFICATION_TRAJECTORY" "$QUALIFICATION_TRANSCRIPT" "$duration"; exit 0
fi

if (cd "$PROJECT" && ./test.sh >"$LOGS/test-output.txt" 2>&1); then test_result=PASS; else test_result=FAIL; fi
changed_files="$(cd "$PROJECT" && git status --porcelain)"
(cd "$PROJECT" && git diff -- calculator.sh test.sh >"$LOGS/diff.patch")
calculator_valid=false
if bash -n "$PROJECT/calculator.sh" && grep -Fq 'echo $(( $1 + $2 ))' "$PROJECT/calculator.sh"; then calculator_valid=true; fi
scope_valid=false
if [ "$changed_files" = ' M calculator.sh' ]; then scope_valid=true; fi
status_ok=false; [ "$final_status" = success ] && status_ok=true
scenario_status=PASS
[ "$status_ok" = true ] || { scenario_status=FAIL; printf '%s\n' 'agent finalStatus was not success' >> "$failures_file"; }
[ "$test_result" = PASS ] || { scenario_status=FAIL; printf '%s\n' 'final test did not pass' >> "$failures_file"; }
[ "$calculator_valid" = true ] || { scenario_status=FAIL; printf '%s\n' 'calculator did not contain the intended addition operation' >> "$failures_file"; }
[ "$scope_valid" = true ] || { scenario_status=FAIL; printf '%s\n' 'changed files were outside the intended scope' >> "$failures_file"; }
if [ "$openclaw_exit" -ne 0 ] && [ "$scenario_status" = PASS ]; then
  scenario_status=WARNING
  printf '%s\n' "openclaw agent exited $openclaw_exit but objective evidence passed" >> "$warnings_file"
fi

duration=$(($(qualification_now_epoch) - START))
warnings_json="$(cat "$warnings_file" | qualification_json_string_array)"; failures_json="$(cat "$failures_file" | qualification_json_string_array)"
metrics="$(jq -n --arg toolCalls "$tools" --arg finalStatus "$final_status" --arg testResult "$test_result" --arg calculatorValid "$calculator_valid" --arg scopeValid "$scope_valid" --arg changedFiles "$changed_files" --arg diffPath "$LOGS/diff.patch" --arg testOutput "$LOGS/test-output.txt" --arg reply "$reply" '{toolCalls:($toolCalls|tonumber),expectedMin:null,expectedMax:null,toolCallsReliable:true,agentFinalStatus:$finalStatus,testResult:$testResult,calculatorValid:($calculatorValid=="true"),scopeValid:($scopeValid=="true"),changedFiles:$changedFiles,diffPath:$diffPath,testOutputPath:$testOutput,finalReply:$reply}')"
score=0; [ "$scenario_status" = PASS ] && score=90; [ "$scenario_status" = WARNING ] && score=80
assertions="$(qualification_assertions_json agent_completion "$([ "$status_ok" = true ] && echo PASS || echo FAIL)" "trajectory finalStatus=$final_status" instruction_following final_test "$([ "$test_result" = PASS ] && echo PASS || echo FAIL)" "final test result=$test_result" code_state_correctness intended_fix "$([ "$calculator_valid" = true ] && echo PASS || echo FAIL)" 'calculator contains the intended addition operation' code_state_correctness change_scope "$([ "$scope_valid" = true ] && echo PASS || echo FAIL)" "changed files: ${changed_files:-none}" instruction_following grounding "$([ "$test_result" = PASS ] && echo PASS || echo FAIL)" 'success claim is checked against objective test output' grounding)"
qualification_emit_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$scenario_status" "$score" "$duration" "$ARTIFACT_DIR" "$assertions" "$warnings_json" "$failures_json" "$session" "$openclaw_exit" "$QUALIFICATION_TRAJECTORY" "$QUALIFICATION_TRANSCRIPT" "$metrics"
