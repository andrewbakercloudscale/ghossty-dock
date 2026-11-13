#!/bin/bash
# Re-signs an installed Ghostty Dock with this Mac's own trusted "Ghostty Dock
# Local" certificate, unless it carries a Developer ID signature already.
#
# A release built without a Developer ID is signed with its maintainer's local
# certificate, which no other Mac trusts. macOS's privacy service rejects such a
# signature and keeps switching Full Disk Access back off, so every session asks
# for every folder again. Signed here, with a certificate this Mac trusts and
# that stays the same across updates, the grants stick. Called by install.sh.
set -uo pipefail

NAME="Ghostty Dock Local"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

function usage() {
    echo "usage: $(basename "$0") [-h] <path/to/Ghostty Dock.app>"
    echo "  re-sign the app with this Mac's '$NAME' certificate (skipped for Developer ID builds)"
    exit 0
}

function sign() {
    codesign --force --options runtime --preserve-metadata=identifier,entitlements,flags \
        --sign "$NAME" "$@" || exit 1
}

function main() {
    case "${1:-}" in -h | --help | "") usage ;; esac
    local app="$1"
    [ -d "$app" ] || { echo "Error: no app at $app" >&2; exit 1; }

    if codesign -dvv "$app" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
        echo "== Developer ID signed: keeping its signature"
        return 0
    fi

    bash "$ROOT/scripts/make-sign-id.sh" || exit 1
    security find-identity -v -p codesigning | grep -q "\"$NAME\"" || {
        echo "Error: '$NAME' is not trusted for code signing; Full Disk Access would not stick" >&2
        exit 1
    }
    # This Mac's certificate already signed it: nothing to do, and re-signing
    # would only change the hash for no reason.
    local mine have
    mine=$(security find-certificate -c "$NAME" -Z 2>/dev/null | awk '/SHA-1/ {print tolower($NF)}')
    have=$(codesign -d -r- "$app" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-f]*\)".*/\1/p')
    if [ -n "$mine" ] && [ "$mine" = "$have" ]; then
        echo "== already signed with this Mac's '$NAME'"
        return 0
    fi

    echo "== signing with this Mac's '$NAME' so macOS keeps its permissions"
    # Inside out: nested code first, the app's own seal last.
    local item
    for item in "$app/Contents/Frameworks/"*.framework; do
        [ -e "$item" ] && sign --deep "$item"
    done
    for item in "$app/Contents/Frameworks/"*.app; do
        [ -e "$item" ] && sign "$item"
    done
    [ -f "$app/Contents/MacOS/ghostty-dock-hold" ] && sign "$app/Contents/MacOS/ghostty-dock-hold"
    sign "$app"
    codesign --verify --deep --strict "$app" || exit 1
}

main "$@"
