import AppKit
import Combine
import DockCore

/// Polls Ghostty and the state files, and publishes the sidebar's rows.
/// Ghostty is asked off the main thread; everything published is set on it.
final class DockModel: ObservableObject {
    @Published private(set) var rows: [Row] = []

    var waitingCount: Int { rows.filter { $0.status == .waiting }.count }
    var unreadCount: Int { rows.filter { $0.status == .unread }.count }

    private let files = StateFiles.standard
    private let queue = DispatchQueue(label: "ghostty-dock.poll")
    private var snapshot = GhosttySnapshot.empty
    private var snapshotOK = false
    private var homePid: Int32?
    private var seen: [String: Int]
    /// First-seen order of windows, so switching windows does not reshuffle rows.
    private var windowOrder: [String] = []
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var polling = false

    init() {
        seen = files.seen()
    }

    func start() {
        try? FileManager.default.createDirectory(at: files.sessionsDir, withIntermediateDirectories: true)
        watchSessions()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.poll() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.poll() }
        poll()
    }

    /// Asks Ghostty for its tabs, then rebuilds.
    func poll() {
        guard !polling else { return }
        polling = true
        queue.async { [weak self] in
            let snap = GhosttyBridge.snapshot()
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                self.snapshotOK = snap != nil
                self.snapshot = snap ?? .empty
                self.rebuild()
            }
        }
    }

    /// Rebuilds from the last snapshot; cheap, used when a state file changes.
    func rebuild() {
        let instances = GhosttyBridge.instances()
        let frontApp = NSWorkspace.shared.frontmostApplication
        let frontPid = frontApp?.processIdentifier
        if let h = homePid, !instances.contains(where: { $0.pid == h }) { homePid = nil }
        // The Ghostty that answers AppleScript says it is frontmost: whichever
        // Ghostty process is frontmost is that one.
        if snapshot.frontmost, frontApp?.bundleIdentifier == GhosttyBridge.bundleId, let p = frontPid {
            homePid = p
        }

        if homePid == nil { homePid = findHomePid(instances.map(\.pid)) }

        let liveTerminals = snapshotOK ? Set(snapshot.terminals.map(\.terminalId)) : nil
        let sessions = files.prune(sessions: files.sessions(), liveTerminals: liveTerminals, isAlive: isAlive)

        var snap = snapshot
        for t in snap.terminals where !windowOrder.contains(t.windowId) { windowOrder.append(t.windowId) }
        for i in snap.terminals.indices {
            snap.terminals[i].windowIndex = windowOrder.firstIndex(of: snap.terminals[i].windowId) ?? 0
        }

        let result = buildRows(RowInputs(sessions: sessions, tabs: files.tabs(), snapshot: snap,
                                         instances: instances, seen: seen, homePid: homePid,
                                         frontmostPid: frontPid))
        if homePid == nil { homePid = result.homePid }

        var rows = result.rows
        if let viewed = result.viewedId, let i = rows.firstIndex(where: { $0.id == viewed }),
           rows[i].status == .unread {
            markSeen(viewed)
            rows[i].status = .inactive
        }
        if rows != self.rows { self.rows = rows }
    }

    func select(_ row: Row) {
        markSeen(row.id)
        switch row.target {
        case .terminal(let id):
            queue.async { [weak self] in
                GhosttyBridge.focus(terminal: id)
                DispatchQueue.main.async { self?.poll() }
            }
        case .app(let pid):
            GhosttyBridge.activate(pid: pid)
        }
        rebuild()
    }

    /// True while the folder picker is up, so the app does not hand
    /// activation straight back to Ghostty from under it.
    private(set) var choosingFolder = false

    func newSession() {
        choosingFolder = true
        defer { choosingFolder = false }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Start Claude Code"
        panel.message = "Choose a folder to start a session in"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        GhosttyBridge.openSession(folder: url.path)
    }

    /// Which Ghostty process answers AppleScript: the one whose window titles
    /// (via Accessibility) are the titles of the snapshot's selected tabs.
    /// Titles are compared without Claude Code's spinner glyph, which changes
    /// between the two reads. Nil unless exactly one process matches.
    private func findHomePid(_ pids: [Int32]) -> Int32? {
        let want = Set(snapshot.terminals.filter(\.tabSelected).map { cleanTitle($0.tabName) })
        guard !want.isEmpty else { return nil }
        let matches = pids.filter { Set(WindowTracker.windowTitles(pid: $0).map(cleanTitle)) == want }
        return matches.count == 1 ? matches[0] : nil
    }

    private func markSeen(_ id: String) {
        let now = Int(Date().timeIntervalSince1970)
        guard (seen[id] ?? 0) < now else { return }
        seen[id] = now
        // Forget rows that are long gone, so the file does not grow forever.
        let live = Set(rows.map(\.id))
        seen = seen.filter { live.contains($0.key) || now - $0.value < 86_400 }
        files.saveSeen(seen)
    }

    private func watchSessions() {
        let fd = open(files.sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler { [weak self] in self?.rebuild() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
}
