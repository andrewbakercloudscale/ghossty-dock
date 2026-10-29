#!/usr/bin/env bash

# Drives hold/ghostty-dock-hold through a tab's life in pseudo-terminals:
# start, the app going away, reattach with the output replayed, a second tab
# taking over, the tab closed, the program ending. No Ghostty.

SCRIPT_NAME=$(basename "$0")
ROOT=$(cd "$(dirname "$0")/.." && pwd)

function usage() {
    cat <<EOM

Tests ghostty-dock-hold. Exits non-zero on any failure.

usage: ${SCRIPT_NAME}

EOM
    exit 1
}

function main() {
    case "${1:-}" in
    -h | --help) usage ;;
    esac
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    clang -O2 -Wall -Werror -o "$tmp/hold" "$ROOT/hold/ghostty-dock-hold.c" || exit 1
    HOLD="$tmp/hold" STATE="$tmp/state" python3 - <<'PY'
import os, pty, time, subprocess, signal, select, sys, fcntl, termios, struct
HOLD, st = os.environ["HOLD"], os.environ["STATE"]
os.makedirs(st + "/sessions")
env = dict(os.environ, GHOSTTY_DOCK_STATE=st, GHOSTTY_DOCK_SURFACE="S1")
passed = failed = 0
def check(what, ok):
    global passed, failed
    print(("  ok   " if ok else "  FAIL ") + what)
    if ok: passed += 1
    else: failed += 1
def app():
    # Stands in for Ghostty Dock: its pid is what the tab reports.
    p = subprocess.Popen(["sleep", "300"]); env["GHOSTTY_DOCK_HOLD_TEST_APP"] = str(p.pid); return p
def spawn(args):
    pid, fd = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.execve(HOLD, ["ghostty-dock-hold"] + args, env)
    return pid, fd
def read(fd, t=1.0):
    out = b""; end = time.time() + t
    while time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try: out += os.read(fd, 65536)
            except OSError: break
    return out
def lst(*a): return subprocess.run([HOLD, "list", *a], env=env, capture_output=True, text=True).stdout

fake = app()
pid, fd = spawn(["new", "--", "/bin/sh", "-c", "printf '\\033[?2004h\\033]2;mytitle\\007'; echo hello; cat"])
check("runs the program", b"hello" in read(fd))
os.write(fd, b"abc\r")
check("passes keys to it", b"abc" in read(fd))
check("lists it as attached", "\t1\t" in lst())

open(st + "/sessions/srf-S1.json", "w").write("{}")
fake.kill(); fake.wait(); os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); time.sleep(0.5)
check("keeps running when the app goes", "\t0\t" in lst("--detached"))

name = lst().split("\t")[0]
fake = app(); env["GHOSTTY_DOCK_SURFACE"] = "S2"
pid, fd = spawn(["attach", name])
out = read(fd)
check("replays the output on reattach", b"hello" in out and b"abc" in out)
check("restores the modes and title", out.rstrip().endswith(b"\x1b[?2004h\x1b]2;mytitle\x07"))
check("moves the status to the new surface", os.listdir(st + "/sessions") == ["srf-S2.json"]
      and open(f"{st}/hold/{name}.surface").read().strip() == "S2")
os.write(fd, b"again\r")
check("keys reach it after reattach", b"again" in read(fd))

pid2, fd2 = spawn(["attach", name]); read(fd2, 0.5)
check("a newer tab takes over", os.waitpid(pid, os.WNOHANG)[0] == pid)

os.kill(pid2, signal.SIGHUP); time.sleep(1.5)
check("closing the tab ends the program", lst() == "")
fake.kill()

pid, fd = spawn(["new", "--login", "--", "/bin/sh", "-c", "echo bye"])
check("the program ending closes the tab", b"bye" in read(fd) and os.waitpid(pid, 0)[1] == 0 and lst() == "")

# A program a wrapper script started is asked to redraw like one started
# directly; the script is a shell, but not one at its prompt.
fake = app(); env["GHOSTTY_DOCK_SURFACE"] = "S3"
prog = "import signal,sys,time; signal.signal(signal.SIGWINCH, lambda *a: print('redraw', flush=True)); print('up', flush=True); time.sleep(30)"
pid, fd = spawn(["new", "--", "/bin/bash", "-c", f"python3 -c \"{prog}\"; true"])
before = read(fd).count(b"redraw")
fake.kill(); fake.wait(); os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); time.sleep(0.5)
fake = app()
pid, fd = spawn(["attach", lst().split("\t")[0]])
check("a wrapped program redraws on reattach", read(fd, 1.5).count(b"redraw") > before)
os.kill(pid, signal.SIGHUP); time.sleep(1.5); fake.kill()

pid, fd = spawn(["new", "--", "/nonexistent/prog"])
read(fd); os.waitpid(pid, 0)
check("a program that cannot start leaves no holder", lst() == "")

print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
