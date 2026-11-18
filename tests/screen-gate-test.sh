#!/usr/bin/env bash

# Tests bin/ghostty-dock-screen-gate: read-only tools and the off switch go
# straight through; an acting tool waits for the pause, says what it will
# do, and then has a lease; "Go Now" and "Not Now" answer it. The idle time
# comes from a file, so nothing reads the real keyboard.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE="$ROOT/bin/ghostty-dock-screen-gate"
PASSED=0
FAILED=0

function usage() {
    cat <<EOM

Tests the screen gate hook. Exits non-zero on any failure.

usage: ${SCRIPT_NAME}

EOM
    exit 1
}

function check() {
    local name=$1 got=$2 want=$3
    if [ "$got" = "$want" ]; then
        echo "PASS $name"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL $name: got '$got', want '$want'"
        FAILED=$((FAILED + 1))
    fi
}

function hook_json() {
    jq -cn --arg tool "$1" --argjson input "${2:-{\}}" --arg sid "${3:-s1}" \
        '{session_id: $sid, cwd: "/tmp/demo-repo", tool_name: $tool, tool_input: $input}'
}

# Runs the gate with idle seconds $1 and the hook JSON $2; prints
# "<seconds taken> <stdout>", the seconds as 0 when under 2 (no wait).
function run_gate() {
    echo "$1" >"$TMP/idle"
    local t0 out
    t0=$(date +%s)
    out=$(GHOSTTY_DOCK_STATE="$TMP/state" GHOSTTY_DOCK_TEST_IDLE="$TMP/idle" GHOSTTY_DOCK_SCREEN_QUIET=10 \
        "$GATE" <<<"$2")
    local took=$(($(date +%s) - t0))
    ((took < 2)) && took=0
    echo "$took $out"
}

function main() {
    [ $# -eq 0 ] || usage
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/state"

    local r
    r=$(run_gate 0 "$(hook_json mcp__claude-in-chrome__read_page)")
    check "read-only tool goes straight on" "$r" "0 "
    r=$(run_gate 0 "$(hook_json mcp__claude-in-chrome__computer '{"action":"screenshot"}')")
    check "screenshot goes straight on" "$r" "0 "

    touch "$TMP/state/screen-gate-off"
    r=$(run_gate 0 "$(hook_json mcp__claude-in-chrome__navigate '{"url":"https://example.com"}')")
    check "off switch lets it through" "$r" "0 "
    rm -f "$TMP/state/screen-gate-off"

    r=$(run_gate 30 "$(hook_json mcp__claude-in-chrome__navigate '{"url":"https://example.com"}')")
    check "already quiet: shows the panel briefly (3s), then goes" \
        "$(case "${r%% *}" in 3 | 4) echo ok ;; *) echo "${r%% *}s" ;; esac)" "ok"

    r=$(run_gate 0 "$(hook_json mcp__claude-in-chrome__computer '{"action":"left_click"}')")
    check "same session straight after has the lease" "$r" "0 "

    # Typing: the gate waits, and the wait file says what it is for.
    echo 0 >"$TMP/idle"
    GHOSTTY_DOCK_STATE="$TMP/state" GHOSTTY_DOCK_TEST_IDLE="$TMP/idle" GHOSTTY_DOCK_SCREEN_QUIET=10 \
        "$GATE" <<<"$(hook_json mcp__playwright__browser_navigate '{"url":"https://example.org/a"}' s2)" \
        >"$TMP/out2" &
    local pid=$!
    sleep 1.5
    check "wait file names the action" "$(jq -r .what "$TMP/state/screen-wait/s2.json" 2>/dev/null)" \
        "Browser: navigate https://example.org/a"
    check "wait file names the session" "$(jq -r .name "$TMP/state/screen-wait/s2.json" 2>/dev/null)" "demo-repo"
    sleep 3
    check "still waiting while typing" "$(kill -0 $pid 2>/dev/null && echo waiting)" "waiting"
    echo 12 >"$TMP/idle"
    sleep 1.5
    check "goes once the pause comes" "$(kill -0 $pid 2>/dev/null && echo waiting || echo gone)" "gone"
    check "wait file removed" "$(ls "$TMP/state/screen-wait/s2.json" 2>/dev/null)" ""
    wait $pid

    # Not Now: denied with a reason.
    echo 0 >"$TMP/idle"
    GHOSTTY_DOCK_STATE="$TMP/state" GHOSTTY_DOCK_TEST_IDLE="$TMP/idle" GHOSTTY_DOCK_SCREEN_QUIET=10 \
        "$GATE" <<<"$(hook_json mcp__claude-in-chrome__form_input '{}' s3)" >"$TMP/out3" &
    pid=$!
    sleep 1
    touch "$TMP/state/screen-wait/s3.stop"
    wait $pid
    check "Not Now denies" "$(jq -r .hookSpecificOutput.permissionDecision "$TMP/out3")" "deny"

    # Go Now: through at once, before the pause.
    GHOSTTY_DOCK_STATE="$TMP/state" GHOSTTY_DOCK_TEST_IDLE="$TMP/idle" GHOSTTY_DOCK_SCREEN_QUIET=10 \
        "$GATE" <<<"$(hook_json mcp__claude-in-chrome__form_input '{}' s4)" >"$TMP/out4" &
    pid=$!
    sleep 1
    touch "$TMP/state/screen-wait/s4.go"
    sleep 1
    check "Go Now lets it through" "$(kill -0 $pid 2>/dev/null && echo waiting || cat "$TMP/out4")" ""

    echo "passed: $PASSED, failed: $FAILED"
    [ "$FAILED" -eq 0 ]
}

main "$@"
