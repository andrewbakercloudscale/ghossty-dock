// ghostty-dock-hold: keeps a terminal's program running when Ghostty Dock
// quits, crashes or restarts, so its tabs come back as they were.
//
// Ghostty Dock runs every tab as `ghostty-dock-hold new -- <command>`. That
// starts a holder (the "master"): a small process of its own, outside the
// app, that runs the command in a pseudo-terminal and keeps the last few MB
// of its output. The tab itself is only a client that passes keys in and
// output out over a socket in ~/.local/state/ghostty-dock/hold.
//
// When the tab is closed the command is hung up, as in any terminal. When
// the app goes away (quit, crash, restart) the holder keeps the command
// running, and the next app reattaches a tab to it with `attach <name>`:
// the kept output is replayed, so scrollback and search still work, and a
// full-screen program is asked to redraw.

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#define RING_SIZE (4 * 1024 * 1024)
#define MAX_MODES 32
#define MAX_KITTY 16

enum { PKT_HELLO = 'H', PKT_INPUT = 'I', PKT_WINSIZE = 'W', PKT_INFO = 'Q', PKT_KILL = 'K',
       PKT_DETACH = 'D', PKT_CLOSE = 'C' };

static char hold_dir[512];
static char state_dir[512];

static void die(const char *what) {
    fprintf(stderr, "ghostty-dock-hold: %s: %s\n", what, strerror(errno));
    exit(1);
}

static void set_dirs(void) {
    const char *s = getenv("GHOSTTY_DOCK_STATE");
    const char *home = getenv("HOME");
    if (!home) home = getpwuid(getuid())->pw_dir;
    if (s && *s) snprintf(state_dir, sizeof state_dir, "%s", s);
    else snprintf(state_dir, sizeof state_dir, "%s/.local/state/ghostty-dock", home);
    snprintf(hold_dir, sizeof hold_dir, "%s/hold", state_dir);
    mkdir(state_dir, 0700);
    mkdir(hold_dir, 0700);
}

static void sock_path(const char *name, char *out, size_t n) { snprintf(out, n, "%s/%s.sock", hold_dir, name); }

static int write_all(int fd, const void *buf, size_t len) {
    const char *p = buf;
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) { struct pollfd pf = {fd, POLLOUT, 0}; if (poll(&pf, 1, 5000) <= 0) return -1; continue; }
            return -1;
        }
        p += w;
        len -= (size_t)w;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t len) {
    char *p = buf;
    while (len > 0) {
        ssize_t r = read(fd, p, len);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        p += r;
        len -= (size_t)r;
    }
    return 0;
}

static int send_pkt(int fd, char type, const void *data, uint32_t len) {
    char hdr[5] = {type, (char)(len & 0xff), (char)((len >> 8) & 0xff), (char)((len >> 16) & 0xff), (char)(len >> 24)};
    if (write_all(fd, hdr, 5) < 0) return -1;
    return len ? write_all(fd, data, len) : 0;
}

static int connect_to(const char *name) {
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    sock_path(name, a.sun_path, sizeof a.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    return fd;
}

// True while the process runs and is not exiting: a crashed or quitting
// app is still there for a moment, closing its terminals.
static int alive(pid_t pid) {
    if (pid <= 0) return 0;
    struct kinfo_proc kp;
    size_t len = sizeof kp;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) < 0 || len == 0) return 0;
    if (kp.kp_proc.p_stat == SZOMB || (kp.kp_proc.p_flag & P_WEXIT)) return 0;
    return 1;
}

// The Ghostty process this runs in, from the parent chain.
static pid_t find_app(void) {
    const char *test = getenv("GHOSTTY_DOCK_HOLD_TEST_APP");
    if (test) return atoi(test);
    pid_t pid = getppid();
    for (int hops = 0; pid > 1 && hops < 20; hops++) {
        char name[PROC_PIDPATHINFO_MAXSIZE] = "";
        proc_name(pid, name, sizeof name);
        if (strcmp(name, "ghostty") == 0) return pid;
        struct kinfo_proc kp;
        size_t len = sizeof kp;
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
        if (sysctl(mib, 4, &kp, &len, NULL, 0) < 0 || len == 0) break;
        pid = kp.kp_eproc.e_ppid;
    }
    return 0;
}

