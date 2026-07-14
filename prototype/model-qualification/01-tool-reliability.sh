#!/usr/bin/env bash
set -u

ROOT="$HOME/.openclaw/workspace/model-qualification/results/tool-reliability"
SESSIONS="$HOME/.openclaw/agents/main/sessions"
mkdir -p "$ROOT"
find "$ROOT" -maxdepth 1 -type f -delete

RULES='Tool-use rules:
- Use only the tool and arguments required for the task.
- For exec, normally provide only the command field.
- Never set elevated=true unless explicitly requested.
- Do not retry a successful tool call.
- Do not invent tool results.
- After the tool succeeds, follow the requested reply format exactly.'

get_trajectory() {
    local session="$1"
    grep -l -- "$session" "$SESSIONS"/*.trajectory.jsonl 2>/dev/null |
        head -1
}

get_reply() {
    local transcript="$1"
    jq -rs '
      [
        .[]
        | select(.type=="message" and .message.role=="assistant")
        | [
            .message.content[]?
            | select(.type=="text")
            | .text
          ]
        | join("")
      ]
      | last // ""
    ' "$transcript"
}

passes=0
total=10

echo
echo "Tool reliability"
echo "----------------"

for n in $(seq 1 "$total"); do
    file="$ROOT/test-$n.txt"
    session="qualify-tool-$n-$(date +%s)-$RANDOM"
    log="$ROOT/test-$n.log"

    rm -f "$file"

    openclaw agent \
        --session-id "$session" \
        --timeout 180 \
        --json \
        --message "$RULES

Use exec exactly once to create:
$file

The file must contain exactly:
PASS_$n

After the tool succeeds, reply with exactly:
DONE" \
        >"$log" 2>&1 || true

    trajectory=$(get_trajectory "$session")

    if [[ -z "$trajectory" ]]; then
        printf '%2d  FAIL  no trajectory\n' "$n"
        continue
    fi

    transcript="${trajectory%.trajectory.jsonl}.jsonl"

    final_status=$(
        jq -r '
          select(.type=="trace.artifacts")
          | .data.finalStatus
        ' "$trajectory" |
        tail -1
    )

    tools=$(
        jq -r '
          select(.type=="trace.artifacts")
          | (.data.toolMetas // [] | length)
        ' "$trajectory" |
        tail -1
    )

    reply=$(get_reply "$transcript")

    file_ok=false
    if [[ -f "$file" ]] && [[ "$(cat "$file")" == "PASS_$n" ]]; then
        file_ok=true
    fi

    if [[ "$final_status" == "success" ]] &&
       [[ "$tools" == "1" ]] &&
       [[ "$file_ok" == true ]] &&
       [[ "$reply" == "DONE" ]]; then
        printf '%2d  PASS  tools=%s\n' "$n" "$tools"
        passes=$((passes + 1))
    else
        printf '%2d  FAIL  status=%s tools=%s file=%s reply=%q\n' \
            "$n" "${final_status:-none}" "${tools:-0}" "$file_ok" "$reply"
    fi
done

echo "----------------"
printf 'RESULT: %d/%d passed\n' "$passes" "$total"

[[ "$passes" -eq "$total" ]]
