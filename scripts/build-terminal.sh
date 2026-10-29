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
    # Tool state (.omc) that other tools leave in the tree is not part of the fork.
    # src/Surface.zig: ⌘-click opens links while a program has the mouse.
    local only=(macos/Sources src/Surface.zig ':(exclude,glob)**/.omc/**')
    git -C "$SRC" add -N -- "${only[@]}" || exit 1
    # Against the release tag, not HEAD: the fork's own commits are part of the patch.
    git -C "$SRC" diff "$GHOSTTY_TAG" -- "${only[@]}" >"$PATCH" || exit 1
    echo "== saved $(grep -c '^diff --git' "$PATCH") file(s) to ${PATCH#"$ROOT"/}"
}

# The newest macOS SDK older than the one xcrun picks, or nothing. Zig
# 0.15.2 can't link against some newer SDKs (every libSystem symbol comes
# back undefined), and Ghostty 1.3.1 needs exactly Zig 0.15.
function older_sdk() {
    local current major path
    current=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null) || return
    major=${current%%.*}
    for path in /Library/Developer/CommandLineTools/SDKs/MacOSX*.*.sdk \
        "$(xcode-select -p 2>/dev/null)"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.*.sdk; do
        [ -d "$path" ] || continue
        local version=${path##*/MacOSX}
        version=${version%.sdk}
        [ "${version%%.*}" -lt "$major" ] && echo "$version $path"
    done | sort -t. -k1,1n -k2,2n | tail -1 | cut -d' ' -f2-
}

# Zig asks `xcrun --sdk macosx --show-sdk-path`, which ignores SDKROOT, so a
# shim earlier on PATH answers that one question with the given SDK.
function zig_build_with_sdk() {
    local sdk=$1 shim
    shift
    shim=$(mktemp -d) || return 1
    cat >"$shim/xcrun" <<EOS
#!/bin/bash
if [ "\$*" = "--sdk macosx --show-sdk-path" ]; then echo "$sdk"; exit 0; fi
exec /usr/bin/xcrun "\$@"
EOS
    chmod +x "$shim/xcrun"
    (cd "$SRC" && PATH="$shim:$PATH" "$VENDOR/zig/zig" build "$@")
    local rc=$?
    rm -rf "$shim"
    return $rc
}

function build_lib() {
    echo "== build libghostty"
    local args=(-Doptimize=ReleaseFast -Demit-xcframework=true
        -Demit-macos-app=false -Dxcframework-target=native)
    if [ -n "${GHOSTTY_DOCK_SDK:-}" ]; then
        zig_build_with_sdk "$GHOSTTY_DOCK_SDK" "${args[@]}" && return
    else
        (cd "$SRC" && "$VENDOR/zig/zig" build "${args[@]}") && return
        local sdk
        sdk=$(older_sdk)
        if [ -n "$sdk" ]; then
            echo "== retry libghostty against ${sdk##*/}"
            zig_build_with_sdk "$sdk" "${args[@]}" && return
        fi
    fi
    cat >&2 <<'EOM'
libghostty failed.
  Metal errors: xcodebuild -downloadComponent MetalToolchain
  Undefined libSystem symbols: Zig 0.15.2 can't link this macOS SDK. Install
  an older one (Command Line Tools for Xcode 26 from developer.apple.com) and
  rerun, or point at one: GHOSTTY_DOCK_SDK=/path/to/MacOSX26.sdk ./install.sh
EOM
    exit 1
}

