#!/usr/bin/env bash

# Checks that patches/ghostty-dock.patch still applies to Ghostty: the
# release build-terminal.sh pins, and with --latest the newest Ghostty
# release too, so a new Ghostty is known to need work before anyone updates.

DEPENDENCIES=(git)
SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PATCH="$ROOT/patches/ghostty-dock.patch"
REPO="https://github.com/ghostty-org/ghostty"

function usage() {
    cat <<EOM

Checks that the Ghostty Dock patch applies to Ghostty. Exits non-zero if it
does not apply to the pinned release.

usage: ${SCRIPT_NAME} [options]

options:
    --latest       Also try the newest Ghostty release (a warning, not a failure)
    -h|--help      Show this help message

dependencies: ${DEPENDENCIES[@]}

EOM
    exit 1
}

function main() {
    local latest=false
    while [ $# -gt 0 ]; do
        case "$1" in
        --latest) latest=true ;;
        -h | --help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
        esac
        shift
    done
    for cmd in "${DEPENDENCIES[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd is required" >&2; exit 1; }
    done

    local pinned
    pinned=$(sed -nE 's/^GHOSTTY_TAG="(.*)"/\1/p' "$ROOT/scripts/build-terminal.sh")
    [ -n "$pinned" ] || { echo "Error: no GHOSTTY_TAG in build-terminal.sh" >&2; exit 1; }

    local work
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    check "$pinned" "$work" || exit 1
    if $latest; then
        local newest
        newest=$(git ls-remote --tags --refs "$REPO" 'v*' | sed -E 's#.*refs/tags/##' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
        if [ -n "$newest" ] && [ "$newest" != "$pinned" ]; then
            check "$newest" "$work" || echo "WARN  Ghostty $newest is out: the patch needs work before moving to it"
        else
            echo "ok    $pinned is the newest Ghostty release"
        fi
    fi
}

function check() {
    local tag="$1"
    local work="$2"
    local dir="$work/$tag"
    git clone -q --depth 1 --branch "$tag" "$REPO" "$dir" 2>/dev/null \
        || { echo "FAIL  cannot fetch Ghostty $tag" >&2; return 1; }
    if git -C "$dir" apply --check "$PATCH" 2>"$work/err"; then
        echo "ok    patch applies to Ghostty $tag"
    else
        echo "FAIL  patch does not apply to Ghostty $tag:" >&2
        sed 's/^/      /' "$work/err" >&2
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
