#!/usr/bin/env bash

# Tests that scripts/move-to-dock.sh stops no session when Ghostty Dock would
# refuse the new tab: the opener would put it in a separate Ghostty instead.
# Stand-ins for osascript and the opener; no Ghostty, no Claude.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASSED=0
FAILED=0

function usage() {
    cat <<EOM

Tests the mover's check that Ghostty Dock takes new tabs. Exits non-zero on any failure.

usage: ${SCRIPT_NAME}

EOM
    exit 1
}

function check() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        PASSED=$((PASSED + 1))
        echo "ok   $name"
    else
        FAILED=$((FAILED + 1))
        echo "FAIL $name (wanted $want, got $got)"
    fi
}

function main() {
    case "${1:-}" in
    -h | --help) usage ;;
    esac

    local tmp
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/home/.local/bin" "$tmp/stub"
    printf '#!/bin/bash\necho "$@" >>"%s/opened"\n' "$tmp" >"$tmp/home/.local/bin/ghostty-dock-open"
    # is running -> $RUNNING; count windows -> exit $ANSWER.
    cat >"$tmp/stub/osascript" <<'STUB'
#!/bin/bash
case "$*" in
*"is running"*) echo "$RUNNING" ;;
*) exit "$ANSWER" ;;
esac
STUB
    chmod +x "$tmp/home/.local/bin/ghostty-dock-open" "$tmp/stub/osascript"

    local sid=00000000-0000-0000-0000-000000000000
    function mover() {
        HOME="$tmp/home" PATH="$tmp/stub:$PATH" RUNNING="$1" ANSWER="$2" \
            bash "$ROOT/scripts/move-to-dock.sh" "${@:3}" >/dev/null 2>&1
        echo $?
    }

    check "refused: a restart stops nothing" 3 "$(mover true 1 --now --restart "$sid")"
    check "refused: docking everything stops nothing" 3 "$(mover true 1)"
    check "refused: docking one stops nothing" 3 "$(mover true 1 --now --pid 999999)"
    grep -q "refusing new tabs" "$tmp/home/.local/state/ghostty-dock/move-to-dock.log"
    check "refused: says so in the log" 0 $?
    [ ! -e "$tmp/opened" ]
    check "refused: opens nothing" 0 $?

    : >"$tmp/home/.local/state/ghostty-dock/move-to-dock.log"
    mover true 0 --now --restart "$sid" >/dev/null
    grep -q "refusing new tabs" "$tmp/home/.local/state/ghostty-dock/move-to-dock.log"
    check "answering: goes ahead" 1 $?
    mover false 1 --now --restart "$sid" >/dev/null
    grep -q "refusing new tabs" "$tmp/home/.local/state/ghostty-dock/move-to-dock.log"
    check "not running: goes ahead, the opener starts it" 1 $?
    mover true 1 --now --undock "$sid" >/dev/null
    grep -q "refusing new tabs" "$tmp/home/.local/state/ghostty-dock/move-to-dock.log"
    check "undocking needs no tab here" 1 $?

    # A stand-in dock with a stand-in claude under it.
    local mac="$tmp/home/Applications/Ghostty Dock.app/Contents/MacOS" cwd="$tmp/work" rest
    mkdir -p "$mac" "$cwd" "$tmp/bin"
    # Compiled, as the mover finds them by their command lines.
    echo 'int main(void) { for (;;) pause(); }' | cc -include unistd.h -x c -o "$tmp/bin/claude" -
    echo 'int main(int c, char **v) { if (!fork()) execv(v[1], v + 1); wait(0); return 0; }' |
        cc -include unistd.h -include sys/wait.h -x c -o "$mac/ghostty" -
    function relaunch() {
        local flags="$1"
        rm -f "$tmp/opened"
        (cd "$cwd" && exec "$mac/ghostty" "$tmp/bin/claude" --resume "$sid" $flags) >/dev/null 2>&1 &
        local dock=$! i
        for ((i = 0; i < 20; i++)); do ps -axo command= | grep -qF "$tmp/bin/claude --resume $sid" && [ -n "$(pgrep -P "$dock")" ] && ps -o command= -p "$(pgrep -P "$dock")" | grep -q "^$tmp/bin/claude" && break; /bin/sleep 0.1; done
        HOME="$tmp/home" PATH="$tmp/stub:$PATH" RUNNING=false ANSWER=0 \
            bash "$ROOT/scripts/move-to-dock.sh" --restart "$sid" --remote-name "my repo" >/dev/null 2>&1
        pkill -f -- "claude --resume $sid" 2>/dev/null
        kill "$dock" 2>/dev/null
        wait "$dock" 2>/dev/null
        cat "$tmp/opened" 2>/dev/null
    }
    local transcript
    transcript="$tmp/home/.claude/projects/$(cd "$cwd" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')/$sid.jsonl"
    rest=$(relaunch "")
    check "no transcript: nothing to resume, left alone" "" "$rest"
    mkdir -p "$(dirname "$transcript")"
    touch -t 202001010000 "$transcript" 2>/dev/null || { : >"$transcript"; touch -t 202001010000 "$transcript"; }
    rest=$(relaunch "")
    [[ "$rest" == *"--resume $sid --remote-control 'my repo'"* ]]
    check "no flag: resumes with its repo's name" 0 $?
    touch -t 202001010000 "$transcript"
    rest=$(relaunch "--dangerously-skip-permissions --remote-control other")
    [[ "$rest" == *"--resume $sid --dangerously-skip-permissions --remote-control 'my repo'"* && "$rest" != *other* ]]
    check "has the flag: its name becomes the repo's" 0 $?

    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

main "$@"