// The app writes its pid to hold/quitting as it quits: its terminals then
// let go of their holders instead of hanging them up.
static int app_quitting(pid_t app) {
    if (app <= 0) return 0;
    char path[600], buf[32] = "";
    snprintf(path, sizeof path, "%s/quitting", hold_dir);
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    if (!fgets(buf, sizeof buf, f)) buf[0] = 0;
    fclose(f);
    return atoi(buf) == app;
}

// ---- master ----------------------------------------------------------------

static char *ring;
static size_t ring_head, ring_len;

// The terminal modes a program set before the kept output began, so a
// reattached tab gets keys and mouse reports in the form the program expects.
static struct { int mode; int on; } modes[MAX_MODES];
static int nmodes;
static int kitty[MAX_KITTY], nkitty;
static int other_keys = -1, keypad;
static char title[512], cwd_osc[1024];

static enum { P_GROUND, P_ESC, P_CSI, P_OSC, P_OSC_ESC } pstate;
static char pbuf[1100];
static size_t plen;

static void set_mode(int mode, int on) {
    for (int i = 0; i < nmodes; i++) if (modes[i].mode == mode) { modes[i].on = on; return; }
    if (nmodes < MAX_MODES) { modes[nmodes].mode = mode; modes[nmodes].on = on; nmodes++; }
}

static int mode_on(int mode) {
    for (int i = 0; i < nmodes; i++) if (modes[i].mode == mode) return modes[i].on;
    return 0;
}

static void end_csi(char final) {
    pbuf[plen] = 0;
    if (pbuf[0] == '?' && (final == 'h' || final == 'l')) {
        char *p = pbuf + 1;
        while (*p) {
            set_mode((int)strtol(p, &p, 10), final == 'h');
            if (*p == ';') p++; else break;
        }
    } else if (final == 'u' && pbuf[0] == '>') {
        if (nkitty < MAX_KITTY) kitty[nkitty++] = atoi(pbuf + 1);
    } else if (final == 'u' && pbuf[0] == '<') {
        int n = pbuf[1] ? atoi(pbuf + 1) : 1;
        nkitty = n >= nkitty ? 0 : nkitty - n;
    } else if (final == 'u' && pbuf[0] == '=') {
        int flags = atoi(pbuf + 1), how = 1;
        char *semi = strchr(pbuf, ';');
        if (semi) how = atoi(semi + 1);
        if (nkitty == 0) kitty[nkitty++] = 0;
        int *top = &kitty[nkitty - 1];
        *top = how == 2 ? (*top | flags) : how == 3 ? (*top & ~flags) : flags;
    } else if (final == 'm' && pbuf[0] == '>' && strncmp(pbuf, ">4", 2) == 0) {
        other_keys = pbuf[2] == ';' ? atoi(pbuf + 3) : 0;
    }
}

static void end_osc(void) {
    pbuf[plen] = 0;
    if ((pbuf[0] == '0' || pbuf[0] == '2') && pbuf[1] == ';') snprintf(title, sizeof title, "%s", pbuf + 2);
    else if (pbuf[0] == '7' && pbuf[1] == ';') snprintf(cwd_osc, sizeof cwd_osc, "%s", pbuf + 2);
}

