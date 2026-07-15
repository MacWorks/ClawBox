#!/usr/bin/env bash

qualification_now_epoch() {
  date +%s
}

qualification_session_dir() {
  printf '%s\n' "${CLAWBOX_QUALIFY_SESSION_DIR:-$HOME/.openclaw/agents/main/sessions}"
}

qualification_unique_session_id() {
  local prefix="$1"
  printf '%s-%s-%s\n' "$prefix" "$(date +%s)" "$RANDOM"
}

qualification_json_string_array() {
  jq -R -s 'split("\n") | map(select(length > 0))'
}

qualification_empty_json_array() {
  printf '[]\n'
}

qualification_assertions_json() {
  jq -n '$ARGS.positional | [range(0; length; 4) as $i | {name:.[$i], status:.[$i+1], message:.[$i+2], category:.[$i+3]}]' --args "$@"
}

qualification_emit_result() {
  local run_id="$1" scenario_id="$2" name="$3" status="$4" score="$5" duration="$6" artifact_dir="$7"
  local assertions_json="$8" warnings_json="$9" failures_json="${10}" session_id="${11:-}" openclaw_exit="${12:-}" trajectory="${13:-}" transcript="${14:-}" metrics_json="${15:-}"
  [ -n "$metrics_json" ] || metrics_json='{}'
  jq -n \
    --arg schemaVersion '1' \
    --arg runId "$run_id" \
    --arg scenarioId "$scenario_id" \
    --arg scenarioName "$name" \
    --arg status "$status" \
    --arg score "$score" \
    --arg duration "$duration" \
    --arg artifactDir "$artifact_dir" \
    --arg sessionId "$session_id" \
    --arg openclawExitStatus "$openclaw_exit" \
    --arg trajectory "$trajectory" \
    --arg transcript "$transcript" \
    --argjson assertions "$assertions_json" \
    --argjson warnings "$warnings_json" \
    --argjson failures "$failures_json" \
    --argjson metrics "$metrics_json" \
    '{schemaVersion:$schemaVersion,runId:$runId,scenarioId:$scenarioId,scenarioName:$scenarioName,status:$status,score:(if $score == "unrated" then null else ($score|tonumber) end),unrated:($score == "unrated"),durationSeconds:($duration|tonumber),assertions:$assertions,toolCalls:{observed:($metrics.toolCalls // null),expectedMin:($metrics.expectedMin // null),expectedMax:($metrics.expectedMax // null),reliable:($metrics.toolCallsReliable // false)},metrics:$metrics,warnings:$warnings,failures:$failures,sessionId:$sessionId,openclawExitStatus:(if $openclawExitStatus == "" then null else ($openclawExitStatus|tonumber) end),artifacts:{directory:$artifactDir,trajectory:(if $trajectory == "" then null else $trajectory end),transcript:(if $transcript == "" then null else $transcript end)}}'
}

qualification_run_openclaw_agent() {
  local session_id="$1" timeout_seconds="$2" prompt_file="$3" output_file="$4"
  local rc=0
  openclaw agent --session-id "$session_id" --timeout "$timeout_seconds" --json --message "$(cat "$prompt_file")" >"$output_file" 2>&1 || rc=$?
  return "$rc"
}

qualification_find_session_files() {
  local session_id="$1" sessions_dir transcript direct_trajectory direct_transcript matches
  sessions_dir="$(qualification_session_dir)"
  REPLY=''
  QUALIFICATION_TRAJECTORY=''
  QUALIFICATION_TRANSCRIPT=''
  QUALIFICATION_EVIDENCE_ERROR=''

  [ -d "$sessions_dir" ] || { QUALIFICATION_EVIDENCE_ERROR="session directory missing: $sessions_dir"; return 1; }

  direct_trajectory="$sessions_dir/$session_id.trajectory.jsonl"
  direct_transcript="$sessions_dir/$session_id.jsonl"
  matches="$(grep -l -- "$session_id" "$sessions_dir"/*.trajectory.jsonl 2>/dev/null || true)"
  if [ -z "$matches" ]; then
    if [ -f "$direct_trajectory" ]; then
      QUALIFICATION_TRAJECTORY="$direct_trajectory"
    else
      QUALIFICATION_EVIDENCE_ERROR='no trajectory found'
      return 1
    fi
  elif [ "$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')" != 1 ]; then
    QUALIFICATION_EVIDENCE_ERROR='multiple trajectories found'
    return 1
  else
    QUALIFICATION_TRAJECTORY="$matches"
  fi

  transcript="${QUALIFICATION_TRAJECTORY%.trajectory.jsonl}.jsonl"
  if [ -f "$direct_transcript" ]; then
    QUALIFICATION_TRANSCRIPT="$direct_transcript"
  elif [ -f "$transcript" ]; then
    QUALIFICATION_TRANSCRIPT="$transcript"
  else
    QUALIFICATION_EVIDENCE_ERROR='transcript missing'
    return 1
  fi
}

qualification_trace_final_status() {
  jq -er 'select(.type=="trace.artifacts") | .data.finalStatus' "$1" | tail -1
}

qualification_trace_tool_count() {
  jq -er 'select(.type=="trace.artifacts") | (.data.toolMetas // [] | length)' "$1" | tail -1
}

qualification_trace_error_json() {
  local trajectory="$1" fallback_status="${2:-unknown}" fallback_message="${3:-}"
  jq -c --arg status "$fallback_status" --arg fallback "$fallback_message" '
    [select(.type=="trace.artifacts") | .data] | last as $data
    | ($data.error // $data.finalError // $data.lastError // null) as $error
    | if ($error | type) == "object" then
        {
          type: (($error.type // $error.code // "agent_error") | tostring),
          message: (($error.message // $error.detail // $fallback // "") | tostring),
          timeout: (($error.timeout // false) == true)
        }
      elif ($data.errorMessage // "") != "" then
        {type:"agent_error", message:($data.errorMessage|tostring), timeout:false}
      elif $status != "success" then
        {type:"agent_status", message:(if $fallback != "" then $fallback else "OpenClaw agent finalStatus=" + $status end), timeout:false}
      else
        {type:null, message:"", timeout:false}
      end
  ' "$trajectory"
}

qualification_final_reply() {
  jq -ers '[.[] | select(.type=="message" and .message.role=="assistant") | [.message.content[]? | select(.type=="text") | .text] | join("")] | last // ""' "$1"
}

qualification_error_result() {
  local run_id="$1" scenario_id="$2" name="$3" artifact_dir="$4" message="$5" session_id="${6:-}" openclaw_exit="${7:-}" trajectory="${8:-}" transcript="${9:-}" duration="${10:-0}"
  local assertions warnings failures
  assertions="$(qualification_assertions_json infrastructure ERROR "$message" tool_correctness)"
  warnings="$(qualification_empty_json_array)"
  failures="$(printf '%s\n' "$message" | qualification_json_string_array)"
  qualification_emit_result "$run_id" "$scenario_id" "$name" ERROR unrated "$duration" "$artifact_dir" "$assertions" "$warnings" "$failures" "$session_id" "$openclaw_exit" "$trajectory" "$transcript" '{}'
}
