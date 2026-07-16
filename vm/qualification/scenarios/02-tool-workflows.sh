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
WORKFLOW_CASES="${CLAWBOX_QUALIFY_WORKFLOW_CASES:-exact-output grounded-read absence-check two-step transform}"

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
agent_complete_cases=0; required_tool_cases=0; reply_correct_cases=0; filesystem_correct_cases=0; grounded_cases=0

workflow_case_enabled() {
  local wanted="$1" selected=''
  for selected in $WORKFLOW_CASES; do
    if [ "$selected" = "$wanted" ]; then
      return 0
    fi
  done
  return 1
}

workflow_validate_cases() {
  local selected=''
  [ -n "$WORKFLOW_CASES" ] || return 1
  for selected in $WORKFLOW_CASES; do
    case "$selected" in
      exact-output|grounded-read|absence-check|two-step|transform) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

if ! workflow_validate_cases; then
  duration=$(($(qualification_now_epoch) - START))
  qualification_error_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$ARTIFACT_DIR" "invalid workflow case selection: $WORKFLOW_CASES" '' 2 '' '' "$duration"
  exit 0
fi

run_case() {
  local name="$1" prompt="$2" expected_min="$3" expected_max="$4" expected_reply="$5" expected_file="${6:-}" expected_content="${7:-}"
  total_cases=$((total_cases + 1))
  local case_dir="$ARTIFACT_DIR/$name" session prompt_file agent_output openclaw_exit final_status tools reply file_ok=true reply_ok=false status_ok=false required_tool_ok=false efficient_ok=false grounded_ok=false case_status=PASS case_warnings='[]' case_failure=''
  mkdir -p "$case_dir"
  session="$(qualification_unique_session_id "qualify-workflow-$name")"
  prompt_file="$case_dir/prompt.txt"; agent_output="$case_dir/agent-output.json"
  printf '%s\n\n%s\n' "$RULES" "$prompt" > "$prompt_file"
  set +e; qualification_run_openclaw_agent "$session" 240 "$prompt_file" "$agent_output"; openclaw_exit=$?; set -e
  if ! qualification_find_session_files "$session"; then scenario_status=ERROR; scenario_error="$name: $QUALIFICATION_EVIDENCE_ERROR"; printf '%s\n' "$scenario_error" >> "$failures_file"; qualification_progress_event "$total_cases" "$SCENARIO_ID" "$name"; return; fi
  if ! final_status="$(qualification_trace_final_status "$QUALIFICATION_TRAJECTORY" 2>/dev/null)"; then scenario_status=ERROR; scenario_error="$name: malformed trajectory finalStatus"; printf '%s\n' "$scenario_error" >> "$failures_file"; qualification_progress_event "$total_cases" "$SCENARIO_ID" "$name"; return; fi
  if ! tools="$(qualification_trace_tool_count "$QUALIFICATION_TRAJECTORY" 2>/dev/null)"; then scenario_status=ERROR; scenario_error="$name: malformed trajectory toolMetas"; printf '%s\n' "$scenario_error" >> "$failures_file"; qualification_progress_event "$total_cases" "$SCENARIO_ID" "$name"; return; fi
  if ! reply="$(qualification_final_reply "$QUALIFICATION_TRANSCRIPT" 2>/dev/null)"; then scenario_status=ERROR; scenario_error="$name: malformed transcript"; printf '%s\n' "$scenario_error" >> "$failures_file"; qualification_progress_event "$total_cases" "$SCENARIO_ID" "$name"; return; fi
  [ "$final_status" = success ] && status_ok=true
  [ "$reply" = "$expected_reply" ] && reply_ok=true
  if [ -n "$expected_file" ]; then [ -f "$expected_file" ] && [ "$(cat "$expected_file")" = "$expected_content" ] || file_ok=false; fi
  [ "$tools" -ge "$expected_min" ] 2>/dev/null && required_tool_ok=true
  [ "$tools" -ge "$expected_min" ] 2>/dev/null && [ "$tools" -le "$expected_max" ] 2>/dev/null && efficient_ok=true
  [ "$required_tool_ok" = true ] && [ "$reply_ok" = true ] && [ "$file_ok" = true ] && grounded_ok=true
  [ "$status_ok" = true ] && agent_complete_cases=$((agent_complete_cases + 1))
  [ "$required_tool_ok" = true ] && required_tool_cases=$((required_tool_cases + 1))
  [ "$reply_ok" = true ] && reply_correct_cases=$((reply_correct_cases + 1))
  [ "$file_ok" = true ] && filesystem_correct_cases=$((filesystem_correct_cases + 1))
  [ "$grounded_ok" = true ] && grounded_cases=$((grounded_cases + 1))
  if [ "$status_ok" != true ] || [ "$required_tool_ok" != true ] || [ "$reply_ok" != true ] || [ "$file_ok" != true ] || [ "$grounded_ok" != true ]; then
    case_status=FAIL
    scenario_status=FAIL
    case_failure="$(jq -n -r --arg name "$name" --arg finalStatus "$final_status" --arg requiredTool "$required_tool_ok" --arg replyOk "$reply_ok" --arg fileOk "$file_ok" --arg grounded "$grounded_ok" --arg expectedReply "$expected_reply" --arg actualReply "$reply" '
      def clean:
        tostring
        | explode | map(if . < 32 or . == 127 then 32 else . end) | implode
        | if length > 120 then .[0:117] + "..." else . end;
      [
        (if $finalStatus != "success" then "agentStatus=\($finalStatus)" else empty end),
        (if $requiredTool != "true" then "required tool use below expected minimum" else empty end),
        (if $replyOk != "true" then "reply mismatch; expected \"" + ($expectedReply|clean) + "\", received \"" + ($actualReply|clean) + "\"" else empty end),
        (if $fileOk != "true" then "filesystem state incorrect" else empty end),
        (if $grounded != "true" then "response was not grounded in required tool evidence" else empty end)
      ] | "\($name): " + join("; ")
    ')"
    printf '%s\n' "$case_failure" >> "$failures_file"
  elif [ "$efficient_ok" != true ]; then
    case_status=WARNING; [ "$scenario_status" = PASS ] && scenario_status=WARNING; printf '%s\n' "$name completed correctly but used $tools tool calls; expected efficient range $expected_min-$expected_max" >> "$warnings_file"; case_warnings="$(printf '%s\n' "expected efficient range $expected_min-$expected_max, observed $tools" | qualification_json_string_array)"
  else
    efficient_cases=$((efficient_cases + 1))
  fi
  [ "$case_status" != FAIL ] && pass_cases=$((pass_cases + 1))
  tool_sum=$((tool_sum + tools))
  jq -n --arg name "$name" --arg sessionId "$session" --arg agentStatus "$final_status" --arg toolCalls "$tools" --arg expectedMin "$expected_min" --arg expectedMax "$expected_max" --arg requiredTool "$required_tool_ok" --arg efficient "$efficient_ok" --arg replyCorrect "$reply_ok" --arg fileCorrect "$file_ok" --arg grounded "$grounded_ok" --arg expectedReply "$expected_reply" --arg actualReply "$reply" --arg status "$case_status" --arg trajectory "$QUALIFICATION_TRAJECTORY" --arg transcript "$QUALIFICATION_TRANSCRIPT" --argjson warnings "$case_warnings" '{case:$name,sessionId:$sessionId,agentStatus:$agentStatus,toolCalls:($toolCalls|tonumber),expectedEfficientRange:{min:($expectedMin|tonumber),max:($expectedMax|tonumber)},requiredToolInvoked:($requiredTool=="true"),toolCountEfficient:($efficient=="true"),replyCorrect:($replyCorrect=="true"),reply:{expected:$expectedReply,actual:$actualReply,correct:($replyCorrect=="true")},filesystemCorrect:($fileCorrect=="true"),groundingCorrect:($grounded=="true"),status:$status,warnings:$warnings,artifacts:{trajectory:$trajectory,transcript:$transcript}}' >> "$cases_jsonl"
  qualification_progress_event "$total_cases" "$SCENARIO_ID" "$name"
}