static void track(const char *buf, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)buf[i];
        switch (pstate) {
        case P_GROUND:
            if (c == 0x1b) pstate = P_ESC;
            break;
        case P_ESC:
            if (c == '[') { pstate = P_CSI; plen = 0; }
            else if (c == ']') { pstate = P_OSC; plen = 0; }
            else { if (c == '=') keypad = 1; else if (c == '>') keypad = 0; pstate = P_GROUND; }
            break;
        case P_CSI:
            if (c >= 0x40 && c <= 0x7e) { end_csi((char)c); pstate = P_GROUND; }
            else if (plen < 64) pbuf[plen++] = (char)c;
            else pstate = P_GROUND;
            break;
        case P_OSC:
            if (c == 0x07) { end_osc(); pstate = P_GROUND; }
            else if (c == 0x1b) pstate = P_OSC_ESC;
            else if (plen < sizeof pbuf - 1) pbuf[plen++] = (char)c;
            break;
        case P_OSC_ESC:
            if (c == '\\') end_osc();
            pstate = c == 0x1b ? P_ESC : P_GROUND;
            if (c == '[') { pstate = P_CSI; plen = 0; }
            break;
        }
    }
}

static void keep(const char *buf, size_t n) {
    track(buf, n);
    if (n >= RING_SIZE) { buf += n - RING_SIZE; n = RING_SIZE; }
    size_t tail = (ring_head + ring_len) % RING_SIZE;
    size_t first = n < RING_SIZE - tail ? n : RING_SIZE - tail;
    memcpy(ring + tail, buf, first);
    memcpy(ring, buf + first, n - first);
    ring_len += n;
    if (ring_len > RING_SIZE) { ring_head = (ring_head + ring_len - RING_SIZE) % RING_SIZE; ring_len = RING_SIZE; }
}

// The kept output as one block, from the first line start once it has wrapped.
static char *kept(size_t *n) {
    char *out = malloc(ring_len + 1);
    size_t first = ring_len < RING_SIZE - ring_head ? ring_len : RING_SIZE - ring_head;
    memcpy(out, ring + ring_head, first);
    memcpy(out + first, ring, ring_len - first);
    size_t skip = 0;
    if (ring_len == RING_SIZE) {
        char *nl = memchr(out, '\n', ring_len < 65536 ? ring_len : 65536);
        if (nl) skip = (size_t)(nl - out) + 1;
    }
    *n = ring_len - skip;
    memmove(out, out + skip, *n);
    return out;
}

// Whether the alternate screen was last switched on or off in the replay
// (1), not at all (-1) or off (0).
static int replay_alt(const char *buf, size_t n) {
    for (size_t i = n; i-- > 3;) {
        if (buf[i] != 'h' && buf[i] != 'l') continue;
        const char *pats[] = {"\x1b[?1049", "\x1b[?1047", "\x1b[?47"};
        for (int k = 0; k < 3; k++) {
            size_t pl = strlen(pats[k]);
            if (i >= pl && memcmp(buf + i - pl, pats[k], pl) == 0) return buf[i] == 'h';
        }
    }
    return -1;
}

static int is_shell(pid_t pid) {
    char name[PROC_PIDPATHINFO_MAXSIZE] = "";
    proc_name(pid, name, sizeof name);
    const char *shells[] = {"zsh", "bash", "fish", "sh", "dash", "tcsh", "csh", "ksh", "nu", "elvish"};
    for (size_t i = 0; i < sizeof shells / sizeof *shells; i++) if (strcmp(name, shells[i]) == 0) return 1;
    return 0;
}

// Whether the foreground group is just a shell at its prompt. A script that
// launches a program (a wrapper around claude) keeps it in its own group.
static int shell_only(pid_t pgrp) {
    pid_t pids[256];
    int n = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgrp, pids, sizeof pids) / (int)sizeof *pids;
    if (n <= 0) return is_shell(pgrp);
    for (int i = 0; i < n; i++) if (pids[i] > 0 && !is_shell(pids[i])) return 0;
    return 1;
}