function build_app() {
    echo "== build app"
    # Xcode bundles every file under Sources, so tool state (.omc) that a
    # hook left there fails the build: "Multiple commands produce ...json".
    find "$SRC/macos/Sources" -name .omc -type d -prune -exec rm -rf {} + || exit 1
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

# Ghostty Dock's own version, beside Ghostty's: 1.0.<commits>, the commit it
# was built from ("+" when the working tree had changes) and the clone it
# came from, which the app's Update button pulls and rebuilds.
function stamp_version() {
    local plist="$1"
    local count sha
    count=$(git -C "$ROOT" rev-list --count HEAD) || exit 1
    sha=$(git -C "$ROOT" rev-parse --short HEAD) || exit 1
    [ -n "$(git -C "$ROOT" status --porcelain -- . ':!vendor')" ] && sha="$sha+"
    local key value
    for key in GhosttyDockVersion GhosttyDockCommit GhosttyDockSource GhosttyDockBuilt; do
        case $key in
        GhosttyDockVersion) value="1.0.$count" ;;
        GhosttyDockCommit) value="$sha" ;;
        GhosttyDockSource) value="$ROOT" ;;
        GhosttyDockBuilt) value=$(date -u '+%Y-%m-%dT%H:%M:%SZ') ;;
        esac
        /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" 2>/dev/null
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" || exit 1
    done
    # A local Xcode build leaves Ghostty's placeholder 0.1 (1); its release
    # script is what normally sets these.
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${GHOSTTY_TAG#v}" \
        -c "Set :CFBundleVersion 1.0.$count" "$plist" || exit 1
    echo "== version 1.0.$count ($sha)"
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
    # Find Agents' catalogue, from Plexiform (scripts/import-agent-catalog.py).
    cp -R "$ROOT/Resources/agent-catalog" "$app/Contents/Resources/agent-catalog" || exit 1
    # The file viewer's page (⌘⇧E, DockViewer.swift).
    cp -R "$ROOT/Resources/viewer" "$app/Contents/Resources/viewer" || exit 1
    stamp_version "$plist"
    # The holder every tab runs in, so tabs outlive the app (hold/).
    clang -O2 -Wall -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
        -o "$app/Contents/MacOS/ghostty-dock-hold" "$ROOT/hold/ghostty-dock-hold.c" || exit 1

    # The browser beside the terminal (⌘⇧B): Chromium and its helpers (browser/).
    "$ROOT/browser/build.sh" || exit 1
    cp -R "$ROOT/vendor/cef/Release/Chromium Embedded Framework.framework" "$ROOT/build/browser/"*.framework \
        "$ROOT/build/browser/"*.app "$app/Contents/Frameworks/" || exit 1

    source "$ROOT/scripts/sign-id.sh"
    echo "== sign: $DOCK_SIGN_ID"
    codesign --force --deep --options runtime --sign "$DOCK_SIGN_ID" \
        --entitlements "$SRC/macos/GhosttyReleaseLocal.entitlements" "$app" || exit 1
    # Chromium's helpers compile JavaScript, which needs entitlements of their
    # own; the app is sealed again around them.
    local helper
    for helper in "$app/Contents/Frameworks/"*Helper*.app; do
        codesign --force --options runtime --sign "$DOCK_SIGN_ID" \
            --entitlements "$ROOT/browser/helper.entitlements" "$helper" || exit 1
    done
    codesign --force --options runtime --sign "$DOCK_SIGN_ID" \
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
    # A running copy keeps running the old build until restarted, but still
    # reads files from the bundle (a new tab's nibs, shell integration). An
    # rm -rf then a copy left it without them for the length of the copy, and
    # a tab opened then killed the app (and the tabs' programs with it), so the
    # new bundle is copied beside it and swapped in with renames.
    local running=false
    ps -axo command= | grep -qxF "$DEST/Contents/MacOS/ghostty" && running=true
    retire_overlay
    mkdir -p "$HOME/Applications" || exit 1
    rm -rf "$DEST.new" "$DEST.old"
    cp -R "$ROOT/build/$APP_NAME.app" "$DEST.new" || exit 1
    if [ -e "$DEST" ]; then
        mv "$DEST" "$DEST.old" || exit 1
    fi
    if ! mv "$DEST.new" "$DEST"; then
        [ -e "$DEST.old" ] && mv "$DEST.old" "$DEST"
        exit 1
    fi
    rm -rf "$DEST.old"
    echo "== installed: $DEST"
    if $running; then
        echo "== it is running the old build: scripts/restart-dock.sh restarts it and resumes its sessions"
    fi
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
