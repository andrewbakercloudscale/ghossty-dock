#!/usr/bin/env bash

# Restarts Ghostty Dock without losing its Claude Code sessions, so a new
# build takes effect: waits until every session's transcript has been quiet
# for a while, quits the app, starts it again and reopens each session as a
# tab with `claude --resume <id>` and its original flags.
#
# Plain shell tabs are not reopened. Runs detached, because the session that
# starts it is one of those restarted.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="$HOME/.local/state/ghostty-dock"
LOG="$STATE_DIR/restart-dock.log"
OPENER="$HOME/.local/bin/ghostty-dock-open"
APP_BIN="$HOME/Applications/Ghostty Dock.app/Contents/MacOS/ghostty"
QUIET_SECS=45
GIVE_UP_SECS=$((4 * 3600))

function usage() {
    cat <<EOM

Restarts Ghostty Dock and resumes every Claude Code session in it as a tab.

usage: ${SCRIPT_NAME} [options]

options:
    --now          Do not wait for busy sessions (interrupts them)
    --dry-run      Only list the sessions that would be resumed
    --foreground   Run here instead of detached
    -h|--help      Show this help message

EOM
    exit 1
}

function log() {
    echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"
}

function app_pid() {
    ps -axo pid=,command= | awk -v bin="$APP_BIN" '{ pid = $1; $1 = ""; sub(/^ /, "") } $0 == bin { print pid; exit }'
}

# Prints the pid of every claude under the app.
function claudes_under() {
    local root="$1"
    ps -axo pid=,ppid=,command= | awk -v root="$root" '
        { parent[$1] = $2; cmd[$1] = $0 }
        END {
            for (p in cmd) {
                if (cmd[p] !~ /^ *[0-9]+ +[0-9]+ +claude --(session-id|resume) /) continue
                q = p
                while (q > 1) { q = parent[q]; if (q == root) { print p; break } }
            }
        }'
}

# Prints "<cwd>\t<session id>\t<flags>" for a claude pid.
function describe() {
    local cpid="$1"
    local args sid flags cwd
    args=$(ps -o command= -p "$cpid")
    sid=$(sed -E 's/.*--(session-id|resume) ([^ ]+).*/\2/' <<<"$args")
    flags=$(sed -E 's/^claude //; s/--(session-id|resume) [^ ]+ ?//' <<<"$args")
    cwd=$(lsof -a -p "$cpid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    printf '%s\t%s\t%s\n' "$cwd" "$sid" "$flags"
}

function quiet_secs() {
    local cwd="$1"
    local sid="$2"
    local file
    file="$HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$cwd")/$sid.jsonl"
    # A session whose transcript saving is off looks quiet forever, so the
    # hook's status counts too.
    if grep -lq "\"session_id\":\"$sid\".*\"status\":\"running\"\|\"status\":\"running\".*\"session_id\":\"$sid\"" "$STATE_DIR"/sessions/*.json 2>/dev/null; then
        echo 0
        return
    fi
    [ -f "$file" ] || { echo 999999; return; }
    echo $(($(date +%s) - $(stat -f %m "$file")))
}

function wait_until_quiet() {
    local sessions="$1"
    local started
    started=$(date +%s)
    while true; do
        local busy=""
        local cwd sid flags
        while IFS=$'\t' read -r cwd sid flags; do
            [ -z "$sid" ] && continue
            local q
            q=$(quiet_secs "$cwd" "$sid")
            [ "$q" -lt "$QUIET_SECS" ] && busy="$busy $(basename "$cwd")"
        done <<<"$sessions"
        [ -z "$busy" ] && return 0
        if [ $(($(date +%s) - started)) -gt "$GIVE_UP_SECS" ]; then
            log "gave up: still busy:$busy"
            return 1
        fi
        log "waiting for:$busy"
        sleep 15
    done
}

function restart() {
    local now="$1"
    local dry="$2"
    local pid
    pid=$(app_pid)
    [ -z "$pid" ] && { log "Ghostty Dock is not running"; return 1; }

    local sessions="" cpid
    for cpid in $(claudes_under "$pid"); do
        sessions+="$(describe "$cpid")"$'\n'
    done
    log "$(grep -c . <<<"$sessions") session(s) to resume"
    $dry && { printf '%s' "$sessions"; return 0; }
    $now || wait_until_quiet "$sessions" || return 1

    # What scripts/undo.sh reopens if this goes wrong.
    local c s f
    while IFS=$'\t' read -r c s f; do
        [ -n "$s" ] && printf '%s\t%s\t%s\n' "$s" "$c" "$f" >>"$STATE_DIR/sessions-snapshot.tsv"
    done <<<"$sessions"
    log "quitting Ghostty Dock ($pid)"
    for cpid in $(claudes_under "$pid"); do kill -TERM "$cpid" 2>/dev/null; done
    sleep 3
    kill -TERM "$pid" 2>/dev/null
    local i
    for ((i = 0; i < 40; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
    kill -KILL "$pid" 2>/dev/null
    sleep 1

    # The opener starts the app with window-save-state=never, so it comes up
    # with only these tabs.
    local cwd sid flags
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] && continue
        log "resuming $(basename "$cwd")"
        "$OPENER" --command "caffeinate -i claude --resume $sid $flags" "$cwd" >>"$LOG" 2>&1 \
            || log "$(basename "$cwd"): opening the tab failed"
    done <<<"$sessions"
    log "done"
}

function main() {
    # Sessions we start must not inherit a Claude Code parent marker
    # (CLAUDE_CODE_CHILD_SESSION turns off their transcript saving).
    unset CLAUDECODE CLAUDE_PID $(compgen -e | grep "^CLAUDE_CODE_")
    local now=false
    local dry=false
    local foreground=false
    local args=("$@")
    while [ "$1" != "" ]; do
        case $1 in
        --now) now=true ;;
        --dry-run) dry=true; foreground=true ;;
        --foreground) foreground=true ;;
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
            /bin/bash "$ROOT/scripts/$SCRIPT_NAME" --foreground "${args[@]}" >/dev/null 2>&1 </dev/null &
        echo "restarting in the background once sessions are quiet; log: $LOG"
        exit 0
    fi
    restart "$now" "$dry"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
