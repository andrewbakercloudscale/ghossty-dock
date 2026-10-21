#!/usr/bin/env bash

# Packages the installed Ghostty Dock.app for people who will not build it:
# a zip with the app, the hook and scripts, and install.sh. Signs with a
# Developer ID and notarizes when those are set up, so it opens without a
# Gatekeeper warning; otherwise it is signed only for this Mac and says so.
# Publishing to GitHub Releases is a separate, explicit step (--publish).

DEPENDENCIES=(ditto codesign git)
SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$HOME/Applications/Ghostty Dock.app"
OUT="$ROOT/build/release"

function usage() {
    cat <<EOM

Packages Ghostty Dock into build/release/Ghostty-Dock-<version>.zip.

usage: ${SCRIPT_NAME} [options]

options:
    --publish      Also create a GitHub release with the zip (needs gh)
    -h|--help      Show this help message

environment:
    DEVELOPER_ID       "Developer ID Application: Name (TEAMID)" to sign with
    NOTARY_PROFILE     a notarytool keychain profile (xcrun notarytool store-credentials)

dependencies: ${DEPENDENCIES[@]}

EOM
    exit 1
}

function main() {
    local publish=false
    while [ $# -gt 0 ]; do
        case "$1" in
        --publish) publish=true ;;
        -h | --help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
        esac
        shift
    done
    for cmd in "${DEPENDENCIES[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd is required" >&2; exit 1; }
    done
    [ -d "$APP" ] || { echo "Error: $APP missing; run scripts/build-terminal.sh first" >&2; exit 1; }

    local version commit
    version=$(/usr/libexec/PlistBuddy -c "Print :GhosttyDockVersion" "$APP/Contents/Info.plist" 2>/dev/null)
    commit=$(/usr/libexec/PlistBuddy -c "Print :GhosttyDockCommit" "$APP/Contents/Info.plist" 2>/dev/null)
    [ -n "$version" ] || { echo "Error: the app has no version; rebuild it" >&2; exit 1; }
    if [[ "$commit" == *+ ]]; then
        echo "Error: the app was built from uncommitted changes ($commit); commit and rebuild" >&2
        exit 1
    fi

    local stage="$OUT/stage"
    rm -rf "$stage" && mkdir -p "$stage/Ghostty Dock" || exit 1
    local dir="$stage/Ghostty Dock"
    ditto "$APP" "$dir/Ghostty Dock.app" || exit 1
    cp -R "$ROOT/bin" "$ROOT/scripts" "$dir/" && cp "$ROOT/install.sh" "$ROOT/README.md" "$dir/" || exit 1

    local signed="this Mac only"
    if [ -n "${DEVELOPER_ID:-}" ]; then
        echo "== sign: $DEVELOPER_ID"
        codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$dir/Ghostty Dock.app" || exit 1
        signed="Developer ID"
    fi

    local zip="$OUT/Ghostty-Dock-$version.zip"
    rm -f "$zip"
    (cd "$stage" && ditto -c -k --keepParent "Ghostty Dock" "$zip") || exit 1

    if [ -n "${DEVELOPER_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "== notarize"
        xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait || exit 1
        xcrun stapler staple "$dir/Ghostty Dock.app" || exit 1
        rm -f "$zip" && (cd "$stage" && ditto -c -k --keepParent "Ghostty Dock" "$zip") || exit 1
        signed="Developer ID, notarized"
    fi
    rm -rf "$stage"
    echo "== $zip ($signed)"
    [ "$signed" = "this Mac only" ] &&
        echo "   Not Developer ID signed: macOS will refuse to open it on other Macs until they allow it in Privacy & Security."

    if $publish; then
        command -v gh >/dev/null || { echo "Error: gh is required to publish" >&2; exit 1; }
        gh release create "v$version" "$zip" --target "$(git -C "$ROOT" rev-parse HEAD)" \
            --title "Ghostty Dock $version" --notes "Built from ${commit}. Signed: ${signed}. Unzip, then run \`bash \"Ghostty Dock/install.sh\"\`." || exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
