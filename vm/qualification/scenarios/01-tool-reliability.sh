#!/usr/bin/env bash
set -euo pipefail

SUITE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SUITE_DIR/lib/helpers.sh"

RUN_ID="$1"
ARTIFACT_DIR="$2"
SCENARIO_ID="01-tool-reliability"
SCENARIO_NAME="Tool-calling reliability"
TOTAL="${CLAWBOX_QUALIFY_TOOL_RELIABILITY_TOTAL:-${CLAWBOX_QUALIFY_RELIABILITY_ITERATIONS:-10}}"
START="$(qualification_now_epoch)"
mkdir -p "$ARTIFACT_DIR"

case "$TOTAL" in
  ''|*[!0-9]*)
    qualification_error_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$ARTIFACT_DIR" "invalid reliability iteration count: $TOTAL" '' 2 '' '' 0
    exit 0
    ;;
esac
if [ "$TOTAL" -lt 1 ]; then
  qualification_error_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$ARTIFACT_DIR" "invalid reliability iteration count: $TOTAL" '' 2 '' '' 0
  exit 0
fi

RULES='Tool-use rules:
- Use only the tool and arguments required for the task.
- For exec, normally provide only the command field.
- Never set elevated=true unless explicitly requested.
- Do not retry a successful tool call.
- Do not invent tool results.
- After the tool succeeds, follow the requested reply format exactly.'

correct=0
efficient=0
tool_sum=0
warnings_file="$ARTIFACT_DIR/warnings.txt"
failures_file="$ARTIFACT_DIR/failures.txt"
iterations_jsonl="$ARTIFACT_DIR/iterations.jsonl"
: > "$warnings_file"
: > "$failures_file"
: > "$iterations_jsonl"
scenario_status=PASS
scenario_error=''

iteration_failure_is_infrastructure() {
  local error_json="$1" error_type='' error_message=''
  error_type="$(printf '%s\n' "$error_json" | jq -r '.type // ""' 2>/dev/null || true)"
  error_message="$(printf '%s\n' "$error_json" | jq -r '.message // ""' 2>/dev/null || true)"
  case "$error_type" in
    infrastructure|executor|gateway|dependency|session|transport) return 0 ;;
  esac
  case "$error_message" in
    *"OpenClaw process could not start"*|*"gateway unavailable"*|*"inference endpoint disconnected"*|*"connection refused"*|*"ECONNREFUSED"*|*"session directory missing"*) return 0 ;;
  esac
  return 1
}

