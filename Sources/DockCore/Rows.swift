import Foundation

public enum DisplayStatus: String, Equatable {
    case running   // Claude is working on a turn
    case waiting   // Claude asked a question or wants permission
    case unread    // Claude finished and you have not looked at the tab since
    case inactive  // finished and seen, or never started a turn
    case shell     // a Ghostty tab with no Claude session in it
    case unknown   // an old separate-Ghostty session the hook has not heard from yet
}

public enum Target: Equatable {
    /// A terminal in the shared Ghostty: focusing it selects its tab.
    case terminal(String)
    /// A separate Ghostty process: bring the whole app forward.
    case app(Int32)
}

public struct Row: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var status: DisplayStatus
    public var since: Date?
    public var detail: String
    public var target: Target
    public var selected: Bool

    public init(id: String, name: String, status: DisplayStatus, since: Date?, detail: String, target: Target,
                selected: Bool = false) {
        self.id = id; self.name = name; self.status = status; self.since = since
        self.detail = detail; self.target = target; self.selected = selected
    }
}

public struct RowInputs {
    public var sessions: [SessionRecord]
    public var tabs: [TabRecord]
    public var snapshot: GhosttySnapshot
    public var instances: [GhosttyInstance]
    /// When each row was last looked at (unix seconds), by row id.
    public var seen: [String: Int]
    /// The Ghostty process that answers AppleScript, once known.
    public var homePid: Int32?
    /// The frontmost app's pid.
    public var frontmostPid: Int32?

    public init(sessions: [SessionRecord], tabs: [TabRecord], snapshot: GhosttySnapshot,
                instances: [GhosttyInstance], seen: [String: Int], homePid: Int32?, frontmostPid: Int32?) {
        self.sessions = sessions; self.tabs = tabs; self.snapshot = snapshot; self.instances = instances
        self.seen = seen; self.homePid = homePid; self.frontmostPid = frontmostPid
    }
}

public struct RowResult: Equatable {
    public var rows: [Row]
    /// The row on screen right now, if Ghostty is in front.
    public var viewedId: String?
    /// Learned from a session the dock opened: its Ghostty is the shared one.
    public var homePid: Int32?
}

