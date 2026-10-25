#!/usr/bin/env bash

# Installs Ghostty Dock: the opener and the Claude Code hook into
# ~/.local/bin, the hook into ~/.claude/settings.json, the "Launch ... in
# Ghostty" Finder Quick Actions added if missing and switched to open tabs,
# and the app (Ghostty
# with the session sidebar built in, scripts/build-terminal.sh) into
# ~/Applications. From a release zip, the app is already built and is copied.

DEPENDENCIES=(jq perl codesign launchctl)
SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")" && pwd)
BIN_DIR="$HOME/.local/bin"
SETTINGS="$HOME/.claude/settings.json"
SERVICES="$HOME/Library/Services"
STATE_DIR="$HOME/.local/state/ghostty-dock"
AGENT_LABEL="consulting.cloudscale.ghosttydock"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
APP="$HOME/Applications/Ghostty Dock.app"
HOOK_EVENTS=(SessionStart UserPromptSubmit PreToolUse PostToolUse Notification Stop SessionEnd)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
if [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]]; then
    RED="" GREEN="" YELLOW="" BLUE="" NC=""
fi

function usage() {
    cat <<EOM

Installs (or removes) Ghostty Dock.

usage: ${SCRIPT_NAME} [options]

options:
    --skip-app       Install scripts, hooks and Quick Actions only; do not build the app
    --uninstall      Remove the hooks, scripts, LaunchAgent and app. Quick Actions
                     fall back to one Ghostty app per session on their own once
                     ghostty-dock-open is gone.
    -h|--help        Show this help message

dependencies: ${DEPENDENCIES[@]} (and swift to build the app)

EOM
    exit 1
}

function main() {
    local skip_app=false
    local uninstall=false
    while [ "$1" != "" ]; do
        case $1 in
        --skip-app) skip_app=true ;;
        --uninstall) uninstall=true ;;
        -h | --help) usage ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage
            ;;
        esac
        shift
    done
    exit_on_missing_tools "${DEPENDENCIES[@]}"

    if $uninstall; then
        uninstall_all
        return
    fi

    print_step 1 4 "Scripts into $BIN_DIR"
    install_scripts || exit 1
    print_step 2 4 "Claude Code hooks in $SETTINGS"
    install_hooks || exit 1
    print_step 3 4 "Finder Quick Actions open tabs"
    add_quick_actions || exit 1
    switch_quick_actions || exit 1
    if $skip_app; then
        print_warning "skipped the app (--skip-app)"
        return
    fi
    # A release zip carries the app ready-built (scripts/release.sh).
    if [ -d "$ROOT/Ghostty Dock.app" ]; then
        print_step 4 4 "Install the app"
        mkdir -p "$(dirname "$APP")" && rm -rf "$APP" && ditto "$ROOT/Ghostty Dock.app" "$APP" || exit 1
    else
        print_step 4 4 "Build and install the app"
        exit_on_missing_tools swift
        bash "$ROOT/scripts/build-terminal.sh" --no-open || exit 1
    fi
    print_success "Ghostty Dock is installed: open it from ~/Applications"
    echo "  - Sessions already open keep their own Ghostty app until closed."
}

function install_scripts() {
    mkdir -p "$BIN_DIR" || return 1
    local f
    for f in ghostty-dock ghostty-dock-open ghostty-dock-hook; do
        install -m 0755 "$ROOT/bin/$f" "$BIN_DIR/$f" || { print_error "could not install $f"; return 1; }
    done
    install -m 0755 "$ROOT/scripts/move-to-dock.sh" "$BIN_DIR/ghostty-dock-move" ||
        { print_error "could not install ghostty-dock-move"; return 1; }
    install -m 0755 "$ROOT/scripts/restart-dock.sh" "$BIN_DIR/ghostty-dock-restart" ||
        { print_error "could not install ghostty-dock-restart"; return 1; }
    print_success "ghostty-dock, ghostty-dock-open, ghostty-dock-hook, ghostty-dock-move, ghostty-dock-restart"
}

