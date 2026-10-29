#!/usr/bin/env bash

# Restarts Ghostty Dock without losing its Claude Code sessions, so a new
# build takes effect: waits until every session's transcript has been quiet
# for a while, quits the app, starts it again and reopens each session as a
# tab with `claude --resume <id>` and its original flags.
#
# Tabs run under ghostty-dock-hold (Settings: Keep tabs running) are not
# stopped at all: the app goes, their holders keep them running, and the new
# app reattaches a tab to each, shells and dev servers included. Only the
# others are waited for and resumed. Runs detached, because the session that
# starts it is one of those restarted.
#
# The app also calls it (installed as ghostty-dock-restart): --save every few
# seconds records the open sessions, and --restore reopens them when the app
# starts after a quit or crash.

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATE_DIR="$HOME/.local/state/ghostty-dock"
LOG="$STATE_DIR/restart-dock.log"
SAVED="$STATE_DIR/open-sessions.tsv"
DESCRIBED="$STATE_DIR/described"
# Sessions a restart or restore could not bring back: the app offers to
# reopen them (--reopen-missing) until they run again.
MISSING="$STATE_DIR/missing-sessions.tsv"
# What a restart is waiting for, for the app to show: "<what>\t<deadline>\t<names>".
STATUS="$STATE_DIR/restart-status"
# The sessions a restart is bringing back, while it runs: --save and
# --restore leave them alone, and the app's Loading screen counts them.
RESTARTING="$STATE_DIR/restarting.tsv"
OPENER="$HOME/.local/bin/ghostty-dock-open"
APP_BIN="$HOME/Applications/Ghostty Dock.app/Contents/MacOS/ghostty"
HOLD="${GHOSTTY_DOCK_HOLD_BIN:-$HOME/Applications/Ghostty Dock.app/Contents/MacOS/ghostty-dock-hold}"
QUIET_SECS=10
GIVE_UP_SECS=$((4 * 3600))
# No restart until the keyboard and mouse have been still this long, so it
# never lands while you are typing; a key press starts the count again.
INPUT_IDLE_SECS=10

function usage() {
    cat <<EOM

Restarts Ghostty Dock and resumes every Claude Code session in it as a tab.

usage: ${SCRIPT_NAME} [options]

options:
    --now          Do not wait for busy sessions (interrupts them)
    --dry-run      Only list the sessions that would be resumed
    --foreground   Run here instead of detached
    --save         Record the open sessions (for --restore) and stop
    --restore      Reopen the sessions recorded by --save that are not
                   running anywhere, then stop
    --reopen-missing
                   Reopen the sessions a restart or restore could not
                   bring back (listed in missing-sessions.tsv), then stop
    -h|--help      Show this help message

EOM
    exit 1
}

# Records what the restart waits for; the deadline is epoch seconds or 0.
function status() {
    printf '%s\t%s\t%s\n' "$1" "${2:-0}" "${3:-}" >"$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
}

function log() {
    echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"
}

function app_pid() {
    ps -axo pid=,command= | awk -v bin="$APP_BIN" '{ pid = $1; $1 = ""; sub(/^ /, "") } index($0, bin) == 1 && (length($0) == length(bin) || substr($0, length(bin) + 1, 1) == " ") { print pid; exit }'
}

# Prints the pid of every claude under any of the given pids, however it was
# started (`claude`, `claude --continue`, a full path, ...).
function claudes_under() {
    local roots="$*"
    [ -z "$roots" ] && return 0
    ps -axo pid=,ppid=,command= | awk -v roots="$roots" '
        BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) root[r[i]] = 1 }
        { parent[$1] = $2; cmd[$1] = $0 }
        END {
            for (p in cmd) {
                if (cmd[p] !~ /^ *[0-9]+ +[0-9]+ +([^ ]*\/)?claude( |$)/) continue
                # A headless claude -p (a git hook or build script) belongs to no tab.
                if (cmd[p] ~ / (-p|--print)( |$)/) continue
                q = p
                while (q > 1) { q = parent[q]; if (q in root) { print p; break } }
            }
        }'
}

# Prints "<name>\t<holder pid>\t<attached 1/0>\t<folder>\t<started>\t..." for
# every running holder, oldest first.
function holders() {
    [ -x "$HOLD" ] || return 0
    "$HOLD" list "$@" 2>/dev/null | sort -t$'\t' -k5n
}

