#!/usr/bin/env bash

# Drives bin/ghostty-dock-hook through a session's life with fake hook JSON
# and checks the state file after each step. No Claude, no Ghostty.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$ROOT/bin/ghostty-dock-hook"
PASSED=0
FAILED=0

function usage() {
    cat <<EOM

Tests the Ghostty Dock Claude Code hook. Exits non-zero on any failure.

usage: ${SCRIPT_NAME}

EOM
    exit 1
}

function main() {
    case "${1:-}" in
    -h | --help) usage ;;
    esac
    command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

    local state
    state=$(mktemp -d)
    trap 'rm -rf "$state"' EXIT
    export GHOSTTY_DOCK_STATE="$state"
    export GHOSTTY_DOCK_TEST_LINEAGE="111 222 ttys009"
    unset DOCK_TAB_ID GHOSTTY_DOCK_SURFACE

    local f="$state/sessions/tty-ttys009.json"

    fire '{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/x/my-proj","source":"startup"}'
    check "start is idle" "$f" '.status' "idle"
    check "name from folder" "$f" '.name' "my-proj"
    check "pids recorded" "$f" '"\(.claude_pid) \(.ghostty_pid) \(.tty)"' "111 222 ttys009"

    fire '{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/x/my-proj"}'
    check "prompt is running" "$f" '.status' "running"
    local since
    since=$(jq -r .since "$f")

    fire '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/my-proj/sub","tool_name":"Bash"}'
    check "tool keeps running" "$f" '.status' "running"
    check "since kept while status unchanged" "$f" '.since|tostring' "$since"
    check "project sticks when Claude cds" "$f" '.name' "my-proj"

    fire '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/my-proj","tool_name":"AskUserQuestion"}'
    check "question is waiting" "$f" '.status' "waiting"

    fire '{"hook_event_name":"PostToolUse","session_id":"s1","cwd":"/x/my-proj","tool_name":"AskUserQuestion"}'
    check "answer resumes running" "$f" '.status' "running"

    fire '{"hook_event_name":"Notification","session_id":"s1","cwd":"/x/my-proj","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
    check "permission prompt is waiting" "$f" '.status' "waiting"

    fire '{"hook_event_name":"Stop","session_id":"s1","cwd":"/x/my-proj"}'
    check "stop is done" "$f" '.status' "done"

    fire '{"hook_event_name":"Notification","session_id":"s1","cwd":"/x/my-proj","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
    check "idle reminder changes nothing" "$f" '.status' "done"

    local created
    created=$(jq -r .created "$f")
    fire '{"hook_event_name":"SessionEnd","session_id":"s1","cwd":"/x/my-proj","reason":"clear"}'
    check "clear keeps the row" "$f" '.status' "done"
    fire '{"hook_event_name":"SessionStart","session_id":"s2","cwd":"/x/my-proj","source":"clear"}'
    check "new session after clear is idle" "$f" '.status' "idle"
    check "row keeps its place after clear" "$f" '.created|tostring' "$created"

    fire '{"hook_event_name":"SessionEnd","session_id":"s2","cwd":"/x/my-proj","reason":"prompt_input_exit"}'
    if [ -e "$f" ]; then fail "exit removes the row"; else pass "exit removes the row"; fi

    DOCK_TAB_ID="abc-123" fire '{"hook_event_name":"UserPromptSubmit","session_id":"s3","cwd":"/y/other"}'
    check "dock tab id is the key" "$state/sessions/tab-abc-123.json" '.dock_tab_id' "abc-123"

    GHOSTTY_DOCK_SURFACE="0A1B-2C3D" DOCK_TAB_ID="abc-123" fire '{"hook_event_name":"UserPromptSubmit","session_id":"s5","cwd":"/y/other"}'
    check "surface id beats dock tab id" "$state/sessions/srf-0A1B-2C3D.json" '.status' "running"

    # A stock Ghostty (here: this shell) started from a Dock tab inherits its ids.
    GHOSTTY_DOCK_TEST_LINEAGE="333 $$ ttys008" GHOSTTY_DOCK_SURFACE="0A1B-2C3D" DOCK_TAB_ID="abc-123" \
        fire '{"hook_event_name":"Stop","session_id":"s6","cwd":"/w/undocked"}'
    check "ids inherited outside Ghostty Dock are ignored" "$state/sessions/tty-ttys008.json" '.name' "undocked"
    check "inherited ids leave the Dock row alone" "$state/sessions/srf-0A1B-2C3D.json" '.status' "running"

    GHOSTTY_DOCK_TEST_LINEAGE="- - -" fire '{"hook_event_name":"Stop","session_id":"s4","cwd":"/z"}'
    check "no terminal falls back to session id" "$state/sessions/sid-s4.json" '.status' "done"

    local out
    out=$(echo 'not json' | "$HOOK"; echo "rc=$?")
    if [ "$out" = "rc=0" ]; then pass "bad input is silent and exits 0"; else fail "bad input is silent and exits 0 (got: $out)"; fi

    echo "${PASSED} passed, ${FAILED} failed"
    [ "$FAILED" -eq 0 ] || exit 1
}

function fire() {
    local out
    out=$(printf '%s' "$1" | "$HOOK")
    [ -z "$out" ] || fail "hook printed output: $out"
}

function check() {
    local name="$1"
    local file="$2"
    local filter="$3"
    local want="$4"
    local got
    got=$(jq -r "$filter" "$file" 2>/dev/null)
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name (want '$want', got '$got')"; fi
}

function pass() {
    PASSED=$((PASSED + 1))
    echo "  ok   $1"
}

function fail() {
    FAILED=$((FAILED + 1))
    echo "  FAIL $1" >&2
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
