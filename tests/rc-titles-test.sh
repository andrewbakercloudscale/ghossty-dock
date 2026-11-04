#!/usr/bin/env bash

# Tests bin/ghostty-dock-rc-titles against a stand-in for the sessions API:
# that a live session's wrong title is set to its repo, a right one and a
# dead session's are left alone, and a worktree takes its main repo's name.
# No network, no Keychain.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASSED=0
FAILED=0

function usage() {
    cat <<EOM

Tests the Remote Control titler. Exits non-zero on any failure.

usage: ${SCRIPT_NAME}

EOM
    exit 1
}

function check() {
    local name=$1 got=$2 want=$3
    if [ "$got" = "$want" ]; then
        echo "PASS $name"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL $name: got '$got', want '$want'"
        FAILED=$((FAILED + 1))
    fi
}

function main() {
    case "${1:-}" in
    -h | --help) usage ;;
    esac

    local tmp
    tmp=$(mktemp -d)
    trap 'kill $server 2>/dev/null; rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/home/.claude/sessions" "$tmp/repos"
    git init -q "$tmp/repos/alpha"
    git -C "$tmp/repos/alpha" commit -q --allow-empty -m init
    git -C "$tmp/repos/alpha" worktree add -q "$tmp/repos/alpha-wt" 2>/dev/null
    mkdir -p "$tmp/repos/plain"

    # Titles on the stand-in server, and what it was sent.
    cat >"$tmp/titles.json" <<EOF
{"cse_A": "Some AI title", "cse_B": "plain", "cse_C": "Old", "cse_D": "Dead one"}
EOF
    cat >"$tmp/server.py" <<'EOF'
import json, sys, http.server
path = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _id(self): return self.path.rsplit("/", 1)[1]
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer tok":
            self.send_response(401); self.end_headers(); return
        t = json.load(open(path))
        body = json.dumps({"response_shape": {"id": self._id(), "title": t.get(self._id())}}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def do_PUT(self):
        t = json.load(open(path))
        t[self._id()] = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["title"]
        json.dump(t, open(path, "w"))
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
EOF
    python3 "$tmp/server.py" "$tmp/titles.json" >"$tmp/port" &
    server=$!
    local i
    for i in $(seq 50); do [ -s "$tmp/port" ] && break; /bin/sleep 0.1; done

    local live=$$
    printf '{"pid":%s,"cwd":"%s","bridgeSessionId":"session_A"}' $live "$tmp/repos/alpha" >"$tmp/home/.claude/sessions/1.json"
    printf '{"pid":%s,"cwd":"%s","bridgeSessionId":"session_B"}' $live "$tmp/repos/plain" >"$tmp/home/.claude/sessions/2.json"
    printf '{"pid":%s,"cwd":"%s","bridgeSessionId":"session_C"}' $live "$tmp/repos/alpha-wt" >"$tmp/home/.claude/sessions/3.json"
    printf '{"pid":999999,"cwd":"%s","bridgeSessionId":"session_D"}' "$tmp/repos/plain" >"$tmp/home/.claude/sessions/4.json"
    printf '{"pid":%s,"cwd":"%s"}' $live "$tmp/repos/plain" >"$tmp/home/.claude/sessions/5.json"

    local out
    out=$(HOME="$tmp/home" GHOSTTY_DOCK_API="http://127.0.0.1:$(cat "$tmp/port")" GHOSTTY_DOCK_TOKEN=tok \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" 2>&1)
    local t="$tmp/titles.json"
    check "wrong title becomes the repo's" "$(jq -r .cse_A "$t")" alpha
    check "right title is left alone" "$(echo "$out" | grep -c cse_B)" 0
    check "a worktree takes its main repo's name" "$(jq -r .cse_C "$t")" alpha
    check "a dead session is left alone" "$(jq -r .cse_D "$t")" "Dead one"
    check "each change is logged" "$(grep -c -- '->' "$tmp/home/.local/state/ghostty-dock/rc-titles.log")" 2

    out=$(HOME="$tmp/home" GHOSTTY_DOCK_API="http://127.0.0.1:$(cat "$tmp/port")" GHOSTTY_DOCK_TOKEN=tok \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" 2>&1)
    check "a second run changes nothing" "$out" ""

    out=$(HOME="$tmp/home" GHOSTTY_DOCK_API="http://127.0.0.1:$(cat "$tmp/port")" GHOSTTY_DOCK_TOKEN=bad \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" 2>&1)
    check "a refused login changes nothing" "$(echo "$out" | grep -c 'HTTP 401')" 3

    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

main "$@"