if workflow_case_enabled exact-output; then
run_case exact-output "Use exec exactly once to run:
printf 'RED\nGREEN\nBLUE\n'

Reply with exactly the complete command output, preserving all lines and adding nothing." 1 1 $'RED\nGREEN\nBLUE'
fi

if workflow_case_enabled grounded-read; then
run_case grounded-read "Use exec exactly once to read:
$ROOT/source.txt

Reply with exactly the verification code and nothing else." 1 1 'NCC1701'
fi

if workflow_case_enabled absence-check; then
run_case absence-check "Use exec exactly once to determine whether this file exists:
$ROOT/missing.txt

Do not create it. Reply with exactly ABSENT when it does not exist." 1 1 'ABSENT'
fi

if workflow_case_enabled two-step; then
run_case two-step "Use exec exactly twice.

First create $ROOT/input.txt containing alpha, beta, and gamma on separate lines.

Second extract the beta line, write it to $ROOT/output.txt, and print it.

Reply with exactly beta." 2 2 'beta' "$ROOT/output.txt" 'beta'
fi

if workflow_case_enabled transform; then
run_case transform "Use exec exactly twice.

First create $ROOT/numbers.txt containing 9, 3, and 7 on separate lines.

Second sort the numbers numerically, write the result to $ROOT/sorted.txt, and print the result.

