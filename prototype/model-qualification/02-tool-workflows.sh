#!/usr/bin/env bash
set -u

ROOT="$HOME/.openclaw/workspace/model-qualification/results/tool-workflows"
SESSIONS="$HOME/.openclaw/agents/main/sessions"
mkdir -p "$ROOT"
find "$ROOT" -maxdepth 1 -type f -delete

RULES='Tool-use rules:
- Use only the tool and arguments required for the task.
- For exec, normally provide only the command field.
- Never set elevated=true unless explicitly requested.
- Do not use web tools for local filesystem tasks.
- Do not retry a successful tool call.
- Never invent, summarize, or paraphrase exact command output.
- After the requested tools succeed, follow the requested reply format exactly.'

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

run_test() {
    local name="$1"
    local prompt="$2"
    local expected_tools="$3"
    local expected_reply="$4"
    local expected_file="${5:-}"
    local expected_content="${6:-}"

    local session="qualify-workflow-${name}-$(date +%s)-$RANDOM"
    local log="$ROOT/$name.log"

    openclaw agent \
        --session-id "$session" \
        --timeout 240 \
        --json \
        --message "$RULES

$prompt" \
        >"$log" 2>&1 || true

    local trajectory
    trajectory=$(get_trajectory "$session")

    if [[ -z "$trajectory" ]]; then
        printf '%-18s FAIL  no trajectory\n' "$name"
        return 1
    fi

    local transcript="${trajectory%.trajectory.jsonl}.jsonl"
    local final_status tools reply file_ok result

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
    file_ok="NA"

    if [[ -n "$expected_file" ]]; then
        if [[ -f "$expected_file" ]] &&
           [[ "$(cat "$expected_file")" == "$expected_content" ]]; then
            file_ok="OK"
        else
            file_ok="FAIL"
        fi
    fi

    result="PASS"
    [[ "$final_status" == "success" ]] || result="FAIL"
    [[ "$tools" == "$expected_tools" ]] || result="FAIL"
    [[ "$reply" == "$expected_reply" ]] || result="FAIL"

    if [[ -n "$expected_file" && "$file_ok" != "OK" ]]; then
        result="FAIL"
    fi

    printf '%-18s %-4s  status=%-7s tools=%-2s file=%-4s reply=%q\n' \
        "$name" "$result" "${final_status:-none}" "${tools:-0}" "$file_ok" "$reply"

    [[ "$result" == "PASS" ]]
}

printf 'The verification code is NCC1701.\n' > "$ROOT/source.txt"
rm -f "$ROOT/missing.txt" "$ROOT/input.txt" "$ROOT/output.txt"
rm -f "$ROOT/numbers.txt" "$ROOT/sorted.txt"

echo
echo "Tool workflows"
echo "--------------"

passes=0
total=5

run_test \
    "exact-output" \
    "Use exec exactly once to run:
printf 'RED\nGREEN\nBLUE\n'

Reply with exactly the complete command output, preserving all lines and adding nothing." \
    "1" \
    $'RED\nGREEN\nBLUE' &&
    passes=$((passes + 1))

run_test \
    "grounded-read" \
    "Use exec exactly once to read:
$ROOT/source.txt

Reply with exactly the verification code and nothing else." \
    "1" \
    "NCC1701" &&
    passes=$((passes + 1))

run_test \
    "absence-check" \
    "Use exec exactly once to determine whether this file exists:
$ROOT/missing.txt

Do not create it. Reply with exactly ABSENT when it does not exist." \
    "1" \
    "ABSENT" &&
    passes=$((passes + 1))

run_test \
    "two-step" \
    "Use exec exactly twice.

First create $ROOT/input.txt containing alpha, beta, and gamma on separate lines.

Second extract the beta line, write it to $ROOT/output.txt, and print it.

Reply with exactly beta." \
    "2" \
    "beta" \
    "$ROOT/output.txt" \
    "beta" &&
    passes=$((passes + 1))

run_test \
    "transform" \
    "Use exec exactly twice.

First create $ROOT/numbers.txt containing 9, 3, and 7 on separate lines.

Second sort the numbers numerically, write the result to $ROOT/sorted.txt, and print the result.

Reply with exactly the printed lines and no Markdown formatting." \
    "2" \
    $'3\n7\n9' \
    "$ROOT/sorted.txt" \
    $'3\n7\n9' &&
    passes=$((passes + 1))

echo "--------------"
printf 'RESULT: %d/%d passed\n' "$passes" "$total"

[[ "$passes" -eq "$total" ]]
