# Sourced by build-app.sh. Picks the identity to sign with.
#
# macOS remembers permissions (Full Disk Access, Automation, folders) per code signature.
# An ad-hoc signature changes with every build, so every update loses them. Any stable
# certificate keeps them: DOCK_SIGN_ID, else the first local code signing identity,
# else ad-hoc as a last resort.
if [[ -z "${DOCK_SIGN_ID:-}" ]]; then
    DOCK_SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/ {print $2; exit}')"
fi
# Else the local certificate scripts/make-sign-id.sh makes. It is self-signed, so
# not "valid" to find-identity -v, but codesign signs with it and macOS keys
# permissions to it, which is all a build on this Mac needs.
if [[ -z "${DOCK_SIGN_ID:-}" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Ghostty Dock Local"'; then
    DOCK_SIGN_ID="Ghostty Dock Local"
fi
DOCK_SIGN_ID="${DOCK_SIGN_ID:--}"
