#!/usr/bin/env bash

# Builds Ghostty Dock's browser: Chromium (CEF) fetched into vendor/cef,
# DockBrowser.framework (DockBrowser.mm) and the helper apps Chromium runs
# its pages in (helper.mm), all in build/browser for build-terminal.sh to
# copy into the app's Contents/Frameworks.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CEF_NAME="cef_binary_156.0.14+g4fa4ab5+chromium-156.0.8078.48_macosarm64_minimal"
CEF_SHA1="7359a9d293dd5c480bec3f18b762731b483b0e13"
CEF="$ROOT/vendor/cef"
OUT="$ROOT/build/browser"
BUNDLE_ID="consulting.cloudscale.ghosttydock"
HELPER="Ghostty Dock Helper"
# Chromium looks for a helper of each kind next to the first.
HELPER_KINDS=("" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)")

function usage() {
    cat <<EOM

Builds the browser (Chromium Embedded Framework, DockBrowser.framework and
its helpers) into build/browser.

usage: ${SCRIPT_NAME} [options]

options:
    -h|--help      Show this help message

EOM
    exit 1
}

function fetch_cef() {
    [ -d "$CEF/Release/Chromium Embedded Framework.framework" ] && return
    echo "== fetch chromium (cef ${CEF_NAME#cef_binary_})"
    local tmp
    tmp=$(mktemp -d) || exit 1
    curl -fsSL "https://cef-builds.spotifycdn.com/${CEF_NAME//+/%2B}.tar.bz2" -o "$tmp/cef.tar.bz2" || exit 1
    echo "$CEF_SHA1  $tmp/cef.tar.bz2" | shasum -c --quiet || { echo "cef download does not match" >&2; exit 1; }
    tar -xjf "$tmp/cef.tar.bz2" -C "$tmp" || exit 1
    rm -rf "$CEF" && mv "$tmp/$CEF_NAME" "$CEF" || exit 1
    rm -rf "$tmp"
}

function build_wrapper() {
    WRAPPER="$CEF/build/libcef_dll_wrapper/libcef_dll_wrapper.a"
    [ -f "$WRAPPER" ] && return
    echo "== build cef wrapper"
    cmake -S "$CEF" -B "$CEF/build" -G "Unix Makefiles" -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release \
        >"$CEF/build.log" 2>&1 || { tail -20 "$CEF/build.log" >&2; exit 1; }
    make -C "$CEF/build" -j8 libcef_dll_wrapper >>"$CEF/build.log" 2>&1 || { tail -20 "$CEF/build.log" >&2; exit 1; }
}

# As CEF's wrapper was built, so the two agree.
FLAGS=(-arch arm64 -mmacosx-version-min=13.0 -std=c++20 -O2 -DNDEBUG -DWRAPPING_CEF_SHARED
    -fno-exceptions -fno-rtti -fobjc-arc -fobjc-call-cxx-cdtors -fvisibility=hidden -I "$CEF")

function build_framework() {
    echo "== build DockBrowser.framework"
    local fw="$OUT/DockBrowser.framework"
    rm -rf "$fw"
    mkdir -p "$fw/Versions/A/Resources" || exit 1
    clang++ "${FLAGS[@]}" -dynamiclib -install_name @rpath/DockBrowser.framework/Versions/A/DockBrowser \
        "$ROOT/browser/DockBrowser.mm" "$WRAPPER" -framework Cocoa -o "$fw/Versions/A/DockBrowser" || exit 1
    plist "$fw/Versions/A/Resources/Info.plist" DockBrowser "$BUNDLE_ID.browser" FMWK
    ln -s A "$fw/Versions/Current"
    ln -s Versions/Current/DockBrowser "$fw/DockBrowser"
    ln -s Versions/Current/Resources "$fw/Resources"
}

function build_helpers() {
    echo "== build helpers"
    local bin="$OUT/helper"
    clang++ "${FLAGS[@]}" "$ROOT/browser/helper.mm" "$WRAPPER" -framework Cocoa -o "$bin" || exit 1
    local kind id
    for kind in "${HELPER_KINDS[@]}"; do
        local name="$HELPER$kind" app="$OUT/$HELPER$kind.app"
        id=$(echo "$kind" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')
        rm -rf "$app"
        mkdir -p "$app/Contents/MacOS" || exit 1
        cp "$bin" "$app/Contents/MacOS/$name" || exit 1
        plist "$app/Contents/Info.plist" "$name" "$BUNDLE_ID.helper${id:+.$id}" APPL
    done
    rm -f "$bin"
}

function plist() {
    local file=$1 name=$2 id=$3 type=$4
    cat >"$file" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$name</string>
    <key>CFBundleIdentifier</key><string>$id</string>
    <key>CFBundleName</key><string>$name</string>
    <key>CFBundlePackageType</key><string>$type</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
EOP
}

function main() {
    while [ $# -gt 0 ]; do
        case "$1" in
        -h | --help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
        esac
        shift
    done
    mkdir -p "$OUT" || exit 1
    fetch_cef
    build_wrapper
    build_framework
    build_helpers
    echo "== browser built: ${OUT#"$ROOT"/}"
}

main "$@"