Reply with exactly the printed lines and no Markdown formatting." 2 2 $'3\n7\n9' "$ROOT/sorted.txt" $'3\n7\n9'
fi

duration=$(($(qualification_now_epoch) - START))
warnings_json="$(cat "$warnings_file" | qualification_json_string_array)"; failures_json="$(cat "$failures_file" | qualification_json_string_array)"; cases_json="$(jq -s '.' "$cases_jsonl")"
avg_tool_calls="$(jq -n --arg sum "$tool_sum" --arg total "$total_cases" 'if ($total|tonumber) == 0 then 0 else (($sum|tonumber) / ($total|tonumber)) end')"
metrics="$(jq -n --arg total "$total_cases" --arg pass "$pass_cases" --arg efficient "$efficient_cases" --arg agentComplete "$agent_complete_cases" --arg requiredTool "$required_tool_cases" --arg replyCorrect "$reply_correct_cases" --arg filesystemCorrect "$filesystem_correct_cases" --arg grounded "$grounded_cases" --arg profileId "${CLAWBOX_QUALIFY_PROFILE_ID:-full}" --arg profileName "${CLAWBOX_QUALIFY_PROFILE_NAME:-Full}" --arg selectedCases "$WORKFLOW_CASES" --argjson avg "$avg_tool_calls" --argjson cases "$cases_json" '{profile:{id:$profileId,name:$profileName},selectedCases:($selectedCases | split(" ") | map(select(. != ""))),totalCases:($total|tonumber),passingCases:($pass|tonumber),agentCompletionCases:($agentComplete|tonumber),requiredToolCases:($requiredTool|tonumber),replyCorrectCases:($replyCorrect|tonumber),filesystemCorrectCases:($filesystemCorrect|tonumber),groundedCases:($grounded|tonumber),efficientCases:($efficient|tonumber),averageToolCalls:$avg,toolCallsReliable:true,toolCalls:$avg,cases:$cases}')"
if [ "$scenario_status" = ERROR ]; then assertions="$(qualification_assertions_json evidence ERROR "${scenario_error:-evidence error}" workflow_correctness)"; qualification_emit_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" ERROR unrated "$duration" "$ARTIFACT_DIR" "$assertions" "$warnings_json" "$failures_json" '' '' '' '' "$metrics"; exit 0; fi
score="$(jq -n --arg total "$total_cases" --arg agentComplete "$agent_complete_cases" --arg requiredTool "$required_tool_cases" --arg replyCorrect "$reply_correct_cases" --arg filesystemCorrect "$filesystem_correct_cases" --arg grounded "$grounded_cases" --arg efficient "$efficient_cases" '
  def ratio($n): (($n|tonumber) / ($total|tonumber));
  ((ratio($agentComplete) * 15)
   + (ratio($requiredTool) * 20)
   + (ratio($replyCorrect) * 20)
   + (ratio($filesystemCorrect) * 20)
   + (ratio($grounded) * 20)
   + (ratio($efficient) * 5)) | round
')"
assertions="$(qualification_assertions_json agent_completion "$([ "$agent_complete_cases" -eq "$total_cases" ] && echo PASS || echo FAIL)" "$agent_complete_cases/$total_cases workflow cases completed successfully" workflow_correctness required_tool_invocation "$([ "$required_tool_cases" -eq "$total_cases" ] && echo PASS || echo FAIL)" "$required_tool_cases/$total_cases workflow cases met required tool-use minimums" tool_correctness reply_correctness "$([ "$reply_correct_cases" -eq "$total_cases" ] && echo PASS || echo FAIL)" "$reply_correct_cases/$total_cases workflow cases returned the exact expected reply" instruction_following filesystem_state "$([ "$filesystem_correct_cases" -eq "$total_cases" ] && echo PASS || echo FAIL)" "$filesystem_correct_cases/$total_cases workflow cases produced the expected filesystem state" code_state_correctness grounding "$([ "$grounded_cases" -eq "$total_cases" ] && echo PASS || echo FAIL)" "$grounded_cases/$total_cases workflow cases were grounded in required tool evidence" grounding efficiency "$([ "$efficient_cases" -eq "$total_cases" ] && echo PASS || echo WARNING)" "$efficient_cases/$total_cases cases used efficient tool-call ranges" efficiency)"
qualification_emit_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$scenario_status" "$score" "$duration" "$ARTIFACT_DIR" "$assertions" "$warnings_json" "$failures_json" '' '' '' '' "$metrics"
