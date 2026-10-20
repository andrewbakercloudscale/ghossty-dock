#!/usr/bin/env bash

# Builds Ghostty Dock.app and installs it to ~/Applications.
#
# Signed with the first local code signing identity when there is one, so
# macOS keeps the Accessibility and Automation permissions across rebuilds.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="Ghostty Dock"
DEST="$HOME/Applications/$APP_NAME.app"

function usage() {
    cat <<EOM

Tests, builds, signs and installs ${APP_NAME}.app to ~/Applications.

usage: ${SCRIPT_NAME} [options]

options:
    --no-open      Do not launch it afterwards (relaunched if it was running)
    -h|--help      Show this help message

EOM
    exit 1
}

function main() {
    local open_after=true
    while [ "$1" != "" ]; do
        case $1 in
        --no-open) open_after=false ;;
        -h | --help) usage ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage
            ;;
        esac
        shift
    done
    cd "$ROOT" || exit 1

    echo "== tests"
    bash tests/hook-test.sh >/dev/null || { echo "hook tests failed, not building" >&2; bash tests/hook-test.sh | grep FAIL; exit 1; }
    swift test >/dev/null 2>&1 || { echo "swift tests failed, not building" >&2; swift test 2>&1 | grep -E 'error|failed' | head; exit 1; }

    echo "== build"
    swift build -c release || exit 1
    local bin
    bin="$(swift build -c release --show-bin-path)/GhosttyDock"

    local app="build/$APP_NAME.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" || exit 1
    cp "$bin" "$app/Contents/MacOS/GhosttyDock" || exit 1
    cp Resources/Info.plist "$app/Contents/Info.plist" || exit 1
    cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns" || exit 1

    source "$ROOT/scripts/sign-id.sh"
    echo "== sign: $DOCK_SIGN_ID"
    codesign --force --sign "$DOCK_SIGN_ID" "$app" || exit 1
    codesign --verify "$app" || exit 1

    # Under the LaunchAgent, launchd restarts a killed copy by itself; a
    # second `open` then made two copies, two Dock icons and two sidebars.
    local agent="gui/$(id -u)/consulting.cloudscale.ghosttydock"
    local managed=false
    launchctl print "$agent" >/dev/null 2>&1 && managed=true
    if $managed; then
        launchctl bootout "$agent" 2>/dev/null
    fi
    local was_running=false
    if pgrep -x GhosttyDock >/dev/null; then
        was_running=true
        pkill -TERM -x GhosttyDock
        for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x GhosttyDock >/dev/null || break; sleep 0.3; done
        pkill -KILL -x GhosttyDock 2>/dev/null
    fi
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$app" "$DEST" || exit 1
    echo "== installed: $DEST"

    if $managed; then
        launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/consulting.cloudscale.ghosttydock.plist" || exit 1
        echo "== relaunched by its LaunchAgent"
    elif $open_after || $was_running; then
        open "$DEST"
        echo "== launched"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