function holder_pids() {
    holders | cut -f2 | tr '\n' ' '
}

# The session a claude pid is on, from the hook's state: for claudes started
# without an id (`claude`, `claude --continue`), or whose id has changed.
function hook_session() {
    local cpid="$1"
    local file
    file=$(grep -l "\"claude_pid\":${cpid}[,}]" "$STATE_DIR"/sessions/*.json 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    [ -n "$file" ] && sed -nE 's/.*"session_id":"([^"]+)".*/\1/p' "$file"
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

# Prints "<cwd>\t<session id>\t<flags>" for a claude pid; the session id is
# empty when it cannot be told, and that claude is not resumed. Prints
# nothing without a folder (a claude that is exiting): read splits on tabs
# and runs empty fields together, so the id would be taken for the folder.
function describe() {
    local cpid="$1"
    local args sid flags cwd
    args=$(ps -o command= -p "$cpid")
    sid=$(hook_session "$cpid")
    [ -z "$sid" ] && grep -qE -- "--(session-id|resume) " <<<"$args" &&
        sid=$(sed -E 's/.*--(session-id|resume) ([^ ]+).*/\2/' <<<"$args")
    # A session's folder and flags never change, and finding them takes
    # lsof and python, so each is worked out once per process. The command
    # line is kept with them in case the pid is reused.
    local cache="$DESCRIBED/$cpid" cached=""
    [ -f "$cache" ] && cached=$(<"$cache")
    if [ -n "$cached" ] && [ "${cached%%$'\n'*}" = "$args" ]; then
        cached="${cached#*$'\n'}"
        cwd="${cached%%$'\t'*}"
        flags="${cached#*$'\t'}"
    else
        flags=$(sed -E 's/^([^ ]*\/)?claude ?//; s/--(session-id|resume) [^ ]+ ?//; s/(^| )(--continue|-c)( |$)/\1/; s/ +$//' <<<"$args")
        local quoted
        quoted=$(claude_flags "$cpid") && flags="$quoted"
        cwd=$(lsof -a -p "$cpid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
        [ -d "$cwd" ] && mkdir -p "$DESCRIBED" && printf '%s\n%s\t%s' "$args" "$cwd" "$flags" >"$cache"
    fi
    [ -d "$cwd" ] || return 0
    printf '%s\t%s\t%s\n' "$cwd" "$sid" "$flags"
}

# True when the transcript's last turn is over: its last entry is the
# turn's end marker or "[Request interrupted by user…]".
function turn_ended() {
    [ -f "$1" ] || return 1
    tail -c 65536 "$1" | tail -n +2 | jq -rR '
        fromjson? | select(.isSidechain != true)
        | if .type == "system" and .subtype == "turn_duration" then "ended"
          elif .type == "user" then
            ([.message.content | if type == "string" then . else (.[]? | .text // (.content | strings) // empty) end]
             | map(startswith("[Request interrupted by user")) | any | if . then "ended" else "busy" end)
          elif .type == "assistant" then "busy"
          else empty end' 2>/dev/null | tail -1 | grep -qx ended
}

function quiet_secs() {
    local cwd="$1"
    local sid="$2"
    local file
    file="$HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$cwd")/$sid.jsonl"
    # A session whose transcript saving is off looks quiet forever, so the
    # hook's status counts too, unless the transcript shows the turn is over:
    # an API error or Esc ends it without the hook hearing.
    if grep -lq "\"session_id\":\"$sid\".*\"status\":\"running\"\|\"status\":\"running\".*\"session_id\":\"$sid\"" "$STATE_DIR"/sessions/*.json 2>/dev/null &&
        ! turn_ended "$file"; then
        echo 0
        return
    fi
    [ -f "$file" ] || { echo 999999; return; }
    echo $(($(date +%s) - $(stat -f %m "$file")))
}

# Waits until no session has been busy for QUIET_SECS and you have not
# typed for INPUT_IDLE_SECS, both at once; checks every second, so a key
# press or a session waking puts the countdown back.
function wait_until_quiet() {
    local sessions="$1"
    local started last=""
    started=$(date +%s)
    while true; do
        local busy="" active="" left=0 idle typing
        local cwd sid flags
        while IFS=$'\t' read -r cwd sid flags; do
            [ -z "$sid" ] && continue
            local q
            q=$(quiet_secs "$cwd" "$sid")
            [ "$q" -lt "$QUIET_SECS" ] || continue
            busy="$busy $(basename "$cwd")"
            [ "$q" -lt 5 ] && active="${active:+$active, }$(basename "$cwd")"
            [ $((QUIET_SECS - q)) -gt "$left" ] && left=$((QUIET_SECS - q))
        done <<<"$sessions"
        idle=$(input_idle_secs)
        typing=$((INPUT_IDLE_SECS - ${idle:-$INPUT_IDLE_SECS}))
        [ -z "$busy" ] && [ "$typing" -le 0 ] && return 0
        if [ $(($(date +%s) - started)) -gt "$GIVE_UP_SECS" ]; then
            log "gave up: still busy:$busy"
            return 1
        fi
        if [ -n "$active" ]; then
            status busy 0 "$active"
        elif [ "$typing" -gt "$left" ]; then
            status typing $(($(date +%s) + typing))
        else
            status quiet $(($(date +%s) + left))
        fi
        [ "$busy" != "$last" ] && [ -n "$busy" ] && log "waiting for:$busy"
        last="$busy"
        sleep 1
    done
}

# Seconds since the last key press, click or mouse move.
function input_idle_secs() {
    ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF / 1000000000); exit}'
}

function wait_for_input_idle() {
    local idle logged=false
    while true; do
        idle=$(input_idle_secs)
        [ "${idle:-$INPUT_IDLE_SECS}" -ge "$INPUT_IDLE_SECS" ] && return 0
        status typing $(($(date +%s) + INPUT_IDLE_SECS - ${idle:-0}))
        $logged || { log "waiting for $INPUT_IDLE_SECS s without typing"; logged=true; }
        sleep 1
    done
}

# Prints "<cwd>\t<session id>\t<flags>" for every claude under the given
# pids: the app's for the sessions it runs itself, the holders' for the rest.
function open_sessions() {
    local cpid
    for cpid in $(claudes_under "$@"); do
        describe "$cpid"
    done | awk -F'\t' '$2 == "" || !seen[$2]++'
}

# True while a restart is quitting the app and reopening its sessions; a
# marker left by one that died is ignored after 10 minutes.
function restarting() {
    [ -n "$(find "$RESTARTING" -mmin -10 2>/dev/null)" ]
}

function save() {
    restarting && return 0
    local pid
    pid=$(app_pid)
    [ -z "$pid" ] && return 0
    # Held sessions too: a reboot ends their holders, and then they are
    # resumed like the rest.
    open_sessions "$pid" $(holder_pids) >"$SAVED.tmp" && mv "$SAVED.tmp" "$SAVED"
    # Forgets processes that have ended.
    local f
    for f in "$DESCRIBED"/*; do
        [ -f "$f" ] && ! kill -0 "${f##*/}" 2>/dev/null && rm -f "$f"
    done
    return 0
}

# Only a session in a terminal counts: Claude Burst's handover writer runs
# `claude -p --resume <sid> --fork-session` with no terminal as a session
# exits, and taking that for the session being back left its tab unopened.
function running_anywhere() {
    local sid="$1"
    ps -axo tty=,command= | grep -vE "^ *\?\? | -p | --print " \
        | grep -qE "^ *[^ ]+ +(caffeinate -i )?claude .*--(session-id|resume) $sid( |$)"
}

function restore() {
    restarting && { log "restore: skipped, a restart is reopening the sessions"; return 0; }
    reattach_all
    [ -s "$SAVED" ] || return 0
    local sessions
    sessions=$(cat "$SAVED")
    rm -f "$SAVED"
    log "restore: $(conditions)"
    reopen_all "$sessions" "$(open_sessions $(holder_pids) | cut -f2)"
}

# Opens a tab on every holder left without one, so what ran in the tabs
# before a quit, crash or restart is back with its output.
function reattach_all() {
    local name hpid attached cwd rest tabs=""
    while IFS=$'\t' read -r name hpid attached cwd rest; do
        [ -n "$name" ] && [ "$attached" = 0 ] || continue
        [ -d "$cwd" ] || cwd="$HOME"
        tabs+="'$HOLD' attach $name"$'\t'"$cwd"$'\n'
    done < <(holders --detached)
    [ -n "$tabs" ] || return 0
    # All in one go: a tab at a time took seconds each.
    printf '%s' "$tabs" | "$OPENER" --batch >>"$LOG" 2>&1 || log "reattaching some tabs failed"
    log "reattached $(grep -c . <<<"$tabs") tab(s)"
    return 0
}

# Reopens what missing-sessions.tsv lists.
function reopen_missing() {
    [ -s "$MISSING" ] || { log "nothing missing"; return 0; }
    local sessions
    sessions=$(cat "$MISSING")
    rm -f "$MISSING"
    log "reopen missing: $(conditions)"
    reopen_all "$sessions"
}

# Opens the sessions not already running, then checks they started. The
# second argument lists ids already back in a holder.
function reopen_all() {
    local sessions="$1"
    local held="${2:-}"
    local cwd sid flags todo=""
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] || [ ! -d "$cwd" ] && continue
        running_anywhere "$sid" && continue
        grep -qxF "$sid" <<<"$held" && continue
        todo+="$cwd"$'\t'"$sid"$'\t'"$flags"$'\n'
    done <<<"$sessions"
    [ -n "$todo" ] && resume_all "$todo"
}

# What a failed reopen usually comes down to, for the log.
function conditions() {
    local screen=on
    display_on || screen=off
    echo "screen $screen, app pid ${1:-$(app_pid)}, PATH=$PATH"
}

# Terminals opened while the screen is off fail to start (Metal cannot make
# their surfaces: "error initializing surface err=error.OutOfMemory"), so a
# restart while you are away waits for the screen to come back on.
function display_on() {
    [ "$(pmset -g log 2>/dev/null | grep -E "Display is turned (on|off)" | tail -1 | grep -oE "(on|off) *$" | tr -d ' ')" != "off" ]
}

function wait_for_display() {
    display_on && return 0
    log "waiting for the screen to come on"
    status screen
    until display_on; do sleep 15; done
    log "screen is on"
    sleep 5
}

# Opens a tab resuming each session, then checks they started, tries the
# missing ones once more and records any still missing in $MISSING.
function resume_all() {
    local sessions="$1"
    local cwd sid flags
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] && continue
        # Once only: never a second tab on a session already back.
        running_anywhere "$sid" && continue
        log "resuming $(basename "$cwd")"
        "$OPENER" --command "caffeinate -i claude --resume $sid $flags" "$cwd" >>"$LOG" 2>&1 \
            || log "$(basename "$cwd"): opening the tab failed"
    done <<<"$sessions"
    sleep 20
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] && continue
        running_anywhere "$sid" && continue
        log "$(basename "$cwd") did not start; trying again ($(conditions))"
        wait_for_display
        "$OPENER" --command "caffeinate -i claude --resume $sid $flags" "$cwd" >>"$LOG" 2>&1 \
            || log "$(basename "$cwd"): opening the tab failed"
    done <<<"$sessions"
    sleep 20
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] && continue
        running_anywhere "$sid" && continue
        log "$(basename "$cwd") still not running; recorded in $(basename "$MISSING")"
        record_missing "$cwd" "$sid" "$flags"
    done <<<"$sessions"
}

