# Ghostty Dock

Ghostty with a Chrome-style vertical tab sidebar: one window, one Dock icon,
every Claude Code session as a tab, coloured by status (needs you, running,
finished, idle, shell) and sorted by name so rows stay put. Ctrl-Opt-J jumps to the
next session waiting for you.

![Ghostty Dock window](docs/window.png)

<img src="docs/statuses.png" width="240" alt="Session sidebar"> <img src="docs/icon.png" width="128" alt="Ghostty Dock icon">

It is Ghostty 1.3.1 plus `patches/ghostty-dock.patch`, built as
`~/Applications/Ghostty Dock.app`. A Claude Code hook (`bin/ghostty-dock-hook`)
reports each session's status.

## Sidebar

| Icon | Colour | Means |
|---|---|---|
| ? (pulsing) | peach | needs you: a question or permission prompt |
| ✓ | blue | finished, not looked at yet |
| moon | mauve | idle |
| spinning arrows | green | running |
| terminal | teal | plain shell, no Claude Code |

- Click a row to switch to it; ✕ closes it; + opens a new tab.
- Drag the sidebar's right edge to make it wider or narrower (double-click the edge to reset).
- Click a row's **Undock** icon (↗, beside ✕; or right-click → Undock) to move that session out
  to its own Ghostty window: claude is stopped and resumed there at once.
- **Undocked**: Claude Code sessions in their own Ghostty windows are listed
  under the tabs, grey with a dashed outline. Click one to show its window, or
  its **Dock** icon (↙) to restart it in a tab here at once.
  Same as `ghostty-dock-move --pid <pid>`, `--undock <session id>`, `--detach`.
- Ctrl-Opt-J: jump to the next session that needs you (then finished ones).
- Dock badge: how many sessions need you.

## Settings (Cmd-,)

- Sort: **alphabetical** (default; rows never move), **urgency** (needs you, then idle with most recently idle first, then
  running), **running first** (running, then needs you, then idle), or **tab order**.
- Sidebar on/off, native tab bar, hotkey, Dock badge, open at login.

## Install

    ./install.sh                     # hooks, opener, Finder Quick Actions, app
    scripts/build-terminal.sh        # rebuild the app only
    ghostty-dock-move --detach       # move sessions from separate Ghostty apps into tabs

## If it goes wrong: undo

    scripts/undo.sh --list           # what it would reopen
    scripts/undo.sh                  # do it

Reopens every Claude Code session that the move or restart scripts stopped,
each in its own stock Ghostty app with `claude --resume <id>` and its original
flags. Running sessions are left alone. It also brings Ghostty back to the Dock
and Cmd-Tab, restores the Finder Quick Actions, and makes `ghostty-dock-open`
use stock Ghostty again. `--sessions-only` skips those settings.

Sessions come from `~/.local/state/ghostty-dock/sessions-snapshot.tsv`, written
before anything is stopped, and from the scripts' logs. Pass session ids to
reopen specific ones.

`./install.sh --uninstall` removes everything.

## Do not

Quit or restart Ghostty Dock while sessions run in it: that ends them. Use
`scripts/restart-dock.sh`, which waits until they are quiet and resumes them.
