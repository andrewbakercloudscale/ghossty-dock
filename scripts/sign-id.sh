# Sourced by build-terminal.sh. Picks the identity to sign with.
#
# macOS keeps permissions (Full Disk Access, Automation, folders) per code
# signature. Changing it makes macOS treat Ghostty Dock as a new app: every
# session asks again, folder by folder. So the identity never changes:
# DOCK_SIGN_ID, else the local "Ghostty Dock Local" certificate
# (scripts/make-sign-id.sh), else the first valid identity, else ad-hoc. And a
# build that would sign differently from the installed app stops, unless
# DOCK_SIGN_CHANGE=1 says the change is meant (grant Full Disk Access to the
# new build before restarting into it).
if [[ -z "${DOCK_SIGN_ID:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Ghostty Dock Local"'; then
    DOCK_SIGN_ID="Ghostty Dock Local"
fi
if [[ -z "${DOCK_SIGN_ID:-}" ]]; then
    DOCK_SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/ {print $2; exit}')"
fi
DOCK_SIGN_ID="${DOCK_SIGN_ID:--}"

# A certificate macOS does not trust still signs, but the privacy service
# rejects the signature and keeps switching Full Disk Access back off.
if [[ "$DOCK_SIGN_ID" != "-" ]] && ! security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$DOCK_SIGN_ID\""; then
    echo "ERROR: '$DOCK_SIGN_ID' is not trusted for code signing on this Mac." >&2
    echo "  macOS would keep turning Full Disk Access off. Run scripts/make-sign-id.sh to trust it." >&2
    exit 1
fi

# What the installed app is signed with: its certificate's name, or "-" ad-hoc.
function dock_installed_sign_id() {
    local app="$HOME/Applications/Ghostty Dock.app" info
    [[ -d "$app" ]] || return 0
    info=$(codesign -dvv "$app" 2>&1) || return 0
    if grep -q '^Authority=' <<<"$info"; then
        grep -m1 '^Authority=' <<<"$info" | cut -d= -f2-
    else
        echo "-"
    fi
}

DOCK_INSTALLED_SIGN_ID="$(dock_installed_sign_id)"
if [[ -n "$DOCK_INSTALLED_SIGN_ID" && "$DOCK_INSTALLED_SIGN_ID" != "$DOCK_SIGN_ID" && "${DOCK_SIGN_CHANGE:-0}" != "1" ]]; then
    echo "ERROR: this build would sign as '$DOCK_SIGN_ID', the installed app is '$DOCK_INSTALLED_SIGN_ID'." >&2
    echo "  macOS would forget Ghostty Dock's permissions and ask folder by folder again." >&2
    echo "  Meant? DOCK_SIGN_CHANGE=1, then turn on Full Disk Access for the new build before restarting." >&2
    exit 1
fi