function record_missing() {
    local cwd="$1"
    local sid="$2"
    local flags="$3"
    touch "$MISSING"
    grep -v $'\t'"$sid"$'\t' "$MISSING" >"$MISSING.tmp"
    printf '%s\t%s\t%s\n' "$cwd" "$sid" "$flags" >>"$MISSING.tmp"
    mv "$MISSING.tmp" "$MISSING"
}

function restart() {
    local now="$1"
    local dry="$2"
    local pid
    pid=$(app_pid)
    [ -z "$pid" ] && { log "Ghostty Dock is not running"; return 1; }

    local sessions held cpid
    sessions=$(open_sessions "$pid")
    held=$(open_sessions $(holder_pids))
    # Restart Now was just clicked, so the screen is on, and asking pmset
    # takes 5 seconds each time: twice was 10 seconds of nothing happening.
    local seen="screen on (clicked), app pid $pid"
    $now || seen=$(conditions "$pid")
    log "$(grep -c . <<<"$sessions") session(s) to resume, $(holders | grep -c .) held tab(s) to reattach ($seen)"
    $dry && { printf '%s' "$sessions"; return 0; }
    $now && status quitting
    trap 'rm -f "$STATUS" "$RESTARTING"' EXIT
    # One restart at a time: a newer one replaces any still waiting.
    local other
    for other in $(pgrep -f "$SCRIPT_NAME --foreground"); do
        [ "$other" != "$$" ] && kill -TERM "$other" 2>/dev/null && log "replaced the restart already waiting ($other)"
    done
    $now || wait_until_quiet "$sessions" || return 1
    $now || wait_for_display
    # Restart Now was just clicked, so the mouse is moving: waiting for
    # the input to go idle would look like nothing happened.
    $now || wait_for_input_idle

    # What scripts/undo.sh reopens if this goes wrong.
    local c s f
    while IFS=$'\t' read -r c s f; do
        [ -n "$s" ] && printf '%s\t%s\t%s\n' "$s" "$c" "$f" >>"$STATE_DIR/sessions-snapshot.tsv"
    done <<<"$sessions"$'\n'"$held"
    printf '%s\n' "$sessions" "$held" | grep . >"$RESTARTING"
    # A --save the app started just before it quit would otherwise write
    # back the sessions as they exit, for the new app to reopen twice.
    pkill -f "$SCRIPT_NAME --save" 2>/dev/null
    log "quitting Ghostty Dock ($pid)"
    status quitting
    # The holders keep their tabs' programs running rather than hang them up.
    mkdir -p "$STATE_DIR/hold" && echo "$pid" >"$STATE_DIR/hold/quitting"
    # Claude saves its session as it ends; held ones are not ended, so
    # with none to end there is nothing to wait for.
    local ended=0
    for cpid in $(claudes_under "$pid"); do kill -TERM "$cpid" 2>/dev/null && ended=1; done
    [ "$ended" = 1 ] && sleep 3
    kill -TERM "$pid" 2>/dev/null
    local i
    for ((i = 0; i < 40; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$pid" 2>/dev/null
    # These are resumed below; the new app must not reopen them too.
    rm -f "$SAVED"
    sleep 1

    # The opener starts the app with window-save-state=never, so it comes up
    # with only these tabs.
    reattach_all
    [ -n "$sessions" ] && resume_all "$sessions"
    rm -f "$RESTARTING"
    log "done"
}

function main() {
    # Sessions we start must not inherit a Claude Code parent marker
    # (CLAUDE_CODE_CHILD_SESSION turns off their transcript saving), nor the
    # Ghostty Dock ids of the tab this runs in (its row would be overwritten).
    unset CLAUDECODE CLAUDE_PID GHOSTTY_DOCK_SURFACE DOCK_TAB_ID $(compgen -e | grep "^CLAUDE_CODE_")
    local now=false
    local dry=false
    local foreground=false
    local args=("$@")
    while [ "$1" != "" ]; do
        case $1 in
        --now) now=true ;;
        --dry-run) dry=true; foreground=true ;;
        --foreground) foreground=true ;;
        --save)
            mkdir -p "$STATE_DIR" || exit 1
            save
            exit 0
            ;;
        --reopen-missing)
            mkdir -p "$STATE_DIR" || exit 1
            [ -x "$OPENER" ] || { echo "Error: $OPENER missing, run install.sh" >&2; exit 1; }
            reopen_missing
            exit 0
            ;;
        --restore)
            mkdir -p "$STATE_DIR" || exit 1
            [ -x "$OPENER" ] || { echo "Error: $OPENER missing, run install.sh" >&2; exit 1; }
            restore
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
    mkdir -p "$STATE_DIR" || exit 1
    [ -x "$OPENER" ] || { echo "Error: $OPENER missing, run install.sh" >&2; exit 1; }

    if ! $foreground; then
        # Its own session, immune to the hangup when its tab closes.
        nohup perl -MPOSIX=setsid -e 'setsid; exec @ARGV' \
            /bin/bash "$SCRIPT_DIR/$SCRIPT_NAME" --foreground "${args[@]}" >/dev/null 2>&1 </dev/null &
        if $now; then
            echo "restarting in the background now; log: $LOG"
        else
            echo "restarting in the background once sessions are quiet; log: $LOG"
        fi
        exit 0
    fi
    restart "$now" "$dry"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
