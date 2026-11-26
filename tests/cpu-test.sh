#!/usr/bin/env bash

# CPU budget for what the app runs in the background while you work: the
# session save (ghostty-dock-restart --save) and the dock-a-window check
# (ghostty-dock-move --list). Counts the processes each one starts, times its
# CPU, and works out the processes a second the app's timers add up to, so a
# change that brings back a polling loop fails here instead of on the Mac
# (2026-11-26: up to 6 a second from the save alone, 15% of a core).
#
# A sandbox home with stand-ins: an "app" and a holder running fake claudes.
# Nothing of the real Dock is read or written.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DOCK_SRC="$ROOT/vendor/ghostty/macos/Sources/Features/Dock"
PASSED=0
FAILED=0

# Processes one steady save may start (the first sees each claude once more).
SAVE_PROCS_MAX=12
# CPU seconds (user + system) for one save, best of three.
SAVE_CPU_MAX=0.4
MOVE_PROCS_MAX=4
# All of the app's background work together, at steady state: with a stock
# Ghostty open (the window check runs), and without (it does not).
RATE_MAX=1.0
IDLE_RATE_MAX=0.3

TOOLS="ps awk sed grep cat ls find date tr cut sort head tail lsof jq xargs mv rm mkdir basename dirname env wc stat pgrep python3 ioreg defaults"

function usage() {
    cat <<EOM

Checks the CPU and process budget of the Dock's background work. Exits
non-zero when over it.

usage: ${SCRIPT_NAME}

EOM
    exit 1
}

function main() {
    case "${1:-}" in
    -h | --help) usage ;;
    esac
    command -v cc >/dev/null || { echo "cc is required (Xcode command line tools)" >&2; exit 1; }

    local tmp
    tmp=$(mktemp -d)
    PIDS=()
    trap 'cleanup "$tmp"' EXIT
    setup "$tmp"

    test_save "$tmp"
    test_move "$tmp"
    test_rate

    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

function cleanup() {
    local p
    for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    rm -rf "$1"
}

# The sandbox: a home, a running "app" (a sleep under the app's path), a
# holder with 8 fake claudes, their hook state, and a shim for each tool
# that notes each start in $COUNT.
function setup() {
    local tmp="$1" t real i
    export HOME="$tmp/home"
    export COUNT="$tmp/count"
    export GHOSTTY_DOCK_HOLD_BIN="$tmp/hold"
    APP_BIN="$HOME/Applications/Ghostty Dock.app/Contents/MacOS/ghostty"
    local state="$HOME/.local/state/ghostty-dock"
    mkdir -p "$(dirname "$APP_BIN")" "$state/sessions" "$state/hold" "$tmp/bin" "$tmp/shims" "$tmp/work"

    printf 'int main(void){for(;;)pause();}\n' >"$tmp/claude.c"
    cc -o "$tmp/bin/claude" "$tmp/claude.c" -include unistd.h || exit 1

    bash -c 'exec -a "$1" sleep 600' _ "$APP_BIN" &
    PIDS+=($!)
    (
        for i in 1 2 3 4 5 6 7 8; do
            (cd "$tmp/work" && exec "$tmp/bin/claude" --session-id "0000000$i-0000-4000-8000-000000000000" \
                --remote-control "tab $i") &
        done
        wait
    ) &
    local holder=$!
    PIDS+=("$holder")
    sleep 0.5
    for i in 1 2 3 4 5 6 7 8; do
        printf '{"session_id":"0000000%s-0000-4000-8000-000000000000","claude_pid":%s,"status":"idle"}\n' \
            "$i" "$(pgrep -f "^$tmp/bin/claude --session-id 0000000$i-" | head -1)" >"$state/sessions/s$i.json"
    done
    cat >"$GHOSTTY_DOCK_HOLD_BIN" <<SH
#!/bin/bash
echo hold >>"\$COUNT"
printf 'h1\t%s\t1\t%s\t5\n' "$holder" "$tmp/work"
SH
    chmod +x "$GHOSTTY_DOCK_HOLD_BIN"

    for t in $TOOLS; do
        real=$(command -v "$t") || continue
        printf '#!/bin/bash\necho %s >>"$COUNT"\nexec %q "$@"\n' "$t" "$real" >"$tmp/shims/$t"
        chmod +x "$tmp/shims/$t"
    done
    SHIMS="$tmp/shims"
}