iteration_failure_summary() {
  local iteration="$1" final_status="$2" tools="$3" file_ok="$4" reply_ok="$5" error_json="$6"
  jq -r --arg iteration "$iteration" --arg finalStatus "$final_status" --arg tools "$tools" --arg fileOk "$file_ok" --arg replyOk "$reply_ok" '
    . as $error
    | ($error.message // "") as $message
    | ($error.type // "agent_error") as $type
    | if ($error.timeout == true) then
        "iteration \($iteration): OpenClaw agent timed out before completing the required tool workflow"
      elif $message != "" then
        "iteration \($iteration): \($message)"
      else
        "iteration \($iteration) failed critical assertions: agentStatus=\($finalStatus), toolCalls=\($tools), fileCorrect=\($fileOk), replyCorrect=\($replyOk), errorType=\($type)"
      end
  ' <<<"$error_json"
}

for n in $(seq 1 "$TOTAL"); do
  iter_dir="$ARTIFACT_DIR/iteration-$n"
  mkdir -p "$iter_dir"
  file="$iter_dir/test-$n.txt"
  session="$(qualification_unique_session_id "qualify-tool-$n")"
  prompt_file="$iter_dir/prompt.txt"
  agent_output="$iter_dir/agent-output.json"
  cat > "$prompt_file" <<EOF_PROMPT
$RULES

Use exec exactly once to create:
$file

The file must contain exactly:
PASS_$n

After the tool succeeds, reply with exactly:
DONE
EOF_PROMPT

  set +e
  qualification_run_openclaw_agent "$session" 180 "$prompt_file" "$agent_output"
  openclaw_exit=$?
  set -e

  if ! qualification_find_session_files "$session"; then
    scenario_status=ERROR
    scenario_error="$QUALIFICATION_EVIDENCE_ERROR"
    printf '%s\n' "iteration $n: $scenario_error" >> "$failures_file"
    break
  fi

  if ! final_status="$(qualification_trace_final_status "$QUALIFICATION_TRAJECTORY" 2>/dev/null)"; then
    scenario_status=ERROR; scenario_error='malformed trajectory finalStatus'; printf '%s\n' "iteration $n: $scenario_error" >> "$failures_file"; break
  fi
  if ! tools="$(qualification_trace_tool_count "$QUALIFICATION_TRAJECTORY" 2>/dev/null)"; then
    scenario_status=ERROR; scenario_error='malformed trajectory toolMetas'; printf '%s\n' "iteration $n: $scenario_error" >> "$failures_file"; break
  fi
  if ! reply="$(qualification_final_reply "$QUALIFICATION_TRANSCRIPT" 2>/dev/null)"; then
    scenario_status=ERROR; scenario_error='malformed transcript'; printf '%s\n' "iteration $n: $scenario_error" >> "$failures_file"; break
  fi
  error_json="$(qualification_trace_error_json "$QUALIFICATION_TRAJECTORY" "$final_status" "OpenClaw agent finalStatus=$final_status" 2>/dev/null || printf '{"type":"agent_error","message":"unable to parse trajectory error details","timeout":false}\n')"

  file_ok=false; [ -f "$file" ] && [ "$(cat "$file")" = "PASS_$n" ] && file_ok=true
  reply_ok=false; [ "$reply" = DONE ] && reply_ok=true
  status_ok=false; [ "$final_status" = success ] && status_ok=true
  iter_status=PASS
  iter_warnings='[]'
  if [ "$status_ok" != true ] || [ "$file_ok" != true ] || [ "$reply_ok" != true ]; then
    failure_summary="$(iteration_failure_summary "$n" "$final_status" "$tools" "$file_ok" "$reply_ok" "$error_json")"
    if [ "$final_status" = error ] && [ "$tools" = 0 ] && iteration_failure_is_infrastructure "$error_json"; then
      iter_status=ERROR
      scenario_status=ERROR
      scenario_error="$failure_summary"
      printf '%s\n' "$failure_summary" >> "$failures_file"
    else
      iter_status=FAIL
      scenario_status=FAIL
      printf '%s\n' "$failure_summary" >> "$failures_file"
    fi
  elif [ "$tools" != 1 ]; then
    iter_status=WARNING
    [ "$scenario_status" = PASS ] && scenario_status=WARNING
    printf '%s\n' "iteration $n completed correctly but used $tools tool calls; efficient target is 1" >> "$warnings_file"
    iter_warnings="$(printf '%s\n' "expected 1 efficient tool call, observed $tools" | qualification_json_string_array)"
  fi
  case "$iter_status" in PASS|WARNING) correct=$((correct + 1)) ;; esac
  [ "$tools" = 1 ] && efficient=$((efficient + 1))
  tool_sum=$((tool_sum + tools))
  jq -n --arg iteration "$n" --arg sessionId "$session" --arg agentStatus "$final_status" --arg toolCalls "$tools" --arg openclawExitStatus "$openclaw_exit" --arg fileCorrect "$file_ok" --arg replyCorrect "$reply_ok" --arg status "$iter_status" --arg trajectory "$QUALIFICATION_TRAJECTORY" --arg transcript "$QUALIFICATION_TRANSCRIPT" --arg agentOutput "$agent_output" --argjson warnings "$iter_warnings" --argjson error "$error_json" '{iteration:($iteration|tonumber),sessionId:$sessionId,agentStatus:$agentStatus,openclawExitStatus:($openclawExitStatus|tonumber),toolCalls:($toolCalls|tonumber),expectedEfficientRange:{min:1,max:1},fileCorrect:($fileCorrect=="true"),replyCorrect:($replyCorrect=="true"),status:$status,error:$error,warnings:$warnings,artifacts:{trajectory:$trajectory,transcript:$transcript,agentOutput:$agentOutput}}' >> "$iterations_jsonl"
  [ "$scenario_status" = ERROR ] && break
done

duration=$(($(qualification_now_epoch) - START))
warnings_json="$(cat "$warnings_file" | qualification_json_string_array)"
failures_json="$(cat "$failures_file" | qualification_json_string_array)"
iterations_json="$(jq -s '.' "$iterations_jsonl")"
avg_tool_calls="$(jq -n --arg sum "$tool_sum" --arg total "$TOTAL" 'if ($total|tonumber) == 0 then 0 else (($sum|tonumber) / ($total|tonumber)) end')"
metrics="$(jq -n --arg total "$TOTAL" --arg correct "$correct" --arg efficient "$efficient" --arg profileId "${CLAWBOX_QUALIFY_PROFILE_ID:-full}" --arg profileName "${CLAWBOX_QUALIFY_PROFILE_NAME:-Full}" --argjson avg "$avg_tool_calls" --argjson iterations "$iterations_json" '{profile:{id:$profileId,name:$profileName},totalIterations:($total|tonumber),correctIterations:($correct|tonumber),efficientIterations:($efficient|tonumber),correctnessRate:(($correct|tonumber) / ($total|tonumber)),efficientCallRate:(($efficient|tonumber) / ($total|tonumber)),averageToolCalls:$avg,toolCallsReliable:true,toolCalls:$avg,expectedMin:1,expectedMax:1,iterations:$iterations}')"

if [ "$scenario_status" = ERROR ]; then
  assertions="$(qualification_assertions_json evidence ERROR "${scenario_error:-infrastructure evidence error}" tool_correctness)"
  qualification_emit_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" ERROR unrated "$duration" "$ARTIFACT_DIR" "$assertions" "$warnings_json" "$failures_json" '' '' '' '' "$metrics"
  exit 0
fi

score="$(jq -n --arg correct "$correct" --arg efficient "$efficient" --arg total "$TOTAL" '(((($correct|tonumber) / ($total|tonumber)) * 85) + ((($efficient|tonumber) / ($total|tonumber)) * 15)) | round')"
assertions="$(qualification_assertions_json task_completion "$([ "$correct" -eq "$TOTAL" ] && echo PASS || echo FAIL)" "$correct/$TOTAL iterations completed with correct state and reply" tool_correctness efficiency "$([ "$efficient" -eq "$TOTAL" ] && echo PASS || echo WARNING)" "$efficient/$TOTAL iterations used the efficient one-call target" efficiency grounding "$([ "$correct" -eq "$TOTAL" ] && echo PASS || echo FAIL)" 'file state and final reply were objectively checked' grounding)"
qualification_emit_result "$RUN_ID" "$SCENARIO_ID" "$SCENARIO_NAME" "$scenario_status" "$score" "$duration" "$ARTIFACT_DIR" "$assertions" "$warnings_json" "$failures_json" '' '' '' '' "$metrics"
