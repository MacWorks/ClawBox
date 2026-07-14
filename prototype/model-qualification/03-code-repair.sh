#!/usr/bin/env bash
set -u

BASE="$HOME/.openclaw/workspace/model-qualification/results"
PROJECT="$BASE/code-repair-project"
LOGS="$BASE/code-repair-logs"
SESSIONS="$HOME/.openclaw/agents/main/sessions"

rm -rf "$PROJECT" "$LOGS"
mkdir -p "$PROJECT" "$LOGS"

cat > "$PROJECT/calculator.sh" <<'EOF'
#!/usr/bin/env bash

add() {
    echo $(( $1 - $2 ))
}

add "$1" "$2"
EOF

cat > "$PROJECT/test.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

actual=$(./calculator.sh 7 5)

if [[ "$actual" != "12" ]]; then
    printf 'FAIL: expected 12, got %s\n' "$actual"
    exit 1
fi

echo "PASS"
EOF

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

session="qualify-code-repair-$(date +%s)-$RANDOM"

openclaw agent \
    --session-id "$session" \
    --timeout 300 \
    --json \
    --message "$RULES

Project directory:
$PROJECT

The supplied test currently fails.

Diagnose the defect, make the smallest appropriate correction, and run the test.

When finished, report:
1. The root cause.
2. The file changed.
3. The exact final test result." \
    >"$LOGS/agent-output.json" 2>&1 || true

trajectory=$(
    grep -l -- "$session" "$SESSIONS"/*.trajectory.jsonl 2>/dev/null |
    head -1
)

final_status="none"
tools=0

if [[ -n "$trajectory" ]]; then
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
fi

if (
    cd "$PROJECT"
    ./test.sh >"$LOGS/test-output.txt" 2>&1
); then
    test_result="PASS"
else
    test_result="FAIL"
fi

changed_files=$(
    cd "$PROJECT"
    git status --porcelain
)

calculator_valid=false
if bash -n "$PROJECT/calculator.sh" &&
   grep -Fq 'echo $(( $1 + $2 ))' "$PROJECT/calculator.sh"; then
    calculator_valid=true
fi

scope_valid=false
if [[ "$changed_files" == " M calculator.sh" ]]; then
    scope_valid=true
fi

overall="PASS"
[[ "$final_status" == "success" ]] || overall="FAIL"
[[ "$test_result" == "PASS" ]] || overall="FAIL"
[[ "$calculator_valid" == true ]] || overall="FAIL"
[[ "$scope_valid" == true ]] || overall="FAIL"

echo
echo "Code repair"
echo "-----------"
printf 'RESULT:       %s\n' "$overall"
printf 'Agent status: %s\n' "$final_status"
printf 'Tool calls:   %s\n' "$tools"
printf 'Test:         %s\n' "$test_result"
printf 'Valid code:   %s\n' "$calculator_valid"
printf 'Change scope: %s\n' "$scope_valid"

echo
echo "Changed files:"
printf '%s\n' "${changed_files:-none}"

echo
echo "Test output:"
cat "$LOGS/test-output.txt"

echo
echo "Diff:"
(
    cd "$PROJECT"
    git diff -- calculator.sh test.sh
)

[[ "$overall" == "PASS" ]]