# Processes started by one run of a command, from the shims' notes.
function procs_of() {
    rm -f "$COUNT"
    PATH="$SHIMS:$PATH" "$@" >/dev/null 2>&1
    grep -c . "$COUNT" 2>/dev/null || echo 0
}

# CPU seconds (user + system, the command and all it started) of one run.
function cpu_of() {
    LC_ALL=C /usr/bin/time -p "$@" 2>&1 >/dev/null | LC_ALL=C awk '$1 == "user" || $1 == "sys" { t += $2 } END { printf "%.2f", t }'
}

function test_save() {
    local tmp="$1" n cpu best=99 i
    local save=(/bin/bash "$ROOT/scripts/restart-dock.sh" --save)
    # The first save describes each claude (lsof, python) and caches it.
    procs_of "${save[@]}" >/dev/null
    expect "the save finds the 8 sessions" "$(grep -c . "$HOME/.local/state/ghostty-dock/open-sessions.tsv" 2>/dev/null)" 8
    n=$(procs_of "${save[@]}")
    SAVE_PROCS=$n
    sort "$COUNT" | uniq -c | sort -rn | awk '{ printf "    %s %s\n", $1, $2 }'
    under "a steady save starts at most $SAVE_PROCS_MAX processes" "$n" "$SAVE_PROCS_MAX"
    for i in 1 2 3; do
        cpu=$(cpu_of "${save[@]}")
        best=$(LC_ALL=C awk -v a="$cpu" -v b="$best" 'BEGIN { print (a < b) ? a : b }')
    done
    under "a save takes at most ${SAVE_CPU_MAX}s of CPU" "$best" "$SAVE_CPU_MAX"
}

function test_move() {
    local n
    n=$(procs_of /bin/bash "$ROOT/scripts/move-to-dock.sh" --list)
    MOVE_PROCS=$n
    under "the dock-a-window check starts at most $MOVE_PROCS_MAX processes" "$n" "$MOVE_PROCS_MAX"
}

# The app's timers, from its source: the save every heartbeat when nothing
# changes, the dock-a-window check every moveTimer.
function test_rate() {
    local beat move rate
    beat=$(sed -nE 's/.*static let heartbeat: TimeInterval = ([0-9.]+).*/\1/p' "$DOCK_SRC/DockSaveSchedule.swift")
    move=$(sed -nE 's/.*moveTimer = Timer.scheduledTimer\(withTimeInterval: ([0-9.]+).*/\1/p' "$DOCK_SRC/DockSessions.swift")
    expect "the save is paced by DockSaveSchedule" \
        "$(grep -c 'saveSchedule.due' "$DOCK_SRC/DockSessions.swift")" 1
    expect "the window check runs only with a stock Ghostty open or a move under way" \
        "$(grep -c 'let needed = Self.stockGhosttyRunning() || Self.moveJobsPending()' "$DOCK_SRC/DockSessions.swift")" 1
    if [ -z "$beat" ] || [ -z "$move" ]; then
        FAILED=$((FAILED + 1))
        echo "FAIL: could not read the timers' intervals from the app's source"
        return
    fi
    # Each run is also a bash of its own.
    rate=$(LC_ALL=C awk -v s="$SAVE_PROCS" -v b="$beat" -v m="$MOVE_PROCS" -v t="$move" \
        'BEGIN { printf "%.2f", (s + 1) / b + (m + 1) / t }')
    echo "    background: $rate processes a second (save every ${beat}s, window check every ${move}s)"
    under "with a stock Ghostty open, at most $RATE_MAX processes a second" "$rate" "$RATE_MAX"
    rate=$(LC_ALL=C awk -v s="$SAVE_PROCS" -v b="$beat" 'BEGIN { printf "%.2f", (s + 1) / b }')
    under "without, at most $IDLE_RATE_MAX processes a second" "$rate" "$IDLE_RATE_MAX"
}

function under() {
    if LC_ALL=C awk -v a="$2" -v b="$3" 'BEGIN { exit !(a <= b) }'; then
        PASSED=$((PASSED + 1))
        printf 'ok: %s (%s)\n' "$1" "$2"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  got: %s\n' "$1" "$2"
    fi
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
