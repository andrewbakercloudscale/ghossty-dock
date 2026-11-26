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

# Without basename and dirname: the app runs this every few seconds.
SCRIPT_NAME=${0##*/}
SCRIPT_DIR=$(cd "$([[ "$0" == */* ]] && echo "${0%/*}" || echo .)" && pwd)
STATE_DIR="$HOME/.local/state/ghostty-dock"
LOG="$STATE_DIR/restart-dock.log"
SAVED="$STATE_DIR/open-sessions.tsv"
# Which app instance wrote $SAVED ("<pid> <start time>"). A list some other
# instance wrote - copied over from another Mac, or left by an app that ran
# before it arrived - is restored, never written over by --save.
SAVED_BY="$STATE_DIR/open-sessions.owner"
DESCRIBED="$STATE_DIR/described"
# Sessions a restart or restore could not bring back: the app offers to
# reopen them (--reopen-missing) until they run again.
MISSING="$STATE_DIR/missing-sessions.tsv"
# Sessions that dropped out of $SAVED, with when: "<folder>\t<id>\t<epoch>\t<flags>"
# (flags last: read collapses an empty field between tabs).
# A shutdown can end some claudes before the app's last save, which then
# left them out; restore counts those as not come back.
ENDED="$STATE_DIR/ended-sessions.tsv"
# What a restart is waiting for, for the app to show: "<what>\t<deadline>\t<names>".
STATUS="$STATE_DIR/restart-status"
# The sessions a restart is bringing back, while it runs: --save and
# --restore leave them alone, and the app's Loading screen counts them.
RESTARTING="$STATE_DIR/restarting.tsv"
# The splits of each tab, which the app records (DockLayout.swift), and the
# copy a restart takes before the app quits.
LAYOUT="$STATE_DIR/layout.json"
LAYOUT_KEPT="$STATE_DIR/layout-restart.json"
OPENER="$HOME/.local/bin/ghostty-dock-open"
APP_BIN="$HOME/Applications/Ghostty Dock.app/Contents/MacOS/ghostty"
HOLD="${GHOSTTY_DOCK_HOLD_BIN:-$HOME/Applications/Ghostty Dock.app/Contents/MacOS/ghostty-dock-hold}"
QUIET_SECS=10
GIVE_UP_SECS=$((4 * 3600))
# No restart until the keyboard and mouse have been still this long, so it
# never lands while you are typing; a key press starts the count again.
INPUT_IDLE_SECS=10


# "caffeinate -i " to keep the Mac awake while a session runs, as the
# launcher does, unless CLAUDE_PANEL_CAFFEINATE is off in
# ~/.config/claude-panel/options (Settings → App in Ghostty Dock).
function awake() {
    local opt="" line
    [ -f "$HOME/.config/claude-panel/options" ] &&
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" == CLAUDE_PANEL_CAFFEINATE=* ]] && opt="${line#*=}"
        done <"$HOME/.config/claude-panel/options"
    opt="${opt//[\"\' ]/}"
    case "$opt" in [Ff][Aa][Ll][Ss][Ee]|0|[Nn][Oo]|[Oo][Ff][Ff]) ;; *) printf 'caffeinate -i ' ;; esac
}

# " --debug=<bridge> --debug-file <log>" so a resumed session records why
# Remote Control fails to connect (the reason only reaches the debug log).
# Bridge lines only; GHOSTTY_DOCK_RC_DEBUG=0 turns it off.
function rcdebug() {
    [ "${GHOSTTY_DOCK_RC_DEBUG:-1}" = 0 ] && return 0
    printf ' --debug=bridge,bridge:init,bridge:api,bridge:session,bridge:repl,bridge:shutdown,remote-bridge --debug-file %s' \
        "$HOME/.local/state/ghostty-dock/rc-debug/$1.log"
}

function usage() {
    cat <<EOM

Restarts Ghostty Dock and resumes every Claude Code session in it as a tab.

usage: ${SCRIPT_NAME} [options]

options:
    --now          Do not wait for busy sessions (interrupts them)
    --fresh        Start every tab again rather than reattach it: Claude
                   sessions resume in new tabs and shells open in their
                   folders. For after the app's signature changed: tabs
                   kept from the old app are not the new app to macOS,
                   which then asks for each folder on every access.
    --dry-run      Only list the sessions that would be resumed
    --foreground   Run here instead of detached
    --save         Record the open sessions (for --restore) and stop
    --restore      Reopen the sessions recorded by --save that are not
                   running anywhere, then stop
    --reattach     Open a tab for each terminal left running without
                   one (a window closed with its sessions kept), then stop
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

# Every process as "<pid> <ppid> <tty> <etime> <command>". save takes one
# look and each step reads it (PROCS): it was four ps of the whole Mac every
# 10 s, each a tenth of a second or more of system time with 900 running.
function procs() {
    if [ -n "${PROCS:-}" ]; then
        printf '%s\n' "$PROCS"
    else
        ps -axo pid=,ppid=,tty=,etime=,command=
    fi
}

function app_pid() {
    procs | awk -v bin="$APP_BIN" '{ pid = $1; $1 = $2 = $3 = $4 = ""; sub(/^ +/, "") } index($0, bin) == 1 && (length($0) == length(bin) || substr($0, length(bin) + 1, 1) == " ") { print pid; exit }'
}

# Prints the pid of every claude under any of the given pids, however it was
# started (`claude`, `claude --continue`, a full path, ...).
function claudes_under() {
    local roots="$*"
    [ -z "$roots" ] && return 0
    procs | awk -v roots="$roots" '
        BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) root[r[i]] = 1 }
        { parent[$1] = $2; cmd[$1] = $0 }
        END {
            for (p in cmd) {
                if (cmd[p] !~ /^ *[0-9]+ +[0-9]+ +[^ ]+ +[^ ]+ +([^ ]*\/)?claude( |$)/) continue
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

# Without sort, cut and tr: save asks every time.
function holder_pids() {
    [ -x "$HOLD" ] || return 0
    local name pid rest
    while IFS=$'\t' read -r name pid rest; do
        [ -n "$pid" ] && printf '%s ' "$pid"
    done < <("$HOLD" list 2>/dev/null)
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

# Flags with --dangerously-skip-permissions added, as every new session is
# started (ghostty-claude-launcher), unless CLAUDE_PANEL_BYPASS_PERMISSIONS is
# off in ~/.config/claude-panel/options or the flags already pick a mode. A
# session started some other way otherwise came back asking, or in auto mode.
# The option with_bypass goes by, read once: it was five processes per
# session per save. Called before a loop, as with_bypass runs in $(...).
function load_bypass_opt() {
    local opt=""
    [ -f "$HOME/.config/claude-panel/options" ] &&
        while IFS= read -r line || [ -n "$line" ]; do
            [[ "$line" == CLAUDE_PANEL_BYPASS_PERMISSIONS=* ]] && opt="${line#*=}"
        done <"$HOME/.config/claude-panel/options"
    opt="${opt//[\"\' ]/}"
    # Lowercase without tr: bash 3.2 has no ${opt,,}.
    case "$opt" in [Ff][Aa][Ll][Ss][Ee] | 0 | [Nn][Oo] | [Oo][Ff][Ff]) BYPASS_OPT=off ;; *) BYPASS_OPT="$opt" ;; esac
}

function with_bypass() {
    local flags="$1"
    [ -n "${BYPASS_OPT+x}" ] || load_bypass_opt
    case "$BYPASS_OPT" in false|0|no|off) echo "$flags"; return ;; esac
    if [[ " $flags" =~ \ (--dangerously-skip-permissions|--permission-mode)(\ |=|$) ]]; then
        echo "$flags"
    else
        echo "--dangerously-skip-permissions${flags:+ $flags}"
    fi
}

# Prints "<cwd>\t<session id>\t<flags>" for a claude pid; the session id is
# empty when it cannot be told, and that claude is not resumed. Prints
# nothing without a folder (a claude that is exiting): read splits on tabs
# and runs empty fields together, so the id would be taken for the folder.
function describe() {
    local cpid="$1"
    local args sid flags cwd
    # open_sessions passes what the hook recorded ("-" for nothing) and the
    # command line, from one look at all of them.
    if [ $# -ge 3 ]; then
        sid="${2#-}"
        args="$3"
    else
        args=$(ps -o command= -p "$cpid")
        sid=$(hook_session "$cpid")
    fi
    [ -z "$sid" ] && [[ "$args" =~ --(session-id|resume)\ ([^ ]+) ]] && sid="${BASH_REMATCH[2]}"
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
    printf '%s\t%s\t%s\n' "$cwd" "$sid" "$(with_bypass "$flags")"
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

# Waits until no session has been busy for QUIET_SECS and you have not
# typed for INPUT_IDLE_SECS, both at once; checks every second, so a key
# press or a session waking puts the countdown back.
#
# Each second costs a few processes however many sessions there are (one
# grep, one stat, one ioreg, the sleep): a process per session per second
# was 60 new processes a second with a dozen tabs open. A session counts
# as busy while its transcript changed in the last QUIET_SECS, or while
# the hook says it is running, unless the transcript shows the turn is
# over (an API error or Esc ends it without the hook hearing; transcript
# saving off looks quiet forever, so the hook's word counts too).
function wait_until_quiet() {
    local sessions="$1"
    local base=$(date +%s) last=""
    local -a cwds=() sids=() files=() ended_at=() ended=()
    local cwd sid flags n=0 i
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] && continue
        cwds[n]="$cwd"; sids[n]="$sid"
        files[n]="$HOME/.claude/projects/$(sed 's/[^A-Za-z0-9]/-/g' <<<"$cwd")/$sid.jsonl"
        ended_at[n]=""; ended[n]=1
        n=$((n + 1))
    done <<<"$sessions"
    while true; do
        local now=$((base + SECONDS)) busy="" active="" left=0 idle=0 typing running mtimes
        running=$(grep -h '"status":"running"' "$STATE_DIR"/sessions/*.json 2>/dev/null)
        mtimes=$'\n'$(stat -f '%m %N' "${files[@]}" 2>/dev/null)$'\n'
        for ((i = 0; i < n; i++)); do
            local m q
            m="${mtimes%%" ${files[i]}"$'\n'*}"
            if [ "$m" = "$mtimes" ]; then m=""; else m="${m##*$'\n'}"; fi
            q=$([ -n "$m" ] && echo $((now - m)) || echo 999999)
            if [[ "$running" == *"\"session_id\":\"${sids[i]}\""* ]]; then
                # Only read again when the transcript has changed.
                if [ "${ended_at[i]}" != "$m" ]; then
                    ended_at[i]="$m"
                    turn_ended "${files[i]}" && ended[i]=1 || ended[i]=0
                fi
                [ "${ended[i]}" = 0 ] && q=0
            fi
            [ "$q" -lt "$QUIET_SECS" ] || continue
            busy="$busy ${cwds[i]##*/}"
            [ "$q" -lt 5 ] && active="${active:+$active, }${cwds[i]##*/}"
            [ $((QUIET_SECS - q)) -gt "$left" ] && left=$((QUIET_SECS - q))
        done
        # Typing only matters once no session is active.
        if [ -z "$active" ]; then
            idle=$(input_idle_secs)
            idle=${idle:-$INPUT_IDLE_SECS}
        fi
        typing=$((INPUT_IDLE_SECS - idle))
        [ -n "$active" ] && typing=0
        [ -z "$busy" ] && [ "$typing" -le 0 ] && return 0
        if [ $((now - base)) -gt "$GIVE_UP_SECS" ]; then
            log "gave up: still busy:$busy"
            return 1
        fi
        if [ -n "$active" ]; then
            status busy 0 "$active"
        elif [ "$typing" -gt "$left" ]; then
            status typing $((now + typing))
        else
            status quiet $((now + left))
        fi
        [ "$busy" != "$last" ] && [ -n "$busy" ] && log "waiting for:$busy"
        last="$busy"
        sleep 1
    done
}

# Seconds since the last key press, click or mouse move (one ioreg, no awk).
function input_idle_secs() {
    local out
    out=$(ioreg -c IOHIDSystem 2>/dev/null)
    [[ "$out" =~ \"HIDIdleTime\"\ =\ ([0-9]+) ]] && echo $((BASH_REMATCH[1] / 1000000000))
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
    local cpid hsid args
    load_bypass_opt
    while IFS=$'\t' read -r cpid hsid args; do
        describe "$cpid" "$hsid" "$args"
    done < <(claude_table "$@") | awk -F'\t' '$2 == "" || !seen[$2]++'
}

# "<pid>\t<hook session id or ->\t<command>" for every claude under the
# given pids, from one ps and one grep: the app saves every 10 s, and a ps,
# grep, xargs, ls, head and sed for each session was over 10 new processes
# a second with 15 open. The hook's newest file for a pid wins, as in
# hook_session.
function claude_table() {
    local roots="$*" files hooks=""
    [ -z "$roots" ] && return 0
    files=$(ls -t "$STATE_DIR"/sessions/*.json 2>/dev/null)
    if [ -n "$files" ]; then
        local IFS=$'\n'
        # shellcheck disable=SC2086
        hooks=$(grep -Ho '"session_id":"[^"]*"\|"claude_pid":[0-9]*' $files 2>/dev/null)
    fi
    # macOS awk takes no newlines in -v, so the hook lines come as a file.
    procs | awk -v roots="$roots" '
        BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) root[r[i]] = 1 }
        FILENAME != "-" {
            if ($0 == "") next
            f = $0; sub(/:.*/, "", f); v = substr($0, length(f) + 2)
            if (f != cur) { cur = f; pid = ""; sid = "" }
            if (v ~ /^"claude_pid":/) { pid = v; sub(/.*:/, "", pid) }
            else { sid = v; sub(/^"session_id":"/, "", sid); sub(/"$/, "", sid) }
            if (pid != "" && sid != "" && !(pid in hook)) { hook[pid] = sid; pid = "x" }
            next
        }
        { parent[$1] = $2; line = $0; sub(/^ *[0-9]+ +[0-9]+ +[^ ]+ +[^ ]+ +/, "", line); cmd[$1] = line }
        END {
            for (p in cmd) {
                if (cmd[p] !~ /^([^ ]*\/)?claude( |$)/) continue
                if (cmd[p] ~ / (-p|--print)( |$)/) continue
                q = p
                while (q > 1) {
                    q = parent[q]
                    if (q in root) { print p "\t" ((p in hook) ? hook[p] : "-") "\t" cmd[p]; break }
                }
            }
        }' <(printf '%s\n' "$hooks") -
}

# True while a restart is quitting the app and reopening its sessions; a
# marker left by one that died is ignored after 10 minutes.
function restarting() {
    [ -e "$RESTARTING" ] && [ -n "$(find "$RESTARTING" -mmin -10 2>/dev/null)" ]
}

# A claude in a terminal whose SessionStart hook never recorded it (it timed
# out: after a power cut every session starts at once and the Mac is busy)
# shows as a plain shell until its next prompt. This records it as that hook
# would have, from the claude's own environment, once it has run for 30 s.
function backfill_status() {
    local hook="$HOME/.local/bin/ghostty-dock-hook" sessions="$STATE_DIR/sessions"
    [ -x "$hook" ] || return 0
    local recorded="" read_recorded=false line cpid _ppid tty etime sid env cwd var
    while read -r cpid _ppid tty etime line; do
        [ -n "$cpid" ] && [ "$tty" != "??" ] || continue
        [[ "$line" =~ ^claude\ .*--(session-id|resume)\ ([0-9a-f-]{36})(\ |$) ]] || continue
        sid="${BASH_REMATCH[2]}"
        # Read only once there is a claude to check it for.
        $read_recorded || { recorded=$(cat "$sessions"/*.json 2>/dev/null | grep -o '"session_id":"[^"]*"'); read_recorded=true; }
        [[ "$recorded" == *"\"session_id\":\"$sid\""* ]] && continue
        # etime is [[dd-]hh:]mm:ss: under 30 s, its own hook may still come.
        [[ "$etime" =~ ^00:([0-2][0-9])$ ]] && continue
        env=$(ps -E -ww -o command= -p "$cpid" 2>/dev/null | tr ' ' '\n')
        cwd=$(lsof -a -p "$cpid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
        [ -d "$cwd" ] || continue
        local vars=()
        for var in GHOSTTY_DOCK_HOLD GHOSTTY_DOCK_SURFACE DOCK_TAB_ID; do
            vars+=("$(grep -m1 "^$var=" <<<"$env" || echo "$var=")")
        done
        jq -nc --arg sid "$sid" --arg cwd "$cwd" \
            '{hook_event_name: "SessionStart", source: "resume", session_id: $sid, cwd: $cwd}' |
            env "${vars[@]}" GHOSTTY_DOCK_TEST_LINEAGE="$cpid - $tty" "$hook" >/dev/null 2>&1
        log "recorded $(basename "$cwd"): its SessionStart hook did not ($sid)"
    done < <(procs | awk '$5 == "claude"')
    return 0
}

function save() {
    restarting && return 0
    # One look at every process for the whole save (see procs).
    local PROCS
    PROCS=$(ps -axo pid=,ppid=,tty=,etime=,command=)
    local pid
    pid=$(app_pid)
    [ -z "$pid" ] && return 0
    local me owner
    # In C: the app and a script run from a terminal can have different
    # locales, and each took the other's list for another Mac's, restored
    # it and wrote its own (2026-11-26).
    me="$pid $(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)"
    # IFS=: ps pads lstart with spaces, which read would trim.
    [ -f "$SAVED_BY" ] && IFS= read -r owner <"$SAVED_BY"
    # Written in the locale's format before that: still this app's.
    [ -n "$owner" ] && [ "$owner" != "$me" ] && [ "${owner%% *}" = "$pid" ] &&
        [ "$owner" = "$pid $(ps -o lstart= -p "$pid" 2>/dev/null)" ] && owner="$me"
    # Moving to a new Mac: the app there ran before the old one's state was
    # copied in, so its first --save wrote over the copied list and the
    # sessions were never reopened. A list this app did not write is
    # restored first.
    if [ -s "$SAVED" ] && [ "$owner" != "$me" ]; then
        if restore_enabled; then
            restore_foreign
        else
            rm -f "$SAVED"
        fi
    fi
    # Held sessions too: a reboot ends their holders, and then they are
    # resumed like the rest.
    open_sessions "$pid" $(holder_pids) >"$SAVED.tmp" || return 0
    note_ended "$SAVED" "$SAVED.tmp"
    mv "$SAVED.tmp" "$SAVED" && echo "$me" >"$SAVED_BY"
    backfill_status
    # Forgets processes that have ended.
    local f
    for f in "$DESCRIBED"/*; do
        [ -f "$f" ] && ! kill -0 "${f##*/}" 2>/dev/null && rm -f "$f"
    done
    return 0
}

# Records the sessions in the old list (first argument) and not the new one
# (second), and forgets those back in it and any over a day old.
function note_ended() {
    local old="$1"
    local new="$2"
    local now cwd sid flags at newtext ended=""
    now=$(date +%s)
    newtext=$(<"$new")
    [ -s "$ENDED" ] && ended=$(<"$ENDED")
    {
        [ -s "$ENDED" ] && while IFS=$'\t' read -r cwd sid at flags; do
            [ -n "$sid" ] && [ $((now - ${at:-0})) -lt 86400 ] || continue
            [[ "$newtext" == *$'\t'"$sid"$'\t'* ]] && continue
            printf '%s\t%s\t%s\t%s\n' "$cwd" "$sid" "$at" "$flags"
        done <"$ENDED"
        [ -s "$old" ] && while IFS=$'\t' read -r cwd sid flags; do
            [ -n "$sid" ] || continue
            [[ "$newtext" == *$'\t'"$sid"$'\t'* ]] && continue
            [[ "$ended" == *$'\t'"$sid"$'\t'* ]] && continue
            printf '%s\t%s\t%s\t%s\n' "$cwd" "$sid" "$now" "$flags"
        done <"$old"
    } >"$ENDED.tmp"
    if [ -s "$ENDED.tmp" ]; then mv "$ENDED.tmp" "$ENDED"; else rm -f "$ENDED.tmp" "$ENDED"; fi
}

# After a quit or shutdown: sessions that ended in the 5 minutes before the
# last save (the first argument, epoch) and whose tab was not closed by hand
# are listed as not come back, so the sidebar shows them.
function recover_ended() {
    local last="$1"
    [ -s "$ENDED" ] || return 0
    local history="$STATE_DIR/history.json" cwd sid flags at closed together
    local times
    times=$(cut -f3 "$ENDED")
    while IFS=$'\t' read -r cwd sid at flags; do
        [ -n "$sid" ] && [ -d "$cwd" ] || continue
        [ "${at:-0}" -ge $((last - 300)) ] || continue
        # Several sessions ending within seconds of each other is not tabs
        # closed by hand: the app notes each in its history as it goes, which
        # would otherwise read as closed. (2026-11-22: a force-quit of Chrome
        # ended 14 at once and none were offered back.)
        together=$(awk -v t="${at:-0}" '$1 >= t - 10 && $1 <= t + 10' <<<"$times" | grep -c .)
        if [ "$together" -lt 3 ]; then
            # History's closedAt counts from 2001 (Apple's reference date).
            closed=$(jq -r --arg sid "$sid" '[.[]? | select(.sessionId == $sid) | .closedAt + 978307200 | floor] | max // 0' \
                "$history" 2>/dev/null)
            [ "${closed:-0}" -ge $((at - 120)) ] && continue
        else
            log "$(basename "$cwd") ended with $((together - 1)) other session(s) at once (mass exit), so not counted as closed by hand"
        fi
        running_anywhere "$sid" && continue
        log "$(basename "$cwd") ended before the last save (shutdown?); recorded in $(basename "$MISSING")"
        record_missing "$cwd" "$sid" "$flags"
    done <"$ENDED"
    rm -f "$ENDED"
}

# The app's "Reopen sessions after a quit" setting (on unless turned off).
function restore_enabled() {
    [ "$(defaults read consulting.cloudscale.ghosttydock dock.restoreSessions 2>/dev/null)" != 0 ]
}

# Reopens a saved list some other app instance wrote, as --restore would,
# but without reattaching held tabs: this app is already running them.
function restore_foreign() {
    local sessions
    sessions=$(cat "$SAVED")
    rm -f "$SAVED"
    log "restore: sessions saved by another app instance (copied from another Mac?): $(conditions)"
    reopen_all "$sessions" "$(open_sessions $(holder_pids) | cut -f2)"
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
    local held
    held=$(held_items)
    [ -n "$held" ] && log "reattaching $(grep -c . <<<"$held") terminal(s)"
    local last
    last=$(stat -f %m "$SAVED" 2>/dev/null || date +%s)
    if [ ! -s "$SAVED" ]; then
        open_items "$LAYOUT" <<<"$held"
        recover_ended "$last"
        return 0
    fi
    local sessions
    sessions=$(cat "$SAVED")
    rm -f "$SAVED"
    log "restore: $(conditions)"
    reopen_all "$sessions" "$(open_sessions $(holder_pids) | cut -f2)" "$held"
    recover_ended "$last"
}

# Opens a tab for each terminal left running without one, as when a window
# is closed with its sessions kept; nothing else is reopened.
function reattach() {
    restarting && { log "reattach: skipped, a restart is reopening the sessions"; return 0; }
    local held
    held=$(held_items)
    [ -z "$held" ] && return 0
    log "reattaching $(grep -c . <<<"$held") terminal(s) from a closed window"
    open_items "$LAYOUT" <<<"$held"
}

# Prints "<surface>\t<folder>\t<command>" reattaching every holder left
# without a tab, so what ran in the tabs before a quit, crash or restart
# is back with its output. <surface> is the terminal it was in, or "-".
function held_items() {
    local name hpid attached cwd rest surface
    while IFS=$'\t' read -r name hpid attached cwd rest; do
        [ -n "$name" ] && [ "$attached" = 0 ] || continue
        [ -d "$cwd" ] || cwd="$HOME"
        surface=$(cat "$STATE_DIR/hold/$name.surface" 2>/dev/null)
        printf '%s\t%s\t%s\n' "${surface:--}" "$cwd" "'$HOLD' attach $name"
    done < <(holders --detached)
}

# The terminal a session was last in, from the hook's state.
function session_surface() {
    local files file
    files=$(grep -l "\"session_id\":\"$1\"" "$STATE_DIR"/sessions/srf-*.json 2>/dev/null)
    # Not through xargs: GNU xargs runs ls with no files, listing the folder.
    [ -n "$files" ] || return 0
    file=$(ls -t $files | head -1)
    file="${file##*/srf-}"
    echo "${file%.json}"
}

# Prints "<surface>\t<folder>\t<command>" resuming each session not
# already running.
function session_items() {
    local cwd sid flags surface
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] && continue
        # Once only: never a second tab on a session already back.
        running_anywhere "$sid" && continue
        surface=$(session_surface "$sid")
        printf '%s\t%s\t%s\n' "${surface:--}" "$cwd" "$(awake)claude$(rcdebug "$sid") --resume $sid $flags"
    done <<<"$1"
}

# What to open, in order, to put the given terminals back as they were
# split: "tab <surface>" for each tab's first terminal, then "split
# <surface> <beside> <right|down>" for the others. Terminals gone are left
# out of their tab's tree; those in no tab are not listed.
function layout_plan() {
    local layout="$1"
    shift
    [ -s "$layout" ] && command -v jq >/dev/null || return 0
    jq -r '
        def keep: if .s then (if (.s | IN($ARGS.positional[])) then . else null end)
            else (.l | keep) as $l | (.r | keep) as $r
                | if $l and $r then {d, l: $l, r: $r} else ($l // $r) end end;
        def lead: if .s then .s else .l | lead end;
        def steps: if .s then empty
            else "split \(.r | lead) \(.l | lead) \(.d)", (.l | steps), (.r | steps) end;
        .tabs[]? | keep | select(. != null) | "tab \(lead)", steps' "$layout" --args "$@" 2>/dev/null
}

# Opens the "<surface>\t<folder>\t<command>" lines on stdin, each in a
# tab of its own, but the terminals that shared a tab before (the layout
# file says which) as splits of one tab again.
function open_items() {
    local layout="$1"
    local items surfaces opened="" n=0
    items=$(grep .)
    [ -z "$items" ] && return 0
    surfaces=$(cut -f1 <<<"$items" | grep -vx -- -)
    local step surface beside direction line cwd cmd new to
    while read -r step surface beside direction; do
        line=$(awk -F'\t' -v s="$surface" '$1 == s { print; exit }' <<<"$items")
        [ -z "$line" ] && continue
        IFS=$'\t' read -r _ cwd cmd <<<"$line"
        new=""
        if [ "$step" = split ]; then
            to=$(awk -v s="$beside" '$1 == s { print $2; exit }' <<<"$opened")
            [ -n "$to" ] && new=$("$OPENER" --print-terminal --split "$to" --direction "$direction" --command "$cmd" "$cwd" 2>>"$LOG")
            [ -z "$new" ] && log "$(basename "$cwd"): could not split it beside the terminal it was beside; opening a tab"
        fi
        [ -z "$new" ] && new=$("$OPENER" --print-terminal --command "$cmd" "$cwd" 2>>"$LOG")
        [ -z "$new" ] && log "$(basename "$cwd"): opening the tab failed"
        opened+="$surface ${new:--}"$'\n'
        n=$((n + 1))
    done < <(layout_plan "$layout" $surfaces)
    [ "$n" -gt 0 ] && log "put back $n terminal(s) of split tabs"
    # The rest, a tab each, all in one go: a tab at a time took seconds each.
    local tabs=""
    while IFS=$'\t' read -r surface cwd cmd; do
        [ "$surface" != - ] && grep -q "^$surface " <<<"$opened" && continue
        tabs+="$cmd"$'\t'"$cwd"$'\n'
    done <<<"$items"
    [ -n "$tabs" ] || return 0
    printf '%s' "$tabs" | "$OPENER" --batch >>"$LOG" 2>&1 || log "opening some tabs failed"
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
# second argument lists ids already back in a holder; the third, holders
# to reattach with them (held_items), so a tab split between the two kinds
# comes back as one.
function reopen_all() {
    local sessions="$1"
    local held="${2:-}"
    local reattach="${3:-}"
    local cwd sid flags todo=""
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] || [ ! -d "$cwd" ] && continue
        running_anywhere "$sid" && continue
        grep -qxF "$sid" <<<"$held" && continue
        todo+="$cwd"$'\t'"$sid"$'\t'"$flags"$'\n'
    done <<<"$sessions"
    if [ -n "$todo" ]; then
        resume_all "$todo" "$reattach" "$LAYOUT"
    else
        open_items "$LAYOUT" <<<"$reattach"
    fi
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

# Opens a tab resuming each session, with the holders to reattach (the
# second argument, held_items) and in the splits the layout file (the
# third) records, then checks they started, tries the missing ones once
# more and records any still missing in $MISSING.
function resume_all() {
    local sessions="$1"
    local reattach="${2:-}"
    local layout="${3:-$LAYOUT}"
    local cwd sid flags
    while IFS=$'\t' read -r cwd sid flags; do
        [ -n "$sid" ] && log "resuming $(basename "$cwd")"
    done <<<"$sessions"
    printf '%s\n%s\n' "$reattach" "$(session_items "$sessions")" | open_items "$layout"
    sleep 20
    while IFS=$'\t' read -r cwd sid flags; do
        [ -z "$sid" ] && continue
        running_anywhere "$sid" && continue
        log "$(basename "$cwd") did not start; trying again ($(conditions))"
        wait_for_display
        "$OPENER" --command "$(awake)claude$(rcdebug "$sid") --resume $sid $flags" "$cwd" >>"$LOG" 2>&1 \
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
    local fresh="${3:-false}"
    # A fresh restart still to do stays asked for: a later restart (the
    # app's Restart button replaces one waiting) does it fresh too.
    local fresh_mark="$STATE_DIR/restart-fresh"
    if $fresh; then touch "$fresh_mark"; elif [ -f "$fresh_mark" ]; then fresh=true; fi
    local pid
    pid=$(app_pid)
    [ -z "$pid" ] && { log "Ghostty Dock is not running"; return 1; }

    local sessions held cpid
    sessions=$(open_sessions "$pid")
    held=$(open_sessions $(holder_pids))
    # Fresh: the held sessions resume too, in new holders of this app.
    local shells=""
    if $fresh; then
        sessions=$(printf '%s\n%s\n' "$sessions" "$held" | grep . | awk -F'\t' '$2 == "" || !seen[$2]++')
        local name hpid attached hcwd rest
        while IFS=$'\t' read -r name hpid attached hcwd rest; do
            [ -n "$hpid" ] && [ -z "$(claudes_under "$hpid")" ] && shells+="$hcwd"$'\n'
        done < <(holders)
        held=""
    fi
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
    # Before any of its terminals close: the app may record the splits again
    # as the sessions end.
    cp -f "$LAYOUT" "$LAYOUT_KEPT" 2>/dev/null || rm -f "$LAYOUT_KEPT"
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
    if $fresh; then
        local hp
        for hp in $(holder_pids); do
            for cpid in $(claudes_under "$hp"); do kill -TERM "$cpid" 2>/dev/null; done
        done
        sleep 3
        "$HOLD" kill-detached 2>/dev/null
        for ((i = 0; i < 20; i++)); do [ -z "$(holders)" ] && break; sleep 0.5; done
        log "fresh: ended $(grep -c . <<<"$shells") shell(s) and the held sessions, to start again"
    fi

    # The opener starts the app with window-save-state=never, so it comes up
    # with only these tabs.
    local reattach
    reattach=$(held_items)
    [ -n "$reattach" ] && log "reattaching $(grep -c . <<<"$reattach") terminal(s)"
    if [ -n "$sessions" ]; then
        resume_all "$sessions" "$reattach" "$LAYOUT_KEPT"
    else
        open_items "$LAYOUT_KEPT" <<<"$reattach"
    fi
    local dir
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        [ -d "$dir" ] || dir="$HOME"
        "$OPENER" --shell "$dir" >>"$LOG" 2>&1 || log "$(basename "$dir"): opening the shell failed"
    done <<<"$shells"
    rm -f "$RESTARTING" "$LAYOUT_KEPT"
    $fresh && rm -f "$fresh_mark"
    log "done"
}

function main() {
    # Sessions we start must not inherit a Claude Code parent marker
    # (CLAUDE_CODE_CHILD_SESSION turns off their transcript saving), nor the
    # Ghostty Dock ids of the tab this runs in (its row would be overwritten).
    unset CLAUDECODE CLAUDE_PID GHOSTTY_DOCK_SURFACE DOCK_TAB_ID
    # Without a grep: the app runs this every few seconds.
    local var
    for var in $(compgen -e); do [[ "$var" == CLAUDE_CODE_* ]] && unset "$var"; done
    local now=false
    local fresh=false
    local dry=false
    local foreground=false
    local args=("$@")
    while [ "$1" != "" ]; do
        case $1 in
        --now) now=true ;;
        --fresh) fresh=true ;;
        --dry-run) dry=true; foreground=true ;;
        --foreground) foreground=true ;;
        --save)
            [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" || exit 1
            save
            exit 0
            ;;
        --reopen-missing)
            mkdir -p "$STATE_DIR" || exit 1
            [ -x "$OPENER" ] || { echo "Error: $OPENER missing, run install.sh" >&2; exit 1; }
            reopen_missing
            exit 0
            ;;
        --reattach)
            mkdir -p "$STATE_DIR" || exit 1
            [ -x "$OPENER" ] || { echo "Error: $OPENER missing, run install.sh" >&2; exit 1; }
            reattach
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
    restart "$now" "$dry" "$fresh"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
