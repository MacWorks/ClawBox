#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SUITE_DIR/lib/helpers.sh"

RUN_ID="$1"
ARTIFACT_DIR="$2"
SCENARIO_ID="02-tool-workflows"
SCENARIO_NAME="Tool workflow correctness"
START="$(qualification_now_epoch)"
ROOT="$ARTIFACT_DIR/work"
mkdir -p "$ROOT"

RULES='Tool-use rules:
- Use only the tool and arguments required for the task.
- For exec, normally provide only the command field.
- Never set elevated=true unless explicitly requested.
- Do not use web tools for local filesystem tasks.
- Do not retry a successful tool call.
- Never invent, summarize, or paraphrase exact command output.
- After the requested tools succeed, follow the requested reply format exactly.'

printf 'The verification code is NCC1701.\n' > "$ROOT/source.txt"
rm -f "$ROOT/missing.txt" "$ROOT/input.txt" "$ROOT/output.txt" "$ROOT/numbers.txt" "$ROOT/sorted.txt"

warnings_file="$ARTIFACT_DIR/warnings.txt"; failures_file="$ARTIFACT_DIR/failures.txt"; cases_jsonl="$ARTIFACT_DIR/cases.jsonl"
: > "$warnings_file"; : > "$failures_file"; : > "$cases_jsonl"
scenario_status=PASS; scenario_error=''; pass_cases=0; efficient_cases=0; total_cases=0; tool_sum=0

run_case() {
  local name="$1" prompt="$2" expected_min="$3" expected_max="$4" expected_reply="$5" expected_file="${6:-}" expected_content="${7:-}"
  total_cases=$((total_cases + 1))
  local case_dir="$ARTIFACT_DIR/$name" session prompt_file agent_output openclaw_exit final_status tools reply file_ok=true reply_ok=false status_ok=false case_status=PASS case_warnings='[]'
  mkdir -p "$case_dir"
  session="$(qualification_unique_session_id "qualify-workflow-$name")"
  prompt_file="$case_dir/prompt.txt"; agent_output="$case_dir/agent-output.json"
  printf '%s\n\n%s\n' "$RULES" "$prompt" > "$prompt_file"
  set +e; qualification_run_openclaw_agent "$session" 240 "$prompt_file" "$agent_output"; openclaw_exit=$?; set -e
  if ! qualification_find_session_files "$session"; then scenario_status=ERROR; scenario_error="$name: $QUALIFICATION_EVIDENCE_ERROR"; printf '%s\n' "$scenario_error" >> "$failures_file"; return; fi
  if ! final_status="$(qualification_trace_final_status "$QUALIFICATION_TRAJECTORY" 2>/dev/null)"; then scenario_status=ERROR; scenario_error="$name: malformed trajectory finalStatus"; printf '%s\n' "$scenario_error" >> "$failures_file"; return; fi
  if ! tools="$(qualification_trace_tool_count "$QUALIFICATION_TRAJECTORY" 2>/dev/null)"; then scenario_status=ERROR; scenario_error="$name: malformed trajectory toolMetas"; printf '%s\n' "$scenario_error" >> "$failures_file"; return; fi
  if ! reply="$(qualification_final_reply "$QUALIFICATION_TRANSCRIPT" 2>/dev/null)"; then scenario_status=ERROR; scenario_error="$name: malformed transcript"; printf '%s\n' "$scenario_error" >> "$failures_file"; return; fi
  [ "$final_status" = success ] && status_ok=true
  [ "$reply" = "$expected_reply" ] && reply_ok=true
  if [ -n "$expected_file" ]; then [ -f "$expected_file" ] && [ "$(cat "$expected_file")" = "$expected_content" ] || file_ok=false; fi
  if [ "$status_ok" != true ] || [ "$reply_ok" != true ] || [ "$file_ok" != true ]; then
    case_status=FAIL; scenario_status=FAIL; printf '%s\n' "$name failed critical assertions" >> "$failures_file"
  elif [ "$tools" -lt "$expected_min" ] || [ "$tools" -gt "$expected_max" ]; then
    case_status=WARNING; [ "$scenario_status" = PASS ] && scenario_status=WARNING; printf '%s\n' "$name completed correctly but used $tools tool calls; expected efficient range $expected_min-$expected_max" >> "$warnings_file"; case_warnings="$(printf '%s\n' "expected efficient range $expected_min-$expected_max, observed $tools" | qualification_json_string_array)"
  else
    efficient_cases=$((efficient_cases + 1))
  fi
  [ "$case_status" != FAIL ] && pass_cases=$((pass_cases + 1))
  tool_sum=$((tool_sum + tools))
  jq -n --arg name "$name" --arg sessionId "$session" --arg agentStatus "$final_status" --arg toolCalls "$tools" --arg expectedMin "$expected_min" --arg expectedMax "$expected_max" --arg replyCorrect "$reply_ok" --arg fileCorrect "$file_ok" --arg status "$case_status" --arg trajectory "$QUALIFICATION_TRAJECTORY" --arg transcript "$QUALIFICATION_TRANSCRIPT" --argjson warnings "$case_warnings" '{case:$name,sessionId:$sessionId,agentStatus:$agentStatus,toolCalls:($toolCalls|tonumber),expectedEfficientRange:{min:($expectedMin|tonumber),max:($expectedMax|tonumber)},replyCorrect:($replyCorrect=="true"),filesystemCorrect:($fileCorrect=="true"),status:$status,warnings:$warnings,artifacts:{trajectory:$trajectory,transcript:$transcript}}' >> "$cases_jsonl"
}