static void replay(int fd, int pty, struct winsize ws) {
    size_t n;
    char *buf = kept(&n);
    write_all(fd, "\x1b[0m", 4);
    write_all(fd, buf, n);
    char out[2048];
    size_t o = 0;
    o += (size_t)snprintf(out + o, sizeof out - o, "\x1b[0m\x1b[?2026l");
    int alt = replay_alt(buf, n), want = mode_on(1049) || mode_on(1047) || mode_on(47);
    if (alt == -1 ? want : alt != want) o += (size_t)snprintf(out + o, sizeof out - o, "\x1b[?1049%c", want ? 'h' : 'l');
    for (int i = 0; i < nmodes; i++) {
        int m = modes[i].mode;
        if (m == 1049 || m == 1047 || m == 47 || m == 2026) continue;
        o += (size_t)snprintf(out + o, sizeof out - o, "\x1b[?%d%c", m, modes[i].on ? 'h' : 'l');
    }
    for (int i = 0; i < nkitty && o < sizeof out - 32; i++) o += (size_t)snprintf(out + o, sizeof out - o, "\x1b[>%du", kitty[i]);
    if (other_keys >= 0) o += (size_t)snprintf(out + o, sizeof out - o, "\x1b[>4;%dm", other_keys);
    if (keypad) o += (size_t)snprintf(out + o, sizeof out - o, "\x1b=");
    write_all(fd, out, o);
    if (title[0]) { write_all(fd, "\x1b]2;", 4); write_all(fd, title, strlen(title)); write_all(fd, "\x07", 1); }
    if (cwd_osc[0]) { write_all(fd, "\x1b]7;", 4); write_all(fd, cwd_osc, strlen(cwd_osc)); write_all(fd, "\x07", 1); }
    free(buf);

    // A program redraws on a size change; a shell would only print its prompt again.
    pid_t fg = tcgetpgrp(pty);
    if (fg > 0 && !shell_only(fg) && ws.ws_col > 2) {
        struct winsize nudge = ws;
        nudge.ws_col--;
        ioctl(pty, TIOCSWINSZ, &nudge);
        usleep(50000);
    }
    ioctl(pty, TIOCSWINSZ, &ws);
}

static void cwd_of(pid_t pid, char *out, size_t n) {
    struct proc_vnodepathinfo vpi;
    out[0] = 0;
    if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof vpi) == sizeof vpi)
        snprintf(out, n, "%s", vpi.pvi_cdir.vip_path);
}

static volatile sig_atomic_t child_exited;
static void on_chld(int sig) { (void)sig; child_exited = 1; }

struct hello { uint16_t rows, cols; int32_t app; };

