#!/usr/bin/env bash

# Tests the file viewer's page (Resources/viewer) with the app's own scheme
# handler (DockViewerScheme.swift) in an off-screen WKWebView: Markdown is
# rendered, raw HTML in a file never runs, code gets line numbers, and a
# missing file says so. macOS only; needs the patch applied to vendor/ghostty.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCHEME="$ROOT/vendor/ghostty/macos/Sources/Features/Dock/DockViewerScheme.swift"
PASSED=0
FAILED=0

function usage() {
    cat <<EOM

Tests the file viewer's page. Exits non-zero on any failure.

usage: ${SCRIPT_NAME}

EOM
    exit 1
}

function main() {
    case "${1:-}" in
    -h | --help) usage ;;
    esac
    [ -f "$SCHEME" ] || { echo "$SCHEME is missing: apply the patch first" >&2; exit 1; }
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    swiftc -O -o "$tmp/render" "$ROOT/tests/viewer/main.swift" "$SCHEME" 2>"$tmp/build.log" ||
        { cat "$tmp/build.log" >&2; exit 1; }
    samples "$tmp"

    local out
    out=$(VIEWER_PAGE="$ROOT/Resources/viewer" "$tmp/render" "$tmp/plan.md" "$tmp/tool.sh" \
        "$tmp/with space.md" "$tmp/missing.md" 2>&1)
    local plan code spaced missing
    plan=$(section "$out" plan.md)
    code=$(section "$out" tool.sh)
    spaced=$(section "$out" "with space.md")
    missing=$(section "$out" missing.md)

    expect "Markdown is rendered" "$(sed -n 2p <<<"$plan")" "md"
    has "a heading's text, without its #" "$plan" "^The plan$"
    has "a table's cells" "$plan" $'^1\tnow$'
    has "a task list's item, without its [ ]" "$plan" "^Write the viewer$"
    lacks "no page errors" "$plan" "^ERROR"
    has "raw HTML is shown as text" "$plan" '<b onclick'
    lacks "an onerror in a file never runs" "$plan" "^ERROR: ran"
    expect "code is shown as code" "$(sed -n 2p <<<"$code")" "code"
    has "with line numbers" "$code" "^3$"
    has "and its text" "$code" 'echo "hello"'
    has "a name with a space" "$spaced" "^Spaced$"
    has "a missing file says so" "$missing" "Could not read"

    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

function samples() {
    cat >"$1/plan.md" <<'MD'
# The plan

- [x] Write the viewer
- [ ] Ship it

| Step | State |
|------|-------|
| 1    | now   |

<img src=x onerror="window.webkit.messageHandlers.viewer.postMessage('ran')">
<b onclick="x()">bold?</b>

```bash
echo hi
```
MD
    printf '#!/bin/sh\n# a tool\necho "hello"\n' >"$1/tool.sh"
    printf '# Spaced\n' >"$1/with space.md"
}

# The render of one file: from its "== <path>" line to the next.
function section() {
    awk -v name="$2" '/^== / { on = (substr($0, length($0) - length(name) + 1) == name) } on' <<<"$1"
}

function expect() {
    if [ "$2" = "$3" ]; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  got:      %s\n  expected: %s\n' "$1" "$2" "$3"
    fi
}

function has() {
    if grep -qE -- "$3" <<<"$2" || grep -qF -- "$3" <<<"$2"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  no %s in:\n%s\n' "$1" "$3" "$2"
    fi
}

function lacks() {
    if grep -qE -- "$3" <<<"$2"; then
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n  found %s in:\n%s\n' "$1" "$3" "$2"
    else
        PASSED=$((PASSED + 1))
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
