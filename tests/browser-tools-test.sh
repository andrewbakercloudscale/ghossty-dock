#!/usr/bin/env bash

# Tests what tells Claude Code about the browser beside a tab, and the tools
# it drives it with: bin/ghostty-dock-context (the SessionStart note),
# bin/ghostty-dock-browser-mcp (the MCP launcher) and bin/ghostty-dock-browse
# ($BROWSER), with stand-ins for the app, npx, curl and open. No Claude, no
# Ghostty, no Chromium.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONTEXT="$ROOT/bin/ghostty-dock-context"
MCP="$ROOT/bin/ghostty-dock-browser-mcp"
BROWSE="$ROOT/bin/ghostty-dock-browse"
DOCK="$ROOT/bin/ghostty-dock"
START='{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}'
PASSED=0
FAILED=0

function usage() {
    cat <<EOM

Tests the browser note and the dock-browser MCP launcher. Exits non-zero on
any failure.

usage: ${SCRIPT_NAME}

EOM
    exit 1
}

function main() {
    case "${1:-}" in
    -h | --help) usage ;;
    esac
    command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    test_context "$tmp"
    test_browse "$tmp"
    test_url "$tmp"
    if command -v node >/dev/null; then
        test_mcp "$tmp"
        test_retype
    else
        echo "  skip the MCP launcher: node is not installed"
    fi

    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

function test_context() {
    local bin="$1/bin"
    mkdir -p "$bin" && printf '#!/bin/sh\n' >"$bin/ghostty-dock-browser-mcp" && chmod +x "$bin/ghostty-dock-browser-mcp"
    local out

    out=$(env -u GHOSTTY_DOCK_HOLD -u GHOSTTY_DOCK_SURFACE GHOSTTY_DOCK_BIN="$bin" "$CONTEXT" <<<"$START")
    expect "outside Ghostty Dock it says nothing" "$out" ""

    out=$(GHOSTTY_DOCK_HOLD=abc123 GHOSTTY_DOCK_BIN="$bin" "$CONTEXT" <<<"$START")
    expect "in a held dock tab it is a SessionStart note" \
        "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>/dev/null)" "SessionStart"
    expect "the note names the dock-browser tools" \
        "$(jq -r '.hookSpecificOutput.additionalContext | test("mcp__dock-browser__")' <<<"$out" 2>/dev/null)" "true"
    expect "the note tells it about the file viewer" \
        "$(jq -r '.hookSpecificOutput.additionalContext | test("ghostty-dock view")' <<<"$out" 2>/dev/null)" "true"
    expect "the note warns off the user's Chrome" \
        "$(jq -r '.hookSpecificOutput.additionalContext | test("9222")' <<<"$out" 2>/dev/null)" "true"

    out=$(env -u GHOSTTY_DOCK_HOLD GHOSTTY_DOCK_SURFACE=5FDBC1A7 GHOSTTY_DOCK_BIN="$bin" \
        GHOSTTY_DOCK_TEST_APP="/Users/x/Applications/Ghostty Dock.app/Contents/MacOS/ghostty" "$CONTEXT" <<<"$START")
    expect "in a terminal of the app it is a note too" \
        "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>/dev/null)" "SessionStart"
    out=$(env -u GHOSTTY_DOCK_HOLD GHOSTTY_DOCK_SURFACE=5FDBC1A7 GHOSTTY_DOCK_BIN="$bin" \
        GHOSTTY_DOCK_TEST_APP="/Applications/Ghostty.app/Contents/MacOS/ghostty" "$CONTEXT" <<<"$START")
    expect "a stock Ghostty with a dock tab's ids says nothing" "$out" ""

    out=$(GHOSTTY_DOCK_HOLD=abc123 GHOSTTY_DOCK_BIN="$1/none" "$CONTEXT" <<<"$START")
    expect "without the browser tools installed it says nothing" "$out" ""

    GHOSTTY_DOCK_HOLD=abc123 GHOSTTY_DOCK_BIN="$bin" "$CONTEXT" </dev/null >/dev/null
    expect "it always exits 0" "$?" "0"
}

