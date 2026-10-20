#!/usr/bin/env bash

# Builds Ghostty Dock as a terminal: Ghostty's own macOS app with the session
# sidebar inside its windows (patches/ghostty-dock.patch), installed to
# ~/Applications as "Ghostty Dock.app".
#
# vendor/ is not committed. On a fresh clone this fetches Ghostty and the Zig
# it needs, then applies the patch. To change the fork, edit vendor/ghostty
# and run with --save-patch.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GHOSTTY_TAG="v1.3.1"
ZIG_VERSION="0.15.2"
APP_NAME="Ghostty Dock"
BUNDLE_ID="consulting.cloudscale.ghosttydock"
DEST="$HOME/Applications/$APP_NAME.app"
VENDOR="$ROOT/vendor"
SRC="$VENDOR/ghostty"
PATCH="$ROOT/patches/ghostty-dock.patch"
OLD_AGENT="consulting.cloudscale.ghosttydock"

function usage() {
    cat <<EOM

Builds, signs and installs ${APP_NAME}.app (patched Ghostty ${GHOSTTY_TAG}).

usage: ${SCRIPT_NAME} [options]

options:
    --save-patch   Write vendor/ghostty's changes to patches/ and stop
    --lib          Rebuild libghostty too (needed after changing Zig code)
    --no-open      Do not launch it afterwards
    -h|--help      Show this help message

EOM
    exit 1
}

function fetch_sources() {
    mkdir -p "$VENDOR" || exit 1
    if [ ! -x "$VENDOR/zig/zig" ]; then
        echo "== fetch zig $ZIG_VERSION"
        local tarball="zig-aarch64-macos-$ZIG_VERSION"
        curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/$tarball.tar.xz" | tar -xJ -C "$VENDOR" || exit 1
        mv "$VENDOR/$tarball" "$VENDOR/zig" || exit 1
    fi
    if [ ! -d "$SRC" ]; then
        echo "== fetch ghostty $GHOSTTY_TAG"
        git clone -q --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty "$SRC" || exit 1
        git -C "$SRC" checkout -q -b ghostty-dock || exit 1
        git -C "$SRC" apply "$PATCH" || { echo "patch does not apply to $GHOSTTY_TAG" >&2; exit 1; }
    fi
}

function save_patch() {
    mkdir -p "$(dirname "$PATCH")" || exit 1
    git -C "$SRC" add -N macos/Sources || exit 1
    git -C "$SRC" diff -- macos/Sources >"$PATCH" || exit 1
    echo "== saved $(grep -c '^diff --git' "$PATCH") file(s) to ${PATCH#"$ROOT"/}"
}

function build_lib() {
    echo "== build libghostty"
    (cd "$SRC" && "$VENDOR/zig/zig" build -Doptimize=ReleaseFast -Demit-xcframework=true \
        -Demit-macos-app=false -Dxcframework-target=native) || {
        echo "libghostty failed; if it mentions Metal: xcodebuild -downloadComponent MetalToolchain" >&2
        exit 1
    }
}

function build_app() {
    echo "== build app"
    # A clean environment, as Ghostty's own build.nu does. arm64 only: the
    # native libghostty has no x86_64 slice.
    env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        xcodebuild -project "$SRC/macos/Ghostty.xcodeproj" -scheme Ghostty -configuration ReleaseLocal \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=YES SYMROOT="$SRC/macos/build" build >"$VENDOR/xcodebuild.log" 2>&1 || {
        grep -E ' error:' "$VENDOR/xcodebuild.log" | head -20 >&2
        echo "build failed, full log: vendor/xcodebuild.log" >&2
        exit 1
    }
}

function package_app() {
    local app="$ROOT/build/$APP_NAME.app"
    rm -rf "$app"
    mkdir -p "$ROOT/build" || exit 1
    cp -R "$SRC/macos/build/ReleaseLocal/Ghostty.app" "$app" || exit 1

    local plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
        -c "Set :CFBundleName $APP_NAME" \
        -c "Set :CFBundleDisplayName $APP_NAME" \
        -c "Set :CFBundleIconFile AppIcon" \
        -c "Delete :CFBundleIconName" "$plist" || exit 1
    cp "$ROOT/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns" || exit 1

    source "$ROOT/scripts/sign-id.sh"
    echo "== sign: $DOCK_SIGN_ID"
    codesign --force --deep --options runtime --sign "$DOCK_SIGN_ID" \
        --entitlements "$SRC/macos/GhosttyReleaseLocal.entitlements" "$app" || exit 1
    codesign --verify --deep "$app" || exit 1
}

# The overlay sidebar app had this path, bundle id and a LaunchAgent; the
# terminal replaces all three.
function retire_overlay() {
    local agent="gui/$(id -u)/$OLD_AGENT"
    if launchctl print "$agent" >/dev/null 2>&1; then
        launchctl bootout "$agent" 2>/dev/null
        echo "== stopped the overlay sidebar's LaunchAgent"
    fi
    rm -f "$HOME/Library/LaunchAgents/$OLD_AGENT.plist"
    pkill -TERM -x GhosttyDock 2>/dev/null
}

function install_app() {
    if pgrep -f "$DEST/Contents/MacOS/ghostty" >/dev/null; then
        echo "== $APP_NAME is running; quit it (Cmd-Q) and rerun to install" >&2
        exit 1
    fi
    retire_overlay
    mkdir -p "$HOME/Applications" || exit 1
    rm -rf "$DEST"
    cp -R "$ROOT/build/$APP_NAME.app" "$DEST" || exit 1
    echo "== installed: $DEST"
}

function main() {
    local open_after=true
    local lib=false
    while [ "$1" != "" ]; do
        case $1 in
        --save-patch)
            save_patch
            exit 0
            ;;
        --lib) lib=true ;;
        --no-open) open_after=false ;;
        -h | --help) usage ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage
            ;;
        esac
        shift
    done

    fetch_sources
    if $lib || [ ! -d "$SRC/macos/GhosttyKit.xcframework" ]; then
        build_lib
    fi
    build_app
    package_app
    install_app
    if $open_after; then
        open "$DEST"
        echo "== launched"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
