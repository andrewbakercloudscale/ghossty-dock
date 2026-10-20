import Foundation

/// One Claude Code session, as bin/ghostty-dock-hook writes it to
/// sessions/<key>.json. The key is per terminal, not per Claude session id.
public struct SessionRecord: Codable, Equatable {
    public var key: String
    public var status: String
    public var since: Int
    public var updated: Int
    public var created: Int
    public var sessionId: String
    public var project: String
    public var cwd: String
    public var name: String
    public var dockTabId: String?
    public var claudePid: Int32?
    public var ghosttyPid: Int32?
    public var tty: String?

    enum CodingKeys: String, CodingKey {
        case key, status, since, updated, created, project, cwd, name, tty
        case sessionId = "session_id"
        case dockTabId = "dock_tab_id"
        case claudePid = "claude_pid"
        case ghosttyPid = "ghostty_pid"
    }

    public init(key: String, status: String, since: Int, updated: Int, created: Int, sessionId: String = "",
                project: String = "", cwd: String = "", name: String, dockTabId: String? = nil,
                claudePid: Int32? = nil, ghosttyPid: Int32? = nil, tty: String? = nil) {
        self.key = key; self.status = status; self.since = since; self.updated = updated
        self.created = created; self.sessionId = sessionId; self.project = project; self.cwd = cwd
        self.name = name; self.dockTabId = dockTabId; self.claudePid = claudePid
        self.ghosttyPid = ghosttyPid; self.tty = tty
    }
}

/// A tab bin/ghostty-dock-open created, as tabs/<dock_tab_id>.json.
public struct TabRecord: Codable, Equatable {
    public var dockTabId: String
    public var terminalId: String
    public var folder: String
    public var created: Int

    enum CodingKeys: String, CodingKey {
        case folder, created
        case dockTabId = "dock_tab_id"
        case terminalId = "terminal_id"
    }

    public init(dockTabId: String, terminalId: String, folder: String, created: Int) {
        self.dockTabId = dockTabId; self.terminalId = terminalId; self.folder = folder; self.created = created
    }
}

/// One terminal surface in the Ghostty that answers AppleScript.
public struct GhosttyTerminal: Equatable {
    public var windowId: String
    public var windowIndex: Int
    public var tabId: String
    public var tabIndex: Int
    public var tabSelected: Bool
    public var terminalId: String
    public var workingDirectory: String
    public var tabName: String

    public init(windowId: String, windowIndex: Int, tabId: String, tabIndex: Int, tabSelected: Bool,
                terminalId: String, workingDirectory: String, tabName: String) {
        self.windowId = windowId; self.windowIndex = windowIndex; self.tabId = tabId; self.tabIndex = tabIndex
        self.tabSelected = tabSelected; self.terminalId = terminalId
        self.workingDirectory = workingDirectory; self.tabName = tabName
    }

    var tabKey: String { windowId + "/" + tabId }
}

public struct GhosttySnapshot: Equatable {
    /// Whether this Ghostty is the active app.
    public var frontmost: Bool
    public var frontWindowId: String?
    public var terminals: [GhosttyTerminal]

    public init(frontmost: Bool, frontWindowId: String?, terminals: [GhosttyTerminal]) {
        self.frontmost = frontmost; self.frontWindowId = frontWindowId; self.terminals = terminals
    }

    public static let empty = GhosttySnapshot(frontmost: false, frontWindowId: nil, terminals: [])
}

/// A running Ghostty process. Before Ghostty Dock every session was its own
/// Ghostty (`open -na`); those keep running until they are closed.
public struct GhosttyInstance: Equatable {
    public var pid: Int32
    /// The folder a launcher was started in, from the process's arguments.
    public var folder: String?
    public var started: Int

    public init(pid: Int32, folder: String?, started: Int) {
        self.pid = pid; self.folder = folder; self.started = started
    }
}
