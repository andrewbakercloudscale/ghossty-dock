#!/usr/bin/env bash

# Moves Claude Code sessions between their own stock Ghostty apps and tabs of
# Ghostty Dock. Docking stops claude once its transcript has been quiet for a
# while, closes that Ghostty, and reopens `claude --resume <id>` with the same
# flags (so --remote-control keeps its name) as a Ghostty Dock tab. Undocking
# does the same the other way, into a Ghostty of its own. Restarting resumes
# a docked session in a fresh Ghostty Dock tab.
#
# A session that is busy is waited for, never interrupted. Run it detached
# (--detach) when the calling session is one of those being moved.

SCRIPT_NAME=$(basename "$0")
SELF="$(cd "$(dirname "$0")" && pwd)/$SCRIPT_NAME"
STATE_DIR="$HOME/.local/state/ghostty-dock"
LOG="$STATE_DIR/move-to-dock.log"
# One "<job>.pid" per move running: all, g<ghostty pid>, u<session id> or
# r<session id>.
LOCK_DIR="$STATE_DIR/moving"
OPENER="$HOME/.local/bin/ghostty-dock-open"
GHOSTTY_APP="/Applications/Ghostty.app"
GHOSTTY_BIN="$GHOSTTY_APP/Contents/MacOS/ghostty"
DOCK_BIN="$HOME/Applications/Ghostty Dock.app/Contents/MacOS/ghostty"
QUIET_SECS=60
# --now: move at once, interrupting a busy session.
NOW=false
GIVE_UP_SECS=$((12 * 3600))

function usage() {
    cat <<EOM

Moves Claude Code sessions between separate Ghostty apps and Ghostty Dock tabs.

usage: ${SCRIPT_NAME} [options]

options:
    --pid <pid>        Dock only the session in this Ghostty app (default: all)
    --undock <id>      Move this session out of Ghostty Dock into its own Ghostty
    --restart <id>     Stop this Ghostty Dock session and resume it in a new tab
    --now              Do not wait for a busy session to go quiet (interrupts it)
    --detach           Run in the background and return at once
    --dry-run          Only list what would move
    --status           Print "<sessions left to dock> <1 if docking all, else 0>"
    --list             Print a line per session outside Ghostty Dock:
                       "window<TAB>pid<TAB>busy<TAB>moving<TAB>name<TAB>cwd",
                       "undocking<TAB>id" per session being undocked and
                       "restarting<TAB>id" per session being restarted
    -h|--help          Show this help message

EOM
    exit 1
}

# Ghostty runs --command under a bare login shell (--noprofile --norc), and
# the app may have been started from Finder with PATH=/usr/bin:/bin, so the
# command carries a PATH that finds claude.
function command_path() {
    local dir out=""
    local IFS=:
    for dir in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin $PATH; do
        case ":$out:" in *":$dir:"*) ;; *) out="${out:+$out:}$dir" ;; esac
    done
    echo "$out"
}

function shell_quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}

function log() {
    echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"
}

