#!/usr/bin/env bash

# Moves every Claude Code session still running in its own stock Ghostty app
# into a tab of Ghostty Dock: stops claude once its transcript has been quiet
# for a while, closes that Ghostty, and reopens `claude --resume <id>` with the
# same flags (so --remote-control keeps its name) as a Ghostty Dock tab.
#
# A session that is busy is waited for, never interrupted. Run it detached
# (--detach) when the calling session is one of those being moved.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="$HOME/.local/state/ghostty-dock"
LOG="$STATE_DIR/move-to-dock.log"
OPENER="$HOME/.local/bin/ghostty-dock-open"
GHOSTTY_BIN="/Applications/Ghostty.app/Contents/MacOS/ghostty"
QUIET_SECS=60
GIVE_UP_SECS=$((12 * 3600))

function usage() {
    cat <<EOM

Moves Claude Code sessions from separate Ghostty apps into Ghostty Dock tabs.

usage: ${SCRIPT_NAME} [options]

options:
    --detach       Run in the background under launchd and return at once
    --dry-run      Only list what would move
    -h|--help      Show this help message

EOM
    exit 1
}

function log() {
    echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"
}

# Prints "<claude pid>" for the claude running under a Ghostty pid.
function claude_under() {
    local root="$1"
    ps -axo pid=,ppid=,command= | awk -v root="$root" '
        { parent[$1] = $2; cmd[$1] = $0 }
        END {
            for (p in cmd) {
                if (cmd[p] !~ /[0-9]+ +[0-9]+ +claude --session-id/) continue
                q = p
                while (q > 1) { q = parent[q]; if (q == root) { print p; exit } }
            }
        }'
}

function transcript_for() {
    local cwd="$1"
    local sid="$2"
    echo "$HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$cwd")/$sid.jsonl"
}

function quiet_for() {
    local file="$1"
    [ -f "$file" ] || { echo 999999; return; }
    echo $(($(date +%s) - $(stat -f %m "$file")))
}

# Moves one session; returns 1 while it is still busy.
function move_one() {
    local gpid="$1"
    local dry="$2"
    local cpid
    cpid=$(claude_under "$gpid")
    if [ -z "$cpid" ]; then
        log "$gpid: no Claude Code in it, closing that Ghostty only"
        $dry || kill -TERM "$gpid" 2>/dev/null
        return 0
    fi
    local args sid flags cwd
    args=$(ps -o command= -p "$cpid")
    sid=$(sed -E 's/.*--session-id ([^ ]+).*/\1/' <<<"$args")
    flags=$(sed -E 's/^claude //; s/--session-id [^ ]+ ?//' <<<"$args")
    cwd=$(lsof -a -p "$cpid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    local quiet
    quiet=$(quiet_for "$(transcript_for "$cwd" "$sid")")
    if [ "$quiet" -lt "$QUIET_SECS" ]; then
        log "$(basename "$cwd"): busy (active ${quiet}s ago), waiting"
        return 1
    fi
    local cmd="caffeinate -i claude --resume $sid $flags"
    log "$(basename "$cwd"): moving ($cmd)"
    $dry && return 0

    kill -TERM "$cpid" 2>/dev/null
    local i
    for ((i = 0; i < 40; i++)); do kill -0 "$cpid" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$cpid" 2>/dev/null
    kill -TERM "$gpid" 2>/dev/null
    sleep 1
    kill -KILL "$gpid" 2>/dev/null
    "$OPENER" --command "$cmd" "$cwd" >>"$LOG" 2>&1 || log "$(basename "$cwd"): opening the tab failed"
    return 0
}

# Ghostty pids, with the one hosting this script's own session last.
function legacy_pids() {
    local self=""
    local p=$$
    while [ "$p" -gt 1 ]; do
        [ "$(ps -o comm= -p "$p")" = "$GHOSTTY_BIN" ] && self="$p"
        p=$(ps -o ppid= -p "$p" | tr -d ' ')
    done
    [ -n "${MOVE_SELF_PID:-}" ] && self="$MOVE_SELF_PID"
    pgrep -f "^$GHOSTTY_BIN" | grep -vx "${self:-x}"
    [ -n "$self" ] && echo "$self"
}

function remove_hidden_setting() {
    local cfg="$HOME/.config/ghostty/config"
    [ -f "$cfg" ] || return
    perl -0pi -e 's/\n?# ghostty-dock: one Dock icon[^\n]*\nmacos-hidden = always\n//' "$cfg"
}

function main() {
    local dry=false
    while [ "$1" != "" ]; do
        case $1 in
        --detach)
            mkdir -p "$STATE_DIR"
            local self_pid
            self_pid=$(legacy_pids | tail -1)
            launchctl submit -l consulting.cloudscale.ghosttydock.move -- \
                /usr/bin/env MOVE_SELF_PID="$self_pid" /bin/bash "$ROOT/scripts/$SCRIPT_NAME" || exit 1
            echo "moving in the background; log: $LOG"
            exit 0
            ;;
        --dry-run) dry=true ;;
        -h | --help) usage ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage
            ;;
        esac
        shift
    done
    mkdir -p "$STATE_DIR" || exit 1
    [ -x "$OPENER" ] || { echo "Error: $OPENER missing, run install.sh" >&2; exit 1; }

    local pending
    pending=$(legacy_pids)
    local started
    started=$(date +%s)
    while [ -n "$pending" ]; do
        local left=""
        local gpid
        for gpid in $pending; do
            move_one "$gpid" "$dry" || left="$left $gpid"
        done
        pending=$(xargs <<<"$left")
        $dry && break
        if [ -n "$pending" ]; then
            if [ $(($(date +%s) - started)) -gt "$GIVE_UP_SECS" ]; then
                log "gave up waiting on: $pending"
                break
            fi
            sleep 20
        fi
    done
    if ! $dry && [ -z "$pending" ]; then
        remove_hidden_setting
        log "done: every session is in Ghostty Dock"
    fi
    # launchd would rerun a submitted job when it exits.
    $dry || launchctl remove consulting.cloudscale.ghosttydock.move 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