static void master(const char *name, int listen_fd, int ready_fd, struct winsize ws, int login, char **argv) {
    ring = malloc(RING_SIZE);
    if (!ring) exit(1);
    int pty;
    char hold_env[64];
    snprintf(hold_env, sizeof hold_env, "GHOSTTY_DOCK_HOLD=%s", name);
    pid_t child = forkpty(&pty, NULL, NULL, &ws);
    if (child < 0) exit(1);
    if (child == 0) {
        putenv(hold_env);
        // Ghostty sets up its shell integration only for a shell it starts
        // itself; this one is started here, so do the same for zsh.
        const char *base = strrchr(argv[0], '/');
        base = base ? base + 1 : argv[0];
        const char *res = getenv("GHOSTTY_RESOURCES_DIR");
        if (strcmp(base, "zsh") == 0 && res && !getenv("GHOSTTY_DOCK_NO_INTEGRATION")) {
            char integ[1024];
            snprintf(integ, sizeof integ, "%s/shell-integration/zsh", res);
            struct stat st;
            if (stat(integ, &st) == 0) {
                const char *old = getenv("ZDOTDIR");
                if (old) setenv("GHOSTTY_ZSH_ZDOTDIR", old, 1);
                setenv("ZDOTDIR", integ, 1);
            }
        }
        char *file = argv[0];
        if (login) {
            char *a0 = malloc(strlen(base) + 2);
            sprintf(a0, "-%s", base);
            argv[0] = a0;
        }
        execvp(file, argv);
        fprintf(stderr, "ghostty-dock-hold: %s: %s\n", file, strerror(errno));
        _exit(127);
    }
    signal(SIGCHLD, on_chld);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
    write(ready_fd, "1", 1);
    close(ready_fd);

    time_t created = time(NULL);
    int client = -1;
    pid_t client_app = 0;
    char pending[8192 + 5];
    size_t pend = 0;
    int hung_up = 0;
    time_t hup_at = 0;
    char buf[65536];

    for (;;) {
        if (child_exited) {
            int st;
            if (waitpid(child, &st, WNOHANG) == child) {
                // Drain what it wrote last.
                ssize_t r;
                fcntl(pty, F_SETFL, O_NONBLOCK);
                while ((r = read(pty, buf, sizeof buf)) > 0) if (client >= 0) write_all(client, buf, (size_t)r);
                break;
            }
            child_exited = 0;
        }
        if (hung_up && time(NULL) - hup_at > 5) kill(-child, SIGKILL);

        struct pollfd pf[3] = {{listen_fd, POLLIN, 0}, {pty, POLLIN, 0}, {client, POLLIN, 0}};
        int np = client >= 0 ? 3 : 2;
        if (poll(pf, (nfds_t)np, 1000) < 0) { if (errno == EINTR) continue; break; }

        if (pf[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t r = read(pty, buf, sizeof buf);
            if (r > 0) {
                keep(buf, (size_t)r);
                if (client >= 0 && write_all(client, buf, (size_t)r) < 0) { close(client); client = -1; }
            } else if (r == 0 || (errno != EINTR && errno != EAGAIN)) {
                int st;
                waitpid(child, &st, 0);
                break;
            }
        }

        if (np == 3 && (pf[2].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t r = read(client, pending + pend, sizeof pending - pend);
            int closed = r <= 0, verdict = 0;
            if (r > 0) pend += (size_t)r;
            while (pend >= 5) {
                uint32_t len = (uint8_t)pending[1] | (uint8_t)pending[2] << 8 | (uint8_t)pending[3] << 16 | (uint32_t)(uint8_t)pending[4] << 24;
                if (len > 8192) { closed = 1; pend = 0; break; }
                if (pend < 5 + len) break;
                char type = pending[0];
                if (type == PKT_INPUT) write_all(pty, pending + 5, len);
                else if (type == PKT_WINSIZE && len >= 4) {
                    struct winsize w = {0};
                    memcpy(&w.ws_row, pending + 5, 2);
                    memcpy(&w.ws_col, pending + 7, 2);
                    ioctl(pty, TIOCSWINSZ, &w);
                } else if (type == PKT_DETACH || type == PKT_CLOSE) verdict = type;
                memmove(pending, pending + 5 + len, pend - 5 - len);
                pend -= 5 + len;
            }
            if (closed || verdict) {
                close(client);
                client = -1;
                pend = 0;
                // The tab told us whether it was closed or the app went away;
                // a tab that died without saying is judged here the same way.
                int keep_it = verdict == PKT_DETACH ||
                              (verdict == 0 && (!alive(client_app) || app_quitting(client_app)));
                if (!keep_it && !hung_up) {
                    pid_t fg = tcgetpgrp(pty);
                    if (fg > 0) kill(-fg, SIGHUP);
                    kill(-child, SIGHUP);
                    hung_up = 1;
                    hup_at = time(NULL);
                }
            }
        }

        if (pf[0].revents & POLLIN) {
            int fd = accept(listen_fd, NULL, NULL);
            if (fd < 0) continue;
            struct timeval tv = {2, 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
            int on = 1;
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
            char hdr[5];
            if (read_all(fd, hdr, 5) < 0) { close(fd); continue; }
            uint32_t len = (uint8_t)hdr[1] | (uint8_t)hdr[2] << 8 | (uint8_t)hdr[3] << 16 | (uint32_t)(uint8_t)hdr[4] << 24;
            char body[4096];
            if (len > sizeof body || read_all(fd, body, len) < 0) { close(fd); continue; }
            if (hdr[0] == PKT_INFO) {
                char cwd[1100], line[2048];
                pid_t fg = tcgetpgrp(pty);
                cwd_of(fg > 0 ? fg : child, cwd, sizeof cwd);
                char fgname[PROC_PIDPATHINFO_MAXSIZE] = "";
                proc_name(fg > 0 ? fg : child, fgname, sizeof fgname);
                int n = snprintf(line, sizeof line, "%s\t%d\t%d\t%s\t%ld\t%d\t%s\n", name, getpid(), client >= 0,
                                 cwd, (long)created, child, fgname);
                write_all(fd, line, (size_t)n);
                close(fd);
            } else if (hdr[0] == PKT_KILL) {
                kill(-child, SIGHUP);
                hung_up = 1;
                hup_at = time(NULL);
                close(fd);
            } else if (hdr[0] == PKT_HELLO && len >= sizeof(struct hello) && !hung_up) {
                struct hello h;
                memcpy(&h, body, sizeof h);
                // One tab at a time: a newer one takes over.
                if (client >= 0) close(client);
                client = fd;
                client_app = h.app;
                pend = 0;
                struct winsize w = {.ws_row = h.rows, .ws_col = h.cols};
                struct timeval none = {0, 0}, slow = {5, 0};
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, sizeof none);
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &slow, sizeof slow);
                replay(fd, pty, w);
            } else {
                close(fd);
            }
        }
    }
    if (client >= 0) close(client);
    char path[600];
    sock_path(name, path, sizeof path);
    unlink(path);
    exit(0);
}

// ---- client ----------------------------------------------------------------

static struct termios saved_tio;
static int tio_saved;
static volatile sig_atomic_t got_winch, got_hup;
static void on_winch(int sig) { (void)sig; got_winch = 1; }
static void on_hup(int sig) { (void)sig; got_hup = 1; }

static void restore_tty(void) {
    if (tio_saved) tcsetattr(STDIN_FILENO, TCSANOW, &saved_tio);
}

static void winsize_of(struct winsize *ws) {
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, ws) < 0 || ws->ws_row == 0) { ws->ws_row = 24; ws->ws_col = 80; }
}