# The launcher runs ~/.local/bin/ghostty-dock and `npx chrome-devtools-mcp`;
# here both are stand-ins that log how they were called, and npx echoes back
# what it is sent, as the server's answers.
function test_mcp() {
    local home="$1/home" fake="$1/fake" log="$1/calls"
    mkdir -p "$home/.local/bin" "$fake"
    cat >"$home/.local/bin/ghostty-dock" <<EOF
#!/bin/sh
echo "dock \$*" >>"$log"
EOF
    cat >"$fake/npx" <<EOF
#!/bin/sh
echo "npx \$*" >>"$log"
exec cat
EOF
    # No page until the browser has been asked for once.
    cat >"$fake/curl" <<EOF
#!/bin/sh
grep -q '^dock browser' "$log" 2>/dev/null && echo '[{"type":"page"}]'
EOF
    chmod +x "$home/.local/bin/ghostty-dock" "$fake/npx" "$fake/curl"

    local messages out
    messages=$(printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
        '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"take_screenshot"}}' \
        '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"click"}}' \
        '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"new_page"}}')
    out=$(HOME="$home" PATH="$fake:$PATH" node "$MCP" <<<"$messages")

    expect "every message reaches the server, in order" "$(jq -r .id <<<"$out" | tr '\n' ' ')" "1 2 3 4 5 "
    expect "the server is chrome-devtools-mcp, through the relay" \
        "$(grep '^npx' "$log" | sed -E 's/:[0-9]+$/:PORT/')" "npx -y chrome-devtools-mcp@1.11.0 --browserUrl http://127.0.0.1:PORT"
    expect "the browser is started at the first tool call and for new_page only" \
        "$(grep -c '^dock browser' "$log")" "2"
}

# A page CEF is still making is announced as one; nothing else changes.
function test_retype() {
    local got
    got=$(node -e '
        const { retype } = require(process.argv[1]);
        const cases = [
            {method: "Target.targetCreated", params: {targetInfo: {type: "other", url: ""}}},
            {method: "Target.attachedToTarget", params: {targetInfo: {type: "other", url: ""}}},
            {id: 1, result: {targetInfos: [{type: "other", url: ""}, {type: "other", url: "chrome://x"}]}},
            {method: "Target.targetCreated", params: {targetInfo: {type: "worker", url: ""}}},
        ];
        console.log(cases.map(c => JSON.stringify(JSON.parse(retype(JSON.stringify(c))))).join("\n"));
        console.log(retype("not json \"other\""));
    ' "$MCP")
    expect "a page being made is announced as a page" "$(sed -n 1p <<<"$got" | jq -r .params.targetInfo.type)" "page"
    expect "also when attached to" "$(sed -n 2p <<<"$got" | jq -r .params.targetInfo.type)" "page"
    expect "and in a target list, where an other with an address stays" \
        "$(sed -n 3p <<<"$got" | jq -r '[.result.targetInfos[].type] | join(",")')" "page,other"
    expect "other types are left alone" "$(sed -n 4p <<<"$got" | jq -r .params.targetInfo.type)" "worker"
    expect "what is not JSON passes as it is" "$(sed -n 5p <<<"$got")" 'not json "other"'
}

# $BROWSER: web links go to the app, the rest (and all of them when the app
# does not answer) to open.
function test_browse() {
    local bin="$1/browse" log="$1/browse.log"
    mkdir -p "$bin"
    printf '#!/bin/sh\necho "dock $*" >>"%s"\n[ -z "$DOCK_DOWN" ]\n' "$log" >"$bin/ghostty-dock"
    printf '#!/bin/sh\necho "open $*" >>"%s"\n' "$log" >"$bin/open"
    chmod +x "$bin/ghostty-dock" "$bin/open"

    PATH="$bin:$PATH" GHOSTTY_DOCK_BIN="$bin" "$BROWSE" https://example.com/a "mailto:x@example.com"
    expect "a web link goes to the dock, anything else to open" "$(cat "$log")" \
        "$(printf 'dock url https://example.com/a\nopen mailto:x@example.com')"
    rm -f "$log"
    PATH="$bin:$PATH" GHOSTTY_DOCK_BIN="$bin" DOCK_DOWN=1 "$BROWSE" http://localhost:3000
    expect "with the app not answering it opens as before" "$(cat "$log")" \
        "$(printf 'dock url http://localhost:3000\nopen http://localhost:3000')"
}

# ghostty-dock url: the request the app gets, and what it refuses itself.
function test_url() {
    local state="$1/state"
    mkdir -p "$state/api"
    (
        for _ in $(seq 100); do
            for req in "$state"/api/req-*.json; do
                [ -f "$req" ] || continue
                cp "$req" "$state/got.json"
                printf '{"ok":true,"url":"https://example.com/"}' >"${req/req-/res-}"
                rm -f "$req"
                exit 0
            done
            sleep 0.05
        done
    ) &
    local out
    out=$(GHOSTTY_DOCK_STATE="$state" GHOSTTY_DOCK_SURFACE=S1 "$DOCK" url https://example.com/)
    wait
    expect "ghostty-dock url prints the page" "$out" "https://example.com/"
    expect "and asks for it beside this terminal" "$(jq -c . "$state/got.json")" \
        '{"op":"url","url":"https://example.com/","surface":"S1"}'
    GHOSTTY_DOCK_STATE="$state" "$DOCK" url file:///etc/passwd 2>/dev/null
    expect "a link that is not http is refused" "$?" "1"
}

function expect() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$3', got '$2')"; fi
}

function pass() {
    PASSED=$((PASSED + 1))
    echo "  ok   $1"
}

function fail() {
    FAILED=$((FAILED + 1))
    echo "  FAIL $1"
}

main "$@"
