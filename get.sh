#! /usr/bin/env bash

# Installs Ghostty Dock from its latest GitHub release, with nothing to build.
# Run it with this one line rather than pasting the file's text into a shell:
#
#     curl -fsSL https://raw.githubusercontent.com/andrewbakercloudscale/ghossty-dock/main/get.sh | bash
#
# The zip is fetched over HTTPS only and checked against the SHA-256 the
# release publishes beside it. The app's signature must be intact and made
# by one of the certificates in SIGNERS, before anything is unpacked.
#
# Unpacks the release into ~/.local/share/ghostty-dock, runs its install.sh
# and opens the app. Run it again to update. Downloaded with curl, the app
# carries no quarantine flag, so macOS opens it without asking.

DEPENDENCIES=(curl ditto jq shasum codesign)
SCRIPT_NAME=$(basename "$0")
REPO="andrewbakercloudscale/ghossty-dock"
ZIP_URL="${GHOSTTY_DOCK_ZIP_URL:-https://github.com/$REPO/releases/latest/download/Ghostty-Dock.zip}"
DEST="$HOME/.local/share/ghostty-dock"
# SHA-1 of the certificates releases are signed with. They live here, in the
# repo, not in the release: a swapped zip would also need a change to this
# file. release.sh refuses to publish an app signed by anything else. Add a
# new certificate here (and release once) before switching to it.
SIGNERS=(
    cd657e31a5b785053512ed8d8303656588a89dc4 # Ghostty Dock Local (release Mac)
)
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

# The release publishes Ghostty-Dock.zip.sha256 beside the zip. A zip that
# does not match it is not installed. A zip from GHOSTTY_DOCK_ZIP_URL with
# no checksum beside it is installed with a warning.
function verify_checksum() {
    local tmp="$1" want got
    if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp/sum" "$ZIP_URL.sha256"; then
        [ -n "${GHOSTTY_DOCK_ZIP_URL:-}" ] || die "could not download the release's checksum ($ZIP_URL.sha256)"
        printf '\033[0;33mWarning:\033[0m no checksum beside %s; not verified\n' "$ZIP_URL" >&2
        return 0
    fi
    want=$(awk '{print $1; exit}' "$tmp/sum")
    got=$(shasum -a 256 "$tmp/Ghostty-Dock.zip" | awk '{print $1}')
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "the release's checksum file is not a SHA-256"
    [ "$want" = "$got" ] || die "the download does not match the release's checksum. Nothing was installed."
    say "Checksum matches ($got)"
}

# The app must be signed by a certificate in SIGNERS. A zip from
# GHOSTTY_DOCK_ZIP_URL signed by anything else is installed with a warning.
function verify_signer() {
    local app="$1" req="" sha
    for sha in "${SIGNERS[@]}"; do
        req+="${req:+ or }certificate leaf = H\"$sha\""
    done
    codesign --verify --deep --strict -R "=$req" "$app" 2>/dev/null && return 0
    if [ -n "${GHOSTTY_DOCK_ZIP_URL:-}" ]; then
        printf '\033[0;33mWarning:\033[0m %s is not signed by a known Ghostty Dock certificate\n' "$ZIP_URL" >&2
        return 0
    fi
    die "the app is not signed by a known Ghostty Dock certificate. Nothing was installed. If you updated from inside the app, get the newest installer: curl -fsSL https://raw.githubusercontent.com/$REPO/main/get.sh | bash"
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
    curl -fL --proto '=https' --tlsv1.2 --progress-bar -o "$tmp/Ghostty-Dock.zip" "$ZIP_URL" ||
        die "could not download $ZIP_URL"
    verify_checksum "$tmp"
    ditto -x -k "$tmp/Ghostty-Dock.zip" "$tmp/unzipped" || die "the download is not a valid zip"
    [ -f "$tmp/unzipped/Ghostty Dock/install.sh" ] && [ -d "$tmp/unzipped/Ghostty Dock/Ghostty Dock.app" ] ||
        die "the download does not hold Ghostty Dock"
    codesign --verify --deep --strict "$tmp/unzipped/Ghostty Dock/Ghostty Dock.app" 2>/dev/null ||
        die "the app's signature is broken: it was changed after it was built. Nothing was installed."
    verify_signer "$tmp/unzipped/Ghostty Dock/Ghostty Dock.app"

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
