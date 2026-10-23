#!/usr/bin/env bash

# Installs Ghostty Dock from its latest GitHub release, with nothing to build:
#
#     curl -fsSL https://raw.githubusercontent.com/andrewbakercloudscale/ghossty-dock/main/get.sh | bash
#
# Unpacks the release into ~/.local/share/ghostty-dock, runs its install.sh
# and opens the app. Run it again to update. Downloaded with curl, the app
# carries no quarantine flag, so macOS opens it without asking.

DEPENDENCIES=(curl ditto jq)
SCRIPT_NAME=$(basename "$0")
REPO="andrewbakercloudscale/ghossty-dock"
ZIP_URL="${GHOSTTY_DOCK_ZIP_URL:-https://github.com/$REPO/releases/latest/download/Ghostty-Dock.zip}"
DEST="$HOME/.local/share/ghostty-dock"
APP="$HOME/Applications/Ghostty Dock.app"

function usage() {
    cat <<EOM

Installs or updates Ghostty Dock from its latest GitHub release.

usage: ${SCRIPT_NAME} [options]

options:
    --no-open      Do not open the app afterwards
    -h|--help      Show this help message

environment:
    GHOSTTY_DOCK_ZIP_URL   a different release zip to install

dependencies: ${DEPENDENCIES[@]}

EOM
    exit 1
}

function say() {
    printf '\033[1;34m==>\033[0m %s\n' "$*"
}

function die() {
    printf '\033[0;31mError:\033[0m %s\n' "$*" >&2
    exit 1
}

function main() {
    local open=true
    while [ $# -gt 0 ]; do
        case "$1" in
        --no-open) open=false ;;
        -h | --help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
        esac
        shift
    done
    [ "$(uname -s)" = Darwin ] || die "Ghostty Dock runs on macOS only."
    [ "$(uname -m)" = arm64 ] || die "Ghostty Dock needs a Mac with Apple silicon (M1 or newer)."
    if ! command -v jq >/dev/null 2>&1; then
        die "jq is needed (macOS 15 and later include it). On older macOS: brew install jq, then run this again."
    fi
    local cmd
    for cmd in "${DEPENDENCIES[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
    done

    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ghostty-dock.XXXXXX") || die "could not make a temporary folder"
    trap 'rm -rf "$tmp"' EXIT

    say "Downloading Ghostty Dock"
    curl -fL --progress-bar -o "$tmp/Ghostty-Dock.zip" "$ZIP_URL" || die "could not download $ZIP_URL"
    ditto -x -k "$tmp/Ghostty-Dock.zip" "$tmp/unzipped" || die "the download is not a valid zip"
    [ -f "$tmp/unzipped/Ghostty Dock/install.sh" ] && [ -d "$tmp/unzipped/Ghostty Dock/Ghostty Dock.app" ] ||
        die "the download does not hold Ghostty Dock"

    say "Unpacking into $DEST"
    mkdir -p "$(dirname "$DEST")" || die "could not create $(dirname "$DEST")"
    rm -rf "$DEST.new" && mv "$tmp/unzipped/Ghostty Dock" "$DEST.new" || die "could not unpack"
    rm -rf "$DEST" && mv "$DEST.new" "$DEST" || die "could not replace $DEST"

    say "Installing"
    bash "$DEST/install.sh" || die "install.sh failed (see above)"

    if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
        echo
        echo "Ghostty Dock shows Claude Code sessions. Claude Code is not installed yet:"
        echo "  curl -fsSL https://claude.ai/install.sh | bash"
    fi
    if $open; then
        say "Opening Ghostty Dock"
        open "$APP" || die "could not open $APP"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [ -z "${BASH_SOURCE[0]:-}" ]; then
    main "$@"
fi