# Prints "<claude pid>" for the claude running under a Ghostty pid; with
# "all", every one (Ghostty Dock has many).
function claude_under() {
    local root="$1"
    local all=0
    [ "$2" = "all" ] && all=1
    ps -axo pid=,ppid=,command= | awk -v root="$root" -v all="$all" '
        { parent[$1] = $2; cmd[$1] = $0 }
        END {
            for (p in cmd) {
                if (cmd[p] !~ /^ *[0-9]+ +[0-9]+ +[^ ]*claude .*--(session-id|resume|continue)( |$)/) continue
                q = p
                while (q > 1) { q = parent[q]; if (q == root) { print p; if (!all) exit; break } }
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

# Prints a claude pid's flags, shell-quoted from its real arguments, without
# --resume/--session-id <id> or --continue: ps joins them with spaces, so a
# quoted `--remote-control "aws lambda to eks"` came back as the name "aws"
# and a first prompt of "lambda to eks". Prints nothing if it cannot tell.
function claude_flags() {
    /usr/bin/python3 - "$1" 2>/dev/null <<'PY'
import ctypes, shlex, struct, sys
libc = ctypes.CDLL(None)
mib = (ctypes.c_int * 3)(1, 49, int(sys.argv[1]))  # CTL_KERN, KERN_PROCARGS2
size = ctypes.c_size_t(0)
libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0)
buf = ctypes.create_string_buffer(size.value)
if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
    sys.exit(1)
raw = buf.raw[:size.value]
argc = struct.unpack("i", raw[:4])[0]
rest = raw[4:]
i = rest.index(b"\0")
while rest[i] == 0:
    i += 1
args = [a.decode("utf-8", "replace") for a in rest[i:].split(b"\0")[:argc]][1:]
out, skip = [], False
for a in args:
    if skip:
        skip = False
    elif a in ("--resume", "--session-id", "-r"):
        skip = True
    elif a not in ("--continue", "-c"):
        out.append(a)
print(shlex.join(out))
PY
}

# Prints "<session id>\t<cwd>\t<flags>" for a claude pid.
function session_of() {
    local cpid="$1"
    local args sid flags cwd
    args=$(ps -o command= -p "$cpid")
    cwd=$(lsof -a -p "$cpid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    if [[ "$args" =~ --continue ]]; then
        # The session --continue picked: the newest transcript for the folder.
        sid=$(basename "$(ls -t "$(dirname "$(transcript_for "$cwd" x)")"/*.jsonl 2>/dev/null | head -1)" .jsonl)
        flags=$(sed -E 's/^[^ ]*claude ?//; s/--continue ?//' <<<"$args")
    else
        sid=$(sed -E 's/.*--(session-id|resume) ([^ ]+).*/\2/' <<<"$args")
        flags=$(sed -E 's/^[^ ]*claude ?//; s/--(session-id|resume) [^ ]+ ?//' <<<"$args")
    fi
    local quoted
    quoted=$(claude_flags "$cpid") && flags="$quoted"
    printf '%s\t%s\t%s\n' "$sid" "$cwd" "$flags"
}

# Moves one session; returns 1 while it is still busy.
function move_one() {
    local gpid="$1"
    local dry="$2"
    local cpid
    cpid=$(claude_under "$gpid")
    if [ -z "$cpid" ]; then
        # A shell, a --continue session (no id to resume) or anything else:
        # never closed, as there is no way to bring it back.
        log "$gpid: no Claude Code session with an id in it, left alone"
        return 0
    fi
    local sid cwd flags
    IFS=$'\t' read -r sid cwd flags <<<"$(session_of "$cpid")"
    if [ -z "$sid" ]; then
        log "$(basename "$cwd"): no session id found, left alone"
        return 0
    fi
    local quiet
    quiet=$(quiet_for "$(transcript_for "$cwd" "$sid")")
    if ! $NOW && [ "$quiet" -lt "$QUIET_SECS" ]; then
        log "$(basename "$cwd"): busy (active ${quiet}s ago), waiting"
        return 1
    fi
    local cmd="caffeinate -i claude --resume $sid $flags"
    log "$(basename "$cwd"): moving ($cmd)"
    $dry && return 0

    # What scripts/undo.sh reopens if this goes wrong.
    printf '%s\t%s\t%s\n' "$sid" "$cwd" "$flags" >>"$STATE_DIR/sessions-snapshot.tsv"
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

# Stock Ghostty apps with a Claude Code session in them.
function movable_pids() {
    local gpid
    for gpid in $(pgrep -f "^$GHOSTTY_BIN"); do
        [ -n "$(claude_under "$gpid")" ] && echo "$gpid"
    done
}

function job_running() {
    local f="$LOCK_DIR/$1.pid"
    [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null
}

function list_sessions() {
    local gpid
    for gpid in $(movable_pids); do
        local sid cwd flags busy=0 moving=0
        IFS=$'\t' read -r sid cwd flags <<<"$(session_of "$(claude_under "$gpid")")"
        [ "$(quiet_for "$(transcript_for "$cwd" "$sid")")" -lt "$QUIET_SECS" ] && busy=1
        { job_running all || job_running "g$gpid"; } && moving=1
        printf 'window\t%s\t%s\t%s\t%s\t%s\n' "$gpid" "$busy" "$moving" "$(basename "$cwd")" "$cwd"
    done
    local f
    for f in "$LOCK_DIR"/u*.pid; do
        [ -f "$f" ] || continue
        local job
        job=$(basename "$f" .pid)
        job_running "$job" && printf 'undocking\t%s\n' "${job#u}"
    done
    for f in "$LOCK_DIR"/r*.pid; do
        [ -f "$f" ] || continue
        local job
        job=$(basename "$f" .pid)
        job_running "$job" && printf 'restarting\t%s\n' "${job#r}"
    done
}

# The claude in a Ghostty Dock tab running session <id>.
function docked_claude() {
    local sid="$1"
    local dock
    # Not pgrep -f: it does not match this path, which has a space in it.
    dock=$(ps -axo pid=,command= | awk -v bin="$DOCK_BIN" '{ pid = $1; $1 = ""; sub(/^ /, "") }
        index($0, bin " ") == 1 || $0 == bin { print pid; exit }')
    [ -n "$dock" ] || return
    local cpid
    for cpid in $(claude_under "$dock" all); do
        [ "$(cut -f1 <<<"$(session_of "$cpid")")" = "$sid" ] && { echo "$cpid"; return; }
    done
}

# Moves session <id> out of Ghostty Dock into a stock Ghostty of its own, or
# with "restart" resumes it in a new Ghostty Dock tab.
function undock() {
    local sid="$1"
    local dry="$2"
    local mode="${3:-undock}"
    local cpid
    cpid=$(docked_claude "$sid")
    [ -n "$cpid" ] || { log "$sid: not running in Ghostty Dock"; return 1; }
    local cwd flags started
    IFS=$'\t' read -r _ cwd flags <<<"$(session_of "$cpid")"
    started=$(date +%s)
    while ! $NOW && [ "$(quiet_for "$(transcript_for "$cwd" "$sid")")" -lt "$QUIET_SECS" ]; do
        log "$(basename "$cwd"): busy, ${mode}ing once quiet"
        $dry && return 0
        [ $(($(date +%s) - started)) -gt "$GIVE_UP_SECS" ] && { log "$(basename "$cwd"): gave up"; return 1; }
        sleep 20
    done
    local cmd="caffeinate -i claude --resume $sid $flags"
    log "$(basename "$cwd"): ${mode}ing ($cmd)"
    $dry && return 0
    printf '%s\t%s\t%s\n' "$sid" "$cwd" "$flags" >>"$STATE_DIR/sessions-snapshot.tsv"
    # Its tab closes when claude exits.
    kill -TERM "$cpid" 2>/dev/null
    local i
    for ((i = 0; i < 40; i++)); do kill -0 "$cpid" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$cpid" 2>/dev/null
    if [ "$mode" = restart ]; then
        "$OPENER" --command "$cmd" "$cwd" >>"$LOG" 2>&1 || log "$(basename "$cwd"): opening the tab failed"
        return
    fi
    # One --command argument: with -e, Ghostty also opens "/bin/zsh" as a tab.
    open -na "$GHOSTTY_APP" --args --window-save-state=never --quit-after-last-window-closed=true \
        --working-directory="$cwd" --command="/usr/bin/env $(shell_quote "PATH=$(command_path)") $cmd" || log "$(basename "$cwd"): Ghostty did not start"
}

function remove_hidden_setting() {
    local cfg="$HOME/.config/ghostty/config"
    [ -f "$cfg" ] || return
    perl -0pi -e 's/\n?# ghostty-dock: one Dock icon[^\n]*\nmacos-hidden = always\n//' "$cfg"
}

function main() {
    # Sessions we start must not inherit a Claude Code parent marker
    # (CLAUDE_CODE_CHILD_SESSION turns off their transcript saving), nor the
    # Ghostty Dock ids of the tab this runs in (its row would be overwritten).
    unset CLAUDECODE CLAUDE_PID GHOSTTY_DOCK_SURFACE DOCK_TAB_ID $(compgen -e | grep "^CLAUDE_CODE_")
    local dry=false
    local detach=false
    local only=""
    local undock_id=""
    local restart_id=""
    local args=()
    while [ "$1" != "" ]; do
        case $1 in
        --detach) detach=true ;;
        --pid)
            shift
            only="$1"
            args+=(--pid "$1")
            ;;
        --undock)
            shift
            undock_id="$1"
            args+=(--undock "$1")
            ;;
        --restart)
            shift
            restart_id="$1"
            args+=(--restart "$1")
            ;;
        --now)
            NOW=true
            args+=(--now)
            ;;
        --dry-run)
            dry=true
            args+=(--dry-run)
            ;;
        --status)
            if job_running all; then echo "$(movable_pids | grep -c .) 1"; else echo "$(movable_pids | grep -c .) 0"; fi
            exit 0
            ;;
        --list)
            list_sessions
            exit 0
            ;;
        -h | --help) usage ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage
            ;;
        esac
        shift
    done
    mkdir -p "$STATE_DIR" "$LOCK_DIR" || exit 1
    [ -x "$OPENER" ] || { echo "Error: $OPENER missing, run install.sh" >&2; exit 1; }

    if $detach; then
        # Its own session, immune to the hangup when the Ghostty this runs
        # in closes. Not launchd: a launchd job may not read ~/Desktop.
        local self_pid
        self_pid=$(legacy_pids | tail -1)
        MOVE_SELF_PID="$self_pid" nohup perl -MPOSIX=setsid -e 'setsid; exec @ARGV' \
            /bin/bash "$SELF" "${args[@]}" >/dev/null 2>&1 </dev/null &
        echo "moving in the background; log: $LOG"
        exit 0
    fi

    local job=all
    [ -n "$only" ] && job="g$only"
    [ -n "$undock_id" ] && job="u$undock_id"
    [ -n "$restart_id" ] && job="r$restart_id"
    if ! $dry; then
        { job_running "$job" || { [ "$job" != "${job#g}" ] && job_running all; }; } &&
            { echo "already moving; log: $LOG"; exit 0; }
        echo $$ >"$LOCK_DIR/$job.pid"
    fi

    if [ -n "$undock_id" ]; then
        undock "$undock_id" "$dry"
    elif [ -n "$restart_id" ]; then
        undock "$restart_id" "$dry" restart
    else
        dock_all "$dry" "$only"
    fi
    $dry || rm -f "$LOCK_DIR/$job.pid"
}

function dock_all() {
    local dry="$1"
    local only="$2"
    local pending
    if [ -n "$only" ]; then
        pending=$(movable_pids | grep -x "$only")
        [ -n "$pending" ] || { log "$only: no Claude Code session to dock"; return; }
    else
        pending=$(legacy_pids)
    fi
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
    if ! $dry && [ -z "$only" ] && [ -z "$pending" ]; then
        remove_hidden_setting
        log "done: every session is in Ghostty Dock"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
