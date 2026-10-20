#!/usr/bin/env bash

# Undo: puts every Claude Code session back the way it was before Ghostty
# Dock, one stock Ghostty app per session, each with its own Dock icon.
#
# Sessions come from the snapshot that move-to-dock.sh and restart-dock.sh
# write before they stop anything (sessions-snapshot.tsv), plus the session
# ids in their logs. Each one not already running is reopened with
# `claude --resume <id>` and its original flags, in the folder its
# transcript records. Nothing running is stopped.
#
# Then: Ghostty shows in the Dock and Cmd-Tab again (macos-hidden removed),
# the Finder Quick Actions are restored from their backups, and
# ghostty-dock-open goes back to opening stock Ghostty.

DEPENDENCIES=(jq perl open)
SCRIPT_NAME=$(basename "$0")
STATE_DIR="$HOME/.local/state/ghostty-dock"
SNAPSHOT="$STATE_DIR/sessions-snapshot.tsv"
BACKUP_DIR="$STATE_DIR/backup"
GHOSTTY_APP="/Applications/Ghostty.app"
GHOSTTY_CONFIG="$HOME/.config/ghostty/config"
SERVICES="$HOME/Library/Services"
DISABLED_MARK="$STATE_DIR/disabled"

function usage() {
    cat <<EOM

Puts Claude Code sessions back into separate stock Ghostty apps and undoes
Ghostty Dock's changes to Ghostty, Finder and the opener.

usage: ${SCRIPT_NAME} [options] [session-id ...]

options:
    --list           Only list the sessions it would reopen
    --sessions-only  Reopen sessions; leave settings and Quick Actions alone
    -h|--help        Show this help message

With session ids, reopens just those.

dependencies: ${DEPENDENCIES[@]}

EOM
    exit 1
}

# Prints "<session id>\t<flags>" for every session Ghostty Dock has moved,
# newest entry per id last.
function known_sessions() {
    {
        [ -f "$SNAPSHOT" ] && cut -f1,3 "$SNAPSHOT"
        cat "$STATE_DIR"/*.log 2>/dev/null |
            sed -nE 's/.*claude --resume ([0-9a-f-]{36}) ?([^)]*)\).*/\1\t\2/p'
    } | awk -F'\t' '{ flags[$1] = $2; if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 } }
        END { for (i = 1; i <= n; i++) print order[i] "\t" flags[order[i]] }'
}

function transcript_of() {
    find "$HOME/.claude/projects" -maxdepth 2 -name "$1.jsonl" 2>/dev/null | head -1
}

function cwd_of() {
    local file
    file=$(transcript_of "$1")
    [ -n "$file" ] && jq -r 'select(.cwd != null) | .cwd' "$file" 2>/dev/null | tail -1
}

# Running under its id, or as `claude --continue` in its folder.
function running() {
    local sid="$1"
    local cwd="$2"
    pgrep -f -- "claude .*$sid" >/dev/null && return 0
    local pid
    for pid in $(pgrep -f -- 'claude .*--continue'); do
        [ "$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" = "$cwd" ] && return 0
    done
    return 1
}

function reopen() {
    local sid="$1"
    local flags="$2"
    local list="$3"
    local cwd
    cwd=$(cwd_of "$sid")
    if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
        print_warning "$sid: no transcript or folder found, skipped"
        return
    fi
    local name
    name=$(basename "$cwd")
    if running "$sid" "$cwd"; then
        print_success "$name: already running"
        return
    fi
    local cmd="caffeinate -i claude --resume $sid $flags"
    if $list; then
        echo "  $name: $cmd"
        return
    fi
    # One --command argument: with -e, Ghostty also opened "/bin/zsh" as a tab.
    open -na "$GHOSTTY_APP" --args --window-save-state=never --quit-after-last-window-closed=true \
        --working-directory="$cwd" --command="$cmd" || {
        print_error "$name: Ghostty did not start"
        return
    }
    print_success "$name: reopened in its own Ghostty"
    sleep 1
}

function unhide_ghostty() {
    [ -f "$GHOSTTY_CONFIG" ] || return
    if grep -q '^macos-hidden = always' "$GHOSTTY_CONFIG"; then
        perl -0pi -e 's/\n?# ghostty-dock: one Dock icon[^\n]*\nmacos-hidden = always\n//' "$GHOSTTY_CONFIG"
        pkill -USR2 -f "^$GHOSTTY_APP/Contents/MacOS/ghostty" 2>/dev/null
        print_success "Ghostty is back in the Dock and Cmd-Tab"
    fi
}

function restore_quick_actions() {
    local backup name
    for backup in "$BACKUP_DIR"/*.workflow.document.wflow; do
        [ -f "$backup" ] || continue
        name=$(basename "$backup" .document.wflow)
        [ -d "$SERVICES/$name/Contents" ] || continue
        cp "$backup" "$SERVICES/$name/Contents/document.wflow" && print_success "Quick Action restored: ${name%.workflow}"
    done
}

function main() {
    # Sessions we start must not inherit a Claude Code parent marker
    # (CLAUDE_CODE_CHILD_SESSION turns off their transcript saving), nor the
    # Ghostty Dock ids of the tab this runs in (its row would be overwritten).
    unset CLAUDECODE CLAUDE_PID GHOSTTY_DOCK_SURFACE DOCK_TAB_ID $(compgen -e | grep "^CLAUDE_CODE_")
    local list=false
    local sessions_only=false
    local only=()
    while [ "$1" != "" ]; do
        case $1 in
        --list) list=true ;;
        --sessions-only) sessions_only=true ;;
        -h | --help) usage ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            usage
            ;;
        *) only+=("$1") ;;
        esac
        shift
    done
    exit_on_missing_tools "${DEPENDENCIES[@]}"

    local sessions
    sessions=$(known_sessions)
    if [ "${#only[@]}" -gt 0 ]; then
        sessions=$(grep -F -f <(printf '%s\n' "${only[@]}") <<<"$sessions")
        local sid
        for sid in "${only[@]}"; do
            grep -q "^$sid" <<<"$sessions" || sessions+=$'\n'"$sid"$'\t'"--dangerously-skip-permissions"
        done
    fi
    [ -z "$sessions" ] && print_warning "no sessions recorded"

    echo "Sessions:"
    local sid flags
    while IFS=$'\t' read -r sid flags; do
        [ -n "$sid" ] && reopen "$sid" "$flags" "$list"
    done <<<"$sessions"
    if $list || $sessions_only; then
        return
    fi

    echo "Settings:"
    unhide_ghostty
    restore_quick_actions
    mkdir -p "$STATE_DIR" && touch "$DISABLED_MARK"
    print_success "ghostty-dock-open opens stock Ghostty again (delete $DISABLED_MARK to undo)"
}

function print_success() {
    echo -e "  \033[0;32m✓\033[0m $1"
}

function print_warning() {
    echo -e "  \033[1;33m!\033[0m $1"
}

function print_error() {
    echo -e "  \033[0;31m✗\033[0m $1" >&2
}

function exit_on_missing_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || { echo "Error: '$tool' is required" >&2; exit 1; }
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
