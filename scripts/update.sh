#!/usr/bin/env bash

# Updates Ghostty Dock from GitHub: pulls this clone, brings vendor/ghostty
# up to the new patch, rebuilds and installs the app and its scripts, then
# restarts it once its sessions are quiet (they are resumed as tabs).
#
# The app's Update button runs it: --check to see what is new, --install
# --detach to install.
#
# Installed from a release (get.sh) there is no clone: it checks GitHub's
# latest release instead, and installs it with get.sh.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE_DIR="$HOME/.local/state/ghostty-dock"
LOG="$STATE_DIR/update.log"
LOCK="$STATE_DIR/update.pid"
SRC="$ROOT/vendor/ghostty"
PATCH="patches/ghostty-dock.patch"
APP="$HOME/Applications/Ghostty Dock.app"
BRANCH="main"
REPO="andrewbakercloudscale/ghossty-dock"
RELEASE=false
[ -d "$ROOT/.git" ] || RELEASE=true

function usage() {
    cat <<EOM

Updates Ghostty Dock to the latest version on GitHub.

usage: ${SCRIPT_NAME} [options]

options:
    --check        Fetch and print what is new, as "key<TAB>value" lines:
                   installed, latest, behind, ahead, then a "commit" line
                   (sha, date, subject) per change not installed yet
    --install      Pull, rebuild, install, then restart once sessions are quiet
    --now          With --install: restart at once (interrupts busy sessions)
    --detach       Run in the background and return at once
    -h|--help      Show this help message

EOM
    exit 1
}

function log() {
    echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"
}

function fail() {
    log "failed: $*"
    rm -f "$LOCK"
    exit 1
}

function check_dependencies() {
    local dep deps=(git xcodebuild /usr/libexec/PlistBuddy)
    $RELEASE && deps=(curl jq /usr/libexec/PlistBuddy)
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || { echo "Error: $dep is required" >&2; exit 1; }
    done
}

function installed_commit() {
    /usr/libexec/PlistBuddy -c "Print :GhosttyDockCommit" "$APP/Contents/Info.plist" 2>/dev/null
}

function fetch() {
    git -C "$ROOT" fetch -q origin "$BRANCH" 2>&1
}

function check() {
    local err
    err=$(fetch) || { printf 'error\t%s\n' "${err:-git fetch failed}"; exit 1; }
    local behind ahead installed
    behind=$(git -C "$ROOT" rev-list --count "HEAD..origin/$BRANCH")
    ahead=$(git -C "$ROOT" rev-list --count "origin/$BRANCH..HEAD")
    installed=$(installed_commit)
    printf 'installed\t%s\n' "${installed:-unknown}"
    printf 'latest\t1.0.%s\t%s\n' "$(git -C "$ROOT" rev-list --count "origin/$BRANCH")" \
        "$(git -C "$ROOT" rev-parse --short "origin/$BRANCH")"
    printf 'behind\t%s\n' "$behind"
    printf 'ahead\t%s\n' "$ahead"
    # Pulled but not built yet counts as new too.
    local since="${installed%+}"
    git -C "$ROOT" cat-file -e "$since^{commit}" 2>/dev/null || since=HEAD
    git -C "$ROOT" log -20 --format='commit%x09%h%x09%cI%x09%s' "$since..origin/$BRANCH"
}

function installed_version() {
    /usr/libexec/PlistBuddy -c "Print :GhosttyDockVersion" "$APP/Contents/Info.plist" 2>/dev/null
}

# True when version $1 (1.0.97) is newer than $2.
function newer() {
    local a b i
    IFS=. read -ra a <<<"$1"
    IFS=. read -ra b <<<"$2"
    for i in 0 1 2; do
        [ "${a[i]:-0}" -gt "${b[i]:-0}" ] 2>/dev/null && return 0
        [ "${a[i]:-0}" -lt "${b[i]:-0}" ] 2>/dev/null && return 1
    done
    return 1
}

# The same lines as check(), from GitHub's latest release.
function check_release() {
    local json
    json=$(curl -fsSL --max-time 30 "https://api.github.com/repos/$REPO/releases/latest") ||
        { printf 'error\tcould not reach GitHub\n'; exit 1; }
    local tag date sha installed
    tag=$(jq -r '.tag_name // empty' <<<"$json")
    date=$(jq -r '.published_at // empty' <<<"$json")
    sha=$(jq -r '.target_commitish // empty' <<<"$json")
    [ -n "$tag" ] || { printf 'error\tGitHub has no release yet\n'; exit 1; }
    installed=$(installed_version)
    printf 'installed\t%s\n' "$(installed_commit)"
    printf 'latest\t%s\t%s\n' "${tag#v}" "${sha:0:7}"
    printf 'ahead\t0\n'
    if newer "${tag#v}" "${installed:-0}"; then
        printf 'behind\t1\n'
        printf 'commit\t%s\t%s\tGhostty Dock %s\n' "$tag" "$date" "${tag#v}"
    else
        printf 'behind\t0\n'
    fi
}