/// Turns state files, the shared Ghostty's tabs and the running Ghostty
/// processes into the sidebar's rows, in Ghostty's own tab order, then the
/// old separate-Ghostty sessions oldest first.
public func buildRows(_ input: RowInputs) -> RowResult {
    let snapshot = input.snapshot
    let terminalById = Dictionary(snapshot.terminals.map { ($0.terminalId, $0) }, uniquingKeysWith: { a, _ in a })
    let tabTerminal = Dictionary(input.tabs.map { ($0.dockTabId, $0.terminalId) }, uniquingKeysWith: { a, _ in a })

    var homePid = input.homePid
    var claimedTabs = Set<String>()
    var placed: [(session: SessionRecord, terminal: GhosttyTerminal?)] = []

    // Exact: the dock opened this tab and recorded its terminal.
    var unplaced: [SessionRecord] = []
    for s in input.sessions {
        if let dock = s.dockTabId, let tid = tabTerminal[dock], let t = terminalById[tid],
           !claimedTabs.contains(t.tabKey) {
            claimedTabs.insert(t.tabKey)
            placed.append((s, t))
            if homePid == nil, let p = s.ghosttyPid { homePid = p }
        } else {
            unplaced.append(s)
        }
    }

    // Sessions started some other way inside the shared Ghostty: match on the
    // working directory, then on the tab title, which Claude Code sets to the
    // session name. Only for sessions known to be in that process.
    var rest: [SessionRecord] = []
    for s in unplaced {
        guard let home = homePid, s.ghosttyPid == home, s.dockTabId == nil else { rest.append(s); continue }
        let free = snapshot.terminals.filter { !claimedTabs.contains($0.tabKey) }
        let match = free.first { !$0.workingDirectory.isEmpty && ($0.workingDirectory == s.project || $0.workingDirectory == s.cwd) }
            ?? free.first { !s.name.isEmpty && titleNames($0.tabName, s.name) }
        if let t = match {
            claimedTabs.insert(t.tabKey)
            placed.append((s, t))
        } else {
            rest.append(s)
        }
    }

    var rows: [(order: [Int], row: Row)] = []
    var viewed: String?
    let front = snapshot.frontWindowId

    func tabOrder(_ t: GhosttyTerminal) -> [Int] { [0, t.windowIndex, t.tabIndex] }
    func isViewed(_ t: GhosttyTerminal) -> Bool { snapshot.frontmost && t.windowId == front && t.tabSelected }

    for (s, t) in placed {
        let t = t!
        let row = sessionRow(s, target: .terminal(t.terminalId), detail: t.tabName, seen: input.seen,
                             selected: t.tabSelected && t.windowId == front)
        if isViewed(t) { viewed = row.id }
        rows.append((tabOrder(t), row))
    }

    // Tabs with no Claude session: plain shells, or Claude before its first hook.
    var shellTabs = Set<String>()
    for t in snapshot.terminals where !claimedTabs.contains(t.tabKey) && !shellTabs.contains(t.tabKey) {
        shellTabs.insert(t.tabKey)
        let name = cleanTitle(t.tabName).isEmpty ? lastComponent(t.workingDirectory) : cleanTitle(t.tabName)
        let row = Row(id: "term-" + t.terminalId, name: name.isEmpty ? "shell" : name, status: .shell, since: nil,
                      detail: t.workingDirectory, target: .terminal(t.terminalId),
                      selected: t.tabSelected && t.windowId == front)
        if isViewed(t) { viewed = row.id }
        rows.append((tabOrder(t), row))
    }

    // Sessions in separate Ghostty processes.
    var pidsWithRows = Set<Int32>()
    for s in rest {
        guard let pid = s.ghosttyPid else { continue }
        pidsWithRows.insert(pid)
        let row = sessionRow(s, target: .app(pid), detail: s.project, seen: input.seen,
                             selected: input.frontmostPid == pid && pid != homePid)
        if input.frontmostPid == pid && pid != homePid { viewed = row.id }
        rows.append(([1, s.created], row))
    }

    // Separate Ghostty processes the hook has not heard from since it was installed.
    for inst in input.instances where inst.pid != homePid && !pidsWithRows.contains(inst.pid) {
        let name = inst.folder.map(lastComponent) ?? "Ghostty"
        let row = Row(id: "pid-\(inst.pid)", name: name, status: .unknown, since: nil,
                      detail: inst.folder ?? "", target: .app(inst.pid), selected: input.frontmostPid == inst.pid)
        rows.append(([1, inst.started], row))
    }

    rows.sort { $0.order.lexicographicallyPrecedes($1.order) }
    return RowResult(rows: rows.map(\.row), viewedId: viewed, homePid: homePid)
}

func sessionRow(_ s: SessionRecord, target: Target, detail: String, seen: [String: Int], selected: Bool) -> Row {
    let status: DisplayStatus
    switch s.status {
    case "running": status = .running
    case "waiting": status = .waiting
    case "done": status = (seen[s.key] ?? 0) >= s.since ? .inactive : .unread
    default: status = .inactive
    }
    let name = s.name.isEmpty ? lastComponent(s.cwd) : s.name
    return Row(id: s.key, name: name.isEmpty ? "claude" : name, status: status,
               since: Date(timeIntervalSince1970: TimeInterval(s.since)), detail: detail, target: target,
               selected: selected)
}

/// Claude Code titles a tab "<spinner or ✳> <session name>".
func titleNames(_ title: String, _ name: String) -> Bool {
    cleanTitle(title).range(of: name, options: [.caseInsensitive]) != nil
}

/// Drops the leading status glyph Claude Code and shell integration put in titles.
public func cleanTitle(_ title: String) -> String {
    var s = Substring(title)
    while let c = s.first, !(c.isLetter || c.isNumber || c == "/" || c == "~" || c == "." || c == "_") {
        s = s.dropFirst()
    }
    return s.trimmingCharacters(in: .whitespaces)
}

func lastComponent(_ path: String) -> String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
}