function install_hooks() {
    if [ ! -f "$SETTINGS" ]; then
        mkdir -p "$(dirname "$SETTINGS")" && echo '{}' >"$SETTINGS"
    fi
    if ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
        print_error "$SETTINGS is not valid JSON; not touching it"
        return 1
    fi
    local backup="$STATE_DIR/backup/settings.json.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$backup")" && cp "$SETTINGS" "$backup" || return 1

    local cmd="$BIN_DIR/ghostty-dock-hook"
    local events_json
    events_json=$(printf '%s\n' "${HOOK_EVENTS[@]}" | jq -R . | jq -s .)
    local tmp="$SETTINGS.ghostty-dock.tmp"
    # PreToolUse only matters for questions; every other tool call is already
    # "running" from the prompt, and PostToolUse clears a question once answered.
    jq --arg cmd "$cmd" --argjson events "$events_json" '
        def mine: any(.hooks[]?; (.command // "") | contains("ghostty-dock-hook"));
        reduce $events[] as $ev (.;
            .hooks[$ev] = ((.hooks[$ev] // []) as $list
                | if any($list[]; mine) then $list
                  else $list + [{
                      matcher: (if $ev == "PreToolUse" then "AskUserQuestion|ExitPlanMode" else "" end),
                      hooks: [{type: "command", command: $cmd, timeout: 5}]
                  }] end))
    ' "$SETTINGS" >"$tmp" && jq -e . "$tmp" >/dev/null && mv -f "$tmp" "$SETTINGS" || {
        rm -f "$tmp"
        print_error "could not update $SETTINGS (backup: $backup)"
        return 1
    }
    print_success "hooked ${HOOK_EVENTS[*]} (backup: $backup)"
}

# Adds the two Quick Actions Settings → Shortcuts → In Finder gives keys
# to, from Resources/quick-actions, when they are not there (claude-burst
# installs its own; those are kept).
function add_quick_actions() {
    local src name added=0
    for src in "$ROOT/Resources/quick-actions"/*.workflow; do
        [ -d "$src" ] || continue
        name=$(basename "$src")
        [ -e "$SERVICES/$name" ] && continue
        mkdir -p "$SERVICES" && ditto "$src" "$SERVICES/$name" || return 1
        echo "  - ${name%.workflow}"
        added=$((added + 1))
    done
    # Tells the Services menu to read them again, so they work straight away.
    ((added > 0)) && /System/Library/CoreServices/pbs -flush >/dev/null 2>&1
    print_success "$added Quick Action(s) added"
}

# Rewrites the `open -na Ghostty.app ... -e "<launcher>" "$folder" &` line of
# each installed Quick Action into the same shape claude-burst now writes:
# prefer ghostty-dock-open, else the old command.
function switch_quick_actions() {
    local changed=0
    local doc
    for doc in "$SERVICES"/*.workflow/Contents/document.wflow; do
        [ -f "$doc" ] || continue
        grep -q 'open -na Ghostty.app --args' "$doc" || continue
        grep -q 'ghostty-dock-open' "$doc" && continue
        local name
        name=$(basename "$(dirname "$(dirname "$doc")")")
        mkdir -p "$STATE_DIR/backup" && cp "$doc" "$STATE_DIR/backup/$name.document.wflow" || return 1
        perl -0pi -e '
            s{^(\s*)(open -na Ghostty\.app --args --window-save-state=never --quit-after-last-window-closed=true -e "([^"]+)" "\$folder" &amp;)$}
             {$1if [ -x "\$HOME/.local/bin/ghostty-dock-open" ]; then\n$1  "\$HOME/.local/bin/ghostty-dock-open" "$3" "\$folder" &amp;\n$1else\n$1  $2\n$1fi}mg
        ' "$doc" || return 1
        if grep -q 'ghostty-dock-open' "$doc" && plutil -lint "$doc" >/dev/null; then
            changed=$((changed + 1))
            echo "  - $name"
        else
            cp "$STATE_DIR/backup/$name.document.wflow" "$doc"
            print_warning "$name: unexpected shape, left as it was"
        fi
    done
    print_success "$changed Quick Action(s) switched"
}

function install_agent() {
    mkdir -p "$(dirname "$AGENT_PLIST")" || return 1
    cat >"$AGENT_PLIST" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$AGENT_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/GhosttyDock</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOP
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null
    pkill -x GhosttyDock 2>/dev/null
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" || { print_error "launchctl bootstrap failed"; return 1; }
    print_success "LaunchAgent $AGENT_LABEL"
}

function uninstall_all() {
    launchctl bootout "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null
    rm -f "$AGENT_PLIST"
    pkill -x GhosttyDock 2>/dev/null
    rm -rf "$APP"
    rm -f "$BIN_DIR/ghostty-dock" "$BIN_DIR/ghostty-dock-open" "$BIN_DIR/ghostty-dock-hook" "$BIN_DIR/ghostty-dock-move" "$BIN_DIR/ghostty-dock-restart"
    if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
        local tmp="$SETTINGS.ghostty-dock.tmp"
        jq '
            if .hooks then .hooks |= with_entries(
                .value |= (map(.hooks |= map(select((.command // "") | contains("ghostty-dock-hook") | not)))
                           | map(select(.hooks | length > 0))))
            else . end
        ' "$SETTINGS" >"$tmp" && mv -f "$tmp" "$SETTINGS"
    fi
    # Settings > "One Dock icon" hid Ghostty from the Dock; put it back.
    local cfg="$HOME/.config/ghostty/config"
    if grep -q '^# ghostty-dock: one Dock icon' "$cfg" 2>/dev/null; then
        perl -0pi -e 's/\n?# ghostty-dock: one Dock icon[^\n]*\nmacos-hidden = always\n//' "$cfg"
        pgrep -ax ghostty | xargs kill -USR2 2>/dev/null
    fi
    print_success "removed; Quick Actions now open a separate Ghostty per session again"
}

function print_step() {
    echo -e "${YELLOW}[$1/$2] $3${NC}"
}

function print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

function print_error() {
    echo -e "${RED}❌ Error: $1${NC}" >&2
}

function print_warning() {
    echo -e "${YELLOW}⚠️  Warning: $1${NC}"
}

function exit_on_missing_tools() {
    for cmd in "$@"; do
        if command -v "$cmd" &>/dev/null; then
            continue
        fi
        printf "Error: Required tool '%s' is not installed or not in PATH\n" "$cmd" >&2
        exit 1
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