# vendor/ghostty is Ghostty plus the old patch's commits. When the pull
# brought a new patch, start it again from the release tag with the new one,
# but only if it holds nothing the old patch did not (unsaved fork work).
function sync_vendor() {
    local old="$1"
    [ -d "$SRC" ] || return 0
    git -C "$ROOT" diff --quiet "$old" HEAD -- "$PATCH" scripts/build-terminal.sh && return 0
    local tag old_tag
    tag=$(sed -n 's/^GHOSTTY_TAG="\(.*\)"$/\1/p' "$ROOT/scripts/build-terminal.sh")
    old_tag=$(git -C "$ROOT" show "$old:scripts/build-terminal.sh" | sed -n 's/^GHOSTTY_TAG="\(.*\)"$/\1/p')
    [ -n "$tag" ] && [ -n "$old_tag" ] || fail "no GHOSTTY_TAG in scripts/build-terminal.sh"
    [ -z "$(git -C "$SRC" status --porcelain -- macos/Sources)" ] ||
        fail "vendor/ghostty has unsaved changes; run scripts/build-terminal.sh --save-patch first"
    git -C "$SRC" add -N macos/Sources
    git -C "$SRC" diff "$old_tag" -- macos/Sources |
        cmp -s - <(git -C "$ROOT" show "$old:$PATCH") ||
        fail "vendor/ghostty differs from the patch it was built from; run scripts/build-terminal.sh --save-patch first"
    if ! git -C "$SRC" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        # A new Ghostty release: fetch it from scratch on the next build.
        log "Ghostty $tag is new; vendor/ghostty is refetched"
        mv "$SRC" "$SRC.old-$(date +%s)" || fail "could not move vendor/ghostty aside"
        return 0
    fi
    git -C "$SRC" checkout -q -B ghostty-dock "$tag" || fail "could not reset vendor/ghostty to $tag"
    git -C "$SRC" apply "$ROOT/$PATCH" || fail "the new patch does not apply to $tag"
    git -C "$SRC" add macos/Sources && git -C "$SRC" commit -qm "ghostty-dock $(git -C "$ROOT" rev-parse --short HEAD)" ||
        fail "could not commit the new patch in vendor/ghostty"
    log "vendor/ghostty now has the new patch"
}

function install() {
    local now="$1"
    if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
        log "an update is already running"
        exit 0
    fi
    echo $$ >"$LOCK"
    # Killed or interrupted: say so, so the app's Update button does not wait forever.
    trap 'fail "interrupted"' INT TERM HUP
    log "updating"
    if $RELEASE; then
        log "downloading the latest release"
        bash "$ROOT/get.sh" --no-open >>"$LOG" 2>&1 || fail "the download or install failed; see $LOG"
        restart "$now"
        return
    fi
    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no -- . ':!vendor')" ] ||
        fail "this clone has uncommitted changes ($ROOT)"
    fetch >/dev/null || fail "could not reach GitHub"
    local old
    old=$(git -C "$ROOT" rev-parse HEAD)
    git -C "$ROOT" merge -q --ff-only "origin/$BRANCH" 2>>"$LOG" ||
        fail "this clone has commits GitHub does not; push them first"
    log "at $(git -C "$ROOT" rev-parse --short HEAD) (was ${old:0:7})"
    sync_vendor "$old"
    log "building (a minute or two)"
    "$ROOT/scripts/build-terminal.sh" --no-open >>"$LOG" 2>&1 || fail "the build failed; see $LOG"
    "$ROOT/install.sh" --skip-app >>"$LOG" 2>&1 || fail "installing the scripts failed; see $LOG"
    restart "$now"
}

function restart() {
    local now="$1"
    log "installed; restarting Ghostty Dock$($now || echo ' once sessions are quiet')"
    local args=()
    $now && args+=(--now)
    "$ROOT/scripts/restart-dock.sh" "${args[@]}" >>"$LOG" 2>&1 || fail "could not restart; see $LOG"
    trap - INT TERM HUP
    rm -f "$LOCK"
}

function main() {
    # Not the ids of the tab or session this runs in (see restart-dock.sh).
    unset CLAUDECODE CLAUDE_PID GHOSTTY_DOCK_SURFACE DOCK_TAB_ID $(compgen -e | grep "^CLAUDE_CODE_")
    # The app starts this with launchd's bare PATH.
    export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    local mode=""
    local now=false
    local detach=false
    local args=("$@")
    while [ "$1" != "" ]; do
        case $1 in
        --check) mode=check ;;
        --install) mode=install ;;
        --now) now=true ;;
        --detach) detach=true ;;
        -h | --help) usage ;;
        *)
            echo "Error: Unknown option '$1'" >&2
            usage
            ;;
        esac
        shift
    done
    [ -n "$mode" ] || usage
    check_dependencies
    mkdir -p "$STATE_DIR" || exit 1

    if $detach; then
        local rest=()
        local a
        for a in "${args[@]}"; do [ "$a" != --detach ] && rest+=("$a"); done
        nohup perl -MPOSIX=setsid -e 'setsid; exec @ARGV' \
            /bin/bash "$ROOT/scripts/$SCRIPT_NAME" "${rest[@]}" >/dev/null 2>&1 </dev/null &
        echo "updating in the background; log: $LOG"
        exit 0
    fi
    case $mode in
    check) if $RELEASE; then check_release; else check; fi ;;
    install) install "$now" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
    exit 0
fi
