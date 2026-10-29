#!/usr/bin/env bash

# Tests how scripts/restart-dock.sh puts tabs back after a restart: that the
# terminals of a split tab come back as splits of one tab, from the app's
# layout.json, and the rest a tab each. Stand-ins for the opener and the
# holder; no Ghostty, no Claude.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASSED=0
FAILED=0

function usage() {
    cat <<EOM

Tests the split layout a restart puts back. Exits non-zero on any failure.

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
    setup "$tmp"
    # shellcheck source=../scripts/restart-dock.sh
    source "$ROOT/scripts/restart-dock.sh"
    LOG="$tmp/log"

    test_plan "$tmp"
    test_open "$tmp"
    test_split_fails "$tmp"
    test_items "$tmp"

    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

# A home with a stand-in opener, which logs each call to $CALLS and prints
# a new terminal id ("new-<n>").
function setup() {
    export HOME="$1/home"
    export CALLS="$1/calls"
    export GHOSTTY_DOCK_HOLD_BIN="$1/hold"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/state/ghostty-dock/hold" "$HOME/.local/state/ghostty-dock/sessions"
    cat >"$HOME/.local/bin/ghostty-dock-open" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --batch ]; then
    while IFS=$'\t' read -r cmd folder; do echo "tab $cmd" >>"$CALLS"; done
    exit 0
fi
split="" dir="" cmd=""
while [ $# -gt 1 ]; do
    case $1 in
    --split) split=$2; shift ;;
    --direction) dir=$2; shift ;;
    --command) cmd=$2; shift ;;
    esac
    shift
done
n=$(($(wc -l <"$CALLS" 2>/dev/null || echo 0) + 1))
if [ -n "$split" ]; then echo "split $split $dir $cmd" >>"$CALLS"; else echo "tab $cmd" >>"$CALLS"; fi
echo "new-$n"
SH
    chmod +x "$HOME/.local/bin/ghostty-dock-open"
    printf '#!/bin/sh\nprintf "h1\\t11\\t0\\t%%s\\t5\\nh2\\t12\\t1\\t%%s\\t6\\n" "$HOME" "$HOME"\n' >"$GHOSTTY_DOCK_HOLD_BIN"
    chmod +x "$GHOSTTY_DOCK_HOLD_BIN"
}

# A | (B / C), and D alone in a tab (not recorded: no splits).
function layout() {
    echo '{"tabs":[{"d":"right","l":{"s":"A"},"r":{"d":"down","l":{"s":"B"},"r":{"s":"C"}}}]}' >"$1"
}

function test_plan() {
    local file="$1/layout.json"
    layout "$file"
    expect "a split tab is its first terminal, then each split beside the one it was split from" \
        "$(layout_plan "$file" A B C)" $'tab A\nsplit B A right\nsplit C B down'
    expect "a terminal gone is left out of its tab" \
        "$(layout_plan "$file" A C)" $'tab A\nsplit C A right'
    expect "a tab with one terminal left is a plain tab" "$(layout_plan "$file" C)" "tab C"
    expect "terminals in no split tab are not listed" "$(layout_plan "$file" D)" ""
    expect "no layout file, no plan" "$(layout_plan "$1/none.json" A B)" ""
}

function test_open() {
    local file="$1/layout.json"
    layout "$file"
    rm -f "$CALLS"
    open_items "$file" <<<$'A\t'"$HOME"$'\tcmd-a\nB\t'"$HOME"$'\tcmd-b\nC\t'"$HOME"$'\tcmd-c\nD\t'"$HOME"$'\tcmd-d\n-\t'"$HOME"$'\tcmd-x' >/dev/null
    expect "the split tab comes back as one tab, split as before, and the rest a tab each" \
        "$(cat "$CALLS")" $'tab cmd-a\nsplit new-1 right cmd-b\nsplit new-2 down cmd-c\ntab cmd-d\ntab cmd-x'
}

function test_split_fails() {
    local file="$1/bad.json"
    echo '{"tabs":[{"d":"right","l":{"s":"A"},"r":{"s":"B"}}]}' >"$file"
    # A stand-in in front of the stand-in, failing every split.
    local opener="$HOME/.local/bin/ghostty-dock-open"
    mv "$opener" "$opener.real"
    printf '#!/usr/bin/env bash\ncase "$*" in *--split*) exit 1 ;; esac\nexec "%s" "$@"\n' "$opener.real" >"$opener"
    chmod +x "$opener"
    rm -f "$CALLS"
    open_items "$file" <<<$'A\t'"$HOME"$'\tcmd-a\nB\t'"$HOME"$'\tcmd-b' >/dev/null
    mv "$opener.real" "$opener"
    expect "a split that fails opens a tab instead" "$(cat "$CALLS")" $'tab cmd-a\ntab cmd-b'
}

function test_items() {
    local state="$HOME/.local/state/ghostty-dock"
    echo "SURF-1" >"$state/hold/h1.surface"
    expect "a detached holder is reattached in the terminal it was in" \
        "$(held_items)" "SURF-1"$'\t'"$HOME"$'\t'"'$GHOSTTY_DOCK_HOLD_BIN' attach h1"
    echo '{"session_id":"sid-1"}' >"$state/sessions/srf-OLD.json"
    touch -t 202001010000 "$state/sessions/srf-OLD.json"
    echo '{"session_id":"sid-1"}' >"$state/sessions/srf-NEW.json"
    expect "a session's terminal is the last it was in" "$(session_surface sid-1)" "NEW"
    expect "a session never seen has no terminal" "$(session_surface sid-2)" ""
}

function expect() {
    if [ "$2" = "$3" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  got:      %s\n  expected: %s\n' "$1" "$2" "$3"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