// Records this tab's surface for the holder, so Claude Code's hook writes
// its status under the tab it is in now, and moves the status already
// written under the tab it was in before.
static void record_surface(const char *name) {
    const char *surface = getenv("GHOSTTY_DOCK_SURFACE");
    if (!surface || !*surface) return;
    char path[600], tmp[620], old[128] = "";
    snprintf(path, sizeof path, "%s/%s.surface", hold_dir, name);
    FILE *f = fopen(path, "r");
    if (f) { if (!fgets(old, sizeof old, f)) old[0] = 0; fclose(f); old[strcspn(old, "\n")] = 0; }
    snprintf(tmp, sizeof tmp, "%s.%d", path, getpid());
    f = fopen(tmp, "w");
    if (f) { fprintf(f, "%s\n", surface); fclose(f); rename(tmp, path); }
    if (old[0] && strcmp(old, surface) != 0) {
        char from[700], to[700];
        snprintf(from, sizeof from, "%s/sessions/srf-%s.json", state_dir, old);
        snprintf(to, sizeof to, "%s/sessions/srf-%s.json", state_dir, surface);
        rename(from, to);
    }
}

static int client(const char *name) {
    int fd = connect_to(name);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    record_surface(name);
    pid_t app = find_app();
    struct winsize ws;
    winsize_of(&ws);
    struct hello h = {ws.ws_row, ws.ws_col, app};
    if (send_pkt(fd, PKT_HELLO, &h, sizeof h) < 0) { close(fd); return -1; }

    if (isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &saved_tio) == 0) {
        tio_saved = 1;
        struct termios raw = saved_tio;
        cfmakeraw(&raw);
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
        atexit(restore_tty);
    }
    struct sigaction sa = {0};
    sa.sa_handler = on_winch;
    sigaction(SIGWINCH, &sa, NULL);
    sa.sa_handler = on_hup;
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    char buf[65536];
    for (;;) {
        if (got_hup) break;
        if (got_winch) {
            got_winch = 0;
            winsize_of(&ws);
            uint16_t sz[2] = {ws.ws_row, ws.ws_col};
            send_pkt(fd, PKT_WINSIZE, sz, sizeof sz);
        }
        struct pollfd pf[2] = {{STDIN_FILENO, POLLIN, 0}, {fd, POLLIN, 0}};
        if (poll(pf, 2, -1) < 0) { if (errno == EINTR) continue; break; }
        if (pf[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t r = read(fd, buf, sizeof buf);
            // The program ended, or another tab took over.
            if (r <= 0) { close(fd); return 0; }
            if (write_all(STDOUT_FILENO, buf, (size_t)r) < 0) break;
        }
        if (pf[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t r = read(STDIN_FILENO, buf, 8192);
            if (r <= 0) break;
            if (send_pkt(fd, PKT_INPUT, buf, (uint32_t)r) < 0) { close(fd); return 0; }
        }
    }
    // The terminal went away: the tab was closed, or the app is going.
    send_pkt(fd, !alive(app) || app_quitting(app) ? PKT_DETACH : PKT_CLOSE, NULL, 0);
    close(fd);
    return 0;
}

// ---- commands --------------------------------------------------------------

static void new_name(char *out, size_t n) {
    unsigned char b[6];
    arc4random_buf(b, sizeof b);
    snprintf(out, n, "%02x%02x%02x%02x%02x%02x", b[0], b[1], b[2], b[3], b[4], b[5]);
}

static int cmd_new(int login, char **argv) {
    char name[32], path[600];
    new_name(name, sizeof name);
    sock_path(name, path, sizeof path);
    struct winsize ws;
    winsize_of(&ws);

    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    int ready[2];
    if (lfd < 0 || bind(lfd, (struct sockaddr *)&a, sizeof a) < 0 || listen(lfd, 8) < 0 || pipe(ready) < 0) goto direct;
    chmod(path, 0600);

    pid_t pid = fork();
    if (pid < 0) goto direct;
    if (pid == 0) {
        // Its own session, so closing the tab's terminal does not reach it,
        // and reparented to launchd once the middle process exits.
        setsid();
        if (fork() != 0) _exit(0);
        close(ready[0]);
        int null = open("/dev/null", O_RDWR);
        dup2(null, 0); dup2(null, 1); dup2(null, 2);
        if (null > 2) close(null);
        fcntl(lfd, F_SETFD, FD_CLOEXEC);
        fcntl(ready[1], F_SETFD, FD_CLOEXEC);
        master(name, lfd, ready[1], ws, login, argv);
    }
    close(lfd);
    close(ready[1]);
    waitpid(pid, NULL, 0);
    char ok = 0;
    struct pollfd pf = {ready[0], POLLIN, 0};
    if (poll(&pf, 1, 3000) > 0 && read(ready[0], &ok, 1) == 1 && ok == '1') {
        close(ready[0]);
        if (client(name) == 0) return 0;
    }
    close(ready[0]);
    unlink(path);

direct:
    // Never leave the tab without its program: run it here instead.
    if (login) {
        const char *base = strrchr(argv[0], '/');
        base = base ? base + 1 : argv[0];
        char *file = argv[0], *a0 = malloc(strlen(base) + 2);
        sprintf(a0, "-%s", base);
        argv[0] = a0;
        execvp(file, argv);
    } else {
        execvp(argv[0], argv);
    }
    die(argv[0]);
    return 1;
}

static int query(const char *name, char type, char *out, size_t n) {
    int fd = connect_to(name);
    if (fd < 0) return -1;
    struct timeval tv = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    if (send_pkt(fd, type, NULL, 0) < 0) { close(fd); return -1; }
    size_t got = 0;
    ssize_t r;
    while (out && got < n - 1 && (r = read(fd, out + got, n - 1 - got)) > 0) got += (size_t)r;
    if (out) out[got] = 0;
    close(fd);
    return 0;
}



// One line per holder: name, holder pid, attached (1/0), folder, started
// (epoch), program pid, foreground program.
static int cmd_list(int detached_only, int kill_them) {
    DIR *d = opendir(hold_dir);
    if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        size_t l = strlen(e->d_name);
        if (l < 6 || strcmp(e->d_name + l - 5, ".sock") != 0) continue;
        char name[64];
        snprintf(name, sizeof name, "%.*s", (int)(l - 5), e->d_name);
        char line[2048];
        if (query(name, PKT_INFO, line, sizeof line) < 0) {
            // Its holder is gone.
            char path[600];
            sock_path(name, path, sizeof path);
            if (errno == ECONNREFUSED || errno == ENOENT) {
                unlink(path);
                char surf[620];
                snprintf(surf, sizeof surf, "%s/%s.surface", hold_dir, name);
                unlink(surf);
            }
            continue;
        }
        char *tab = strchr(line, '\t');
        int attached = tab && strchr(tab + 1, '\t') && strchr(tab + 1, '\t')[1] == '1';
        if (detached_only && attached) continue;
        if (kill_them) query(name, PKT_KILL, NULL, 0);
        else fputs(line, stdout);
    }
    closedir(d);
    return 0;
}