run_case exact-output "Use exec exactly once to run:
printf 'RED\nGREEN\nBLUE\n'

Reply with exactly the complete command output, preserving all lines and adding nothing." 1 1 $'RED\nGREEN\nBLUE'
run_case grounded-read "Use exec exactly once to read:
$ROOT/source.txt

Reply with exactly the verification code and nothing else." 1 1 'NCC1701'
run_case absence-check "Use exec exactly once to determine whether this file exists:
$ROOT/missing.txt

Do not create it. Reply with exactly ABSENT when it does not exist." 1 1 'ABSENT'
run_case two-step "Use exec exactly twice.

First create $ROOT/input.txt containing alpha, beta, and gamma on separate lines.

Second extract the beta line, write it to $ROOT/output.txt, and print it.

Reply with exactly beta." 2 2 'beta' "$ROOT/output.txt" 'beta'
run_case transform "Use exec exactly twice.

First create $ROOT/numbers.txt containing 9, 3, and 7 on separate lines.

Second sort the numbers numerically, write the result to $ROOT/sorted.txt, and print the result.

Reply with exactly the printed lines and no Markdown formatting." 2 2 $'3\n7\n9' "$ROOT/sorted.txt" $'3\n7\n9'

duration=$(($(qualification_now_epoch) - START))
warnings_json="$(cat "$warnings_file" | qualification_json_string_array)"; failures_json="$(cat "$failures_file" | qualification_json_string_array)"; cases_json="$(jq -s '.' "$cases_jsonl")"
avg_tool_calls="$(jq -n --arg sum "$tool_sum" --arg total "$total_cases" 'if ($total|tonumber) == 0 then 0 else (($sum|tonumber) / ($total|tonumber)) end')"
metrics="$(jq -n --arg total "$total_cases" --arg pass "$pass_cases" --arg efficient "$efficient_cases" --argjson avg "$avg_tool_calls" --argjson cases "$cases_json" '{totalCases:($total|tonumber),passingCases:($pass|tonumber),efficientCases:($efficient|tonumber),averageToolCalls:$avg,toolCallsReliable:true,toolCalls:$avg,cases:$cases}')"
if [ "$scenario_status" = ERROR ]; then assertions="$(qualification_assertions_json evidence ERROR "${scenario_error:-evidence error}" workflow_correctness)"; qualification_emit_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" ERROR unrated "$duration" "$ARTIFACT_DIR" "$assertions" "$warnings_json" "$failures_json" '' '' '' '' "$metrics"; exit 0; fi
score="$(jq -n --arg pass "$pass_cases" --arg efficient "$efficient_cases" --arg total "$total_cases" '(((($pass|tonumber) / ($total|tonumber)) * 90) + ((($efficient|tonumber) / ($total|tonumber)) * 10)) | round')"
assertions="$(qualification_assertions_json workflow_cases "$([ "$pass_cases" -eq "$total_cases" ] && echo PASS || echo FAIL)" "$pass_cases/$total_cases workflow cases completed correctly" workflow_correctness grounding "$([ "$pass_cases" -eq "$total_cases" ] && echo PASS || echo FAIL)" 'reply and filesystem evidence were checked against expected values' grounding efficiency "$([ "$efficient_cases" -eq "$total_cases" ] && echo PASS || echo WARNING)" "$efficient_cases/$total_cases cases used efficient tool-call ranges" efficiency)"
qualification_emit_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$scenario_status" "$score" "$duration" "$ARTIFACT_DIR" "$assertions" "$warnings_json" "$failures_json" '' '' '' '' "$metrics"
