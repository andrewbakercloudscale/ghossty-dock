#!/usr/bin/env bash

# Guards against memory leaks.
#
# Static checks (always run, no app needed):
#   1. Every C function in include/ghostty.h takes the same number of
#      parameters as the Zig `export fn` behind it. A mismatch once made
#      ghostty_surface_free_text free nothing, and the app grew to 14.5 GB.
#   2. Every Swift call that gets text back from Ghostty (read_text,
#      read_selection, quicklook_word) frees it with ghostty_surface_free_text
#      within a few lines.
#
# Live check (--live): measures the running Ghostty Dock with `leaks` twice and
# fails if the leaked bytes grow by more than a limit in between.

DEPENDENCIES=(python3)
SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/vendor/ghostty"

function usage() {
    cat <<EOM

Checks Ghostty Dock for memory leaks. Exits non-zero on a leak.

usage: ${SCRIPT_NAME} [options]

options:
    --live          Also measure the running app with leaks(1)
    --pid PID       App to measure (default: the running Ghostty Dock)
    --seconds N     Time between the two measurements (default 60)
    --max-kb N      Allowed growth in leaked KB over that time (default 512)
    -h|--help       Show this help message

dependencies: ${DEPENDENCIES[@]} (and leaks, for --live)

EOM
    exit 1
}

function main() {
    local live=false pid="" seconds=60 max_kb=512
    while [ $# -gt 0 ]; do
        case "$1" in
        --live) live=true ;;
        --pid) pid="$2"; shift ;;
        --seconds) seconds="$2"; shift ;;
        --max-kb) max_kb="$2"; shift ;;
        -h | --help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
        esac
        shift
    done
    for cmd in "${DEPENDENCIES[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || { echo "Error: $cmd is required" >&2; exit 1; }
    done
    [ -f "$SRC/include/ghostty.h" ] || { echo "Error: no $SRC (run scripts/build-terminal.sh once)" >&2; exit 1; }

    local failed=0
    check_abi || failed=1
    check_frees || failed=1
    if $live; then
        check_live "$pid" "$seconds" "$max_kb" || failed=1
    fi
    [ "$failed" = 0 ] && echo "PASS  no leaks found" || echo "FAIL  see above"
    exit "$failed"
}

# Header prototypes vs Zig exports: same name, same parameter count.
function check_abi() {
    python3 - "$SRC" <<'PY'
import os, re, sys
src = sys.argv[1]

def count(params):
    params = re.sub(r"\s+", " ", params).strip()
    if params in ("", "void"):
        return 0
    depth, n = 0, 1
    for ch in params:
        if ch in "([{": depth += 1
        elif ch in ")]}": depth -= 1
        elif ch == "," and depth == 0: n += 1
    if params.rstrip().endswith(","):
        n -= 1
    return n

header = open(os.path.join(src, "include/ghostty.h")).read()
header = re.sub(r"/\*.*?\*/|//[^\n]*", "", header, flags=re.S)
c = {m.group(1): count(m.group(2))
     for m in re.finditer(r"\b(ghostty_\w+)\s*\(([^;{]*?)\)\s*;", header)
     if not re.search(r"typedef[^;]*$", header[:m.start()].rsplit(";", 1)[-1])}

zig = {}
for dirpath, _, files in os.walk(os.path.join(src, "src")):
    for f in files:
        if not f.endswith(".zig"):
            continue
        text = open(os.path.join(dirpath, f)).read()
        for m in re.finditer(r"export fn (ghostty_\w+)\s*\(", text):
            i, depth = m.end(), 1
            while depth:
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                i += 1
            zig[m.group(1)] = (count(text[m.end():i - 1]), os.path.join(dirpath, f))

bad = 0
checked = 0
for name, n in sorted(c.items()):
    if name not in zig:
        continue
    checked += 1
    zn, path = zig[name]
    if zn != n:
        bad += 1
        print(f"FAIL  {name}: header has {n} parameter(s), "
              f"{os.path.relpath(path, src)} has {zn}")
if checked < 50:
    print(f"FAIL  matched only {checked} header functions to Zig exports: parser is broken")
    sys.exit(1)
if bad:
    sys.exit(1)
print(f"ok    {checked} C functions match their Zig exports")
PY
}

# Text Ghostty hands to Swift must be freed close to where it is read.
function check_frees() {
    python3 - "$SRC/macos/Sources" <<'PY'
import os, re, sys
root = sys.argv[1]
reads = re.compile(r"ghostty_surface_(read_text|read_selection|quicklook_word)\s*\(")
window = 10
bad = calls = 0
for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.endswith(".swift"):
            continue
        path = os.path.join(dirpath, f)
        lines = open(path).read().split("\n")
        for i, line in enumerate(lines):
            if not reads.search(line) or line.lstrip().startswith("//"):
                continue
            calls += 1
            if not any("ghostty_surface_free_text" in l for l in lines[i:i + window]):
                bad += 1
                print(f"FAIL  {os.path.relpath(path, root)}:{i + 1} reads text "
                      f"without ghostty_surface_free_text within {window} lines")
if calls == 0:
    print("FAIL  found no text reads: the check is looking in the wrong place")
    sys.exit(1)
if bad:
    sys.exit(1)
print(f"ok    {calls} text reads are all freed")
PY
}

function leaked_bytes() {
    leaks "$1" --nostacks 2>/dev/null \
        | sed -nE 's/.*: [0-9]+ leaks? for ([0-9]+) total leaked bytes.*/\1/p' | head -1
}

function check_live() {
    local pid="$1" seconds="$2" max_kb="$3"
    command -v leaks >/dev/null 2>&1 || { echo "FAIL  leaks(1) not found (install Xcode tools)"; return 1; }
    if [ -z "$pid" ]; then
        pid=$(pgrep -f 'Ghostty Dock.app/Contents/MacOS/ghostty$' | head -1)
    fi
    [ -n "$pid" ] || { echo "FAIL  Ghostty Dock is not running (or pass --pid)"; return 1; }
    local before after grew
    before=$(leaked_bytes "$pid")
    [ -n "$before" ] || { echo "FAIL  leaks could not read pid $pid"; return 1; }
    echo "..    pid $pid: $((before / 1024)) KB leaked; measuring again in ${seconds}s"
    sleep "$seconds"
    after=$(leaked_bytes "$pid")
    [ -n "$after" ] || { echo "FAIL  leaks could not read pid $pid"; return 1; }
    grew=$(((after - before) / 1024))
    if [ "$grew" -gt "$max_kb" ]; then
        echo "FAIL  leaked $grew KB more in ${seconds}s (limit $max_kb KB): $((after / 1024)) KB total"
        return 1
    fi
    echo "ok    leaked $grew KB more in ${seconds}s (limit $max_kb KB)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