// macOS asks the app that started a process before letting it into the
// Desktop, Documents and the like. A tab's holder outlives the app that
// started it, so it answers for itself instead: it is signed as the app,
// and its shell gets the app's permissions before and after a restart.
extern int responsibility_get_pid_responsible_for_pid(pid_t);
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *, bool);
extern char **environ;

static void disclaim(char **argv) {
    if (responsibility_get_pid_responsible_for_pid(getpid()) == getpid()) return;
    char self[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), self, sizeof self) <= 0) return;
    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) return;
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETEXEC);
    responsibility_spawnattrs_setdisclaim(&attr, true);
    posix_spawn(NULL, self, NULL, &attr, argv, environ);
    // Only returns if it could not: run on as the app's.
    posix_spawnattr_destroy(&attr);
}

static void usage(void) {
    fputs("usage: ghostty-dock-hold new [--login] -- <command> [args...]\n"
          "       ghostty-dock-hold attach <name>\n"
          "       ghostty-dock-hold list [--detached]\n"
          "       ghostty-dock-hold kill <name>\n"
          "       ghostty-dock-hold kill-detached\n",
          stderr);
    exit(2);
}

int main(int argc, char **argv) {
    if (argc < 2) usage();
    set_dirs();
    const char *cmd = argv[1];
    if (strcmp(cmd, "new") == 0) {
        int login = 0, i = 2;
        for (; i < argc && strcmp(argv[i], "--") != 0; i++)
            if (strcmp(argv[i], "--login") == 0) login = 1;
        if (i + 1 >= argc) usage();
        disclaim(argv);
        unsetenv("GHOSTTY_DOCK_HOLD");
        return cmd_new(login, argv + i + 1);
    }
    if (strcmp(cmd, "attach") == 0 && argc == 3) {
        if (client(argv[2]) == 0) return 0;
        fprintf(stderr, "ghostty-dock-hold: %s has ended\n", argv[2]);
        return 1;
    }
    if (strcmp(cmd, "list") == 0) return cmd_list(argc > 2 && strcmp(argv[2], "--detached") == 0, 0);
    if (strcmp(cmd, "kill") == 0 && argc == 3) return query(argv[2], PKT_KILL, NULL, 0) < 0;
    if (strcmp(cmd, "kill-detached") == 0) return cmd_list(1, 1);
    usage();
    return 2;
}
