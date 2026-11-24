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
    def do_POST(self):
        cid = self.path.split("/")[-2]
        t = json.load(open(path))
        t.setdefault("_archived", []).append(cid)
        json.dump(t, open(path, "w"))
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
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

    # Ended sessions leave the phone's list once gone for the grace time.
    local api="http://127.0.0.1:$(cat "$tmp/port")"
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok GHOSTTY_DOCK_RC_KEEP_ENDED=1 \
        GHOSTTY_DOCK_RC_GRACE=0 python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    check "keep-ended archives nothing" "$(jq -r '._archived // [] | length' "$t")" 0
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    check "an ended session waits out the grace time" "$(jq -r '._archived // [] | length' "$t")" 0
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok GHOSTTY_DOCK_RC_GRACE=0 \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    check "an ended session is archived" "$(jq -r '._archived | join(",")' "$t")" cse_D
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok GHOSTTY_DOCK_RC_GRACE=0 \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    check "it is archived once, not every run" "$(jq -r '._archived | length' "$t")" 1
    # A live session that ends (its file now names a dead pid) goes too.
    printf '{"pid":999998,"cwd":"%s","bridgeSessionId":"session_B"}' "$tmp/repos/plain" >"$tmp/home/.claude/sessions/2.json"
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok GHOSTTY_DOCK_RC_GRACE=0 \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    check "a session that ends is archived, live ones are not" "$(jq -r '._archived | join(",")' "$t")" "cse_D,cse_B"
    # A clean exit removes the file; a session seen live before still goes.
    rm -f "$tmp/home/.claude/sessions/2.json"
    printf '{"pid":%s,"cwd":"%s","bridgeSessionId":"session_E"}' "$$" "$tmp/repos/plain" >"$tmp/home/.claude/sessions/5.json"
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok GHOSTTY_DOCK_RC_GRACE=0 \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    rm -f "$tmp/home/.claude/sessions/5.json"
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok GHOSTTY_DOCK_RC_GRACE=0 \
        python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    check "a cleanly closed session is archived" "$(jq -r '._archived | last' "$t")" cse_E
    # A session whose Remote Control failed to connect is logged, once.
    local rlog="$tmp/home/.local/state/ghostty-dock/rc-titles.log" now
    now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    printf '{"pid":%s,"cwd":"%s","sessionId":"f00dfeed-1"}' "$$" "$tmp/repos/plain" >"$tmp/home/.claude/sessions/6.json"
    local tdir="$tmp/home/.claude/projects/$(printf '%s' "$tmp/repos/plain" | sed 's/[^A-Za-z0-9]/-/g')"
    mkdir -p "$tdir" "$tmp/home/.local/state/ghostty-dock/rc-debug"
    : >"$tmp/home/.local/state/ghostty-dock/rc-debug/f00dfeed-1.log"
    { printf '{"type":"system","subtype":"informational","content":"Remote Control disconnected — old news","timestamp":"2020-01-01T00:00:00.000Z"}\n'
      printf '{"type":"system","subtype":"informational","content":"Remote Control disconnected — Session creation failed — see debug log","timestamp":"%s"}\n' "$now"
    } >"$tdir/f00dfeed-1.jsonl"
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    check "a Remote Control failure is logged once" "$(grep -c 'f00dfeed): Remote Control failed.*Session creation failed.*debug log .*f00dfeed-1.log' "$rlog")" 1
    check "old failures are not dug up" "$(grep -c 'old news' "$rlog")" 0
    printf '{"type":"system","subtype":"informational","content":"Remote Control disconnected — later news","timestamp":"2020-01-01T00:00:00.000Z"}\n' >>"$tdir/f00dfeed-1.jsonl"
    HOME="$tmp/home" GHOSTTY_DOCK_API="$api" GHOSTTY_DOCK_TOKEN=tok python3 "$ROOT/bin/ghostty-dock-rc-titles" >/dev/null 2>&1
    check "a new failure in a known session is logged" "$(grep -c 'later news' "$rlog")" 1

    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

main "$@"
