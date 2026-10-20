import Foundation

/// Reads and tidies ~/.local/state/ghostty-dock, the only place the hook, the
/// opener and the app share anything.
public struct StateFiles {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static var standard: StateFiles {
        if let env = ProcessInfo.processInfo.environment["GHOSTTY_DOCK_STATE"], !env.isEmpty {
            return StateFiles(root: URL(fileURLWithPath: env))
        }
        return StateFiles(root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/ghostty-dock"))
    }

    public var sessionsDir: URL { root.appendingPathComponent("sessions") }
    public var tabsDir: URL { root.appendingPathComponent("tabs") }
    public var lineageDir: URL { root.appendingPathComponent("lineage") }
    public var seenFile: URL { root.appendingPathComponent("seen.json") }

    public func sessions() -> [SessionRecord] { decodeAll(sessionsDir) }
    public func tabs() -> [TabRecord] { decodeAll(tabsDir) }

    public func seen() -> [String: Int] {
        guard let data = try? Data(contentsOf: seenFile),
              let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return map
    }

    public func saveSeen(_ map: [String: Int]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: seenFile, options: .atomic)
    }

    /// Removes rows whose claude process has gone (a crash or a closed window
    /// sends no SessionEnd), tab records for terminals Ghostty no longer has,
    /// and lineage cache entries for dead processes. Returns the live sessions.
    public func prune(sessions: [SessionRecord], liveTerminals: Set<String>?, isAlive: (Int32) -> Bool) -> [SessionRecord] {
        let fm = FileManager.default
        var live: [SessionRecord] = []
        for s in sessions {
            if let pid = s.claudePid, !isAlive(pid) {
                try? fm.removeItem(at: sessionsDir.appendingPathComponent(s.key + ".json"))
            } else {
                live.append(s)
            }
        }
        if let liveTerminals {
            let now = Int(Date().timeIntervalSince1970)
            for t in tabs() where !liveTerminals.contains(t.terminalId) && now - t.created > 30 {
                try? fm.removeItem(at: tabsDir.appendingPathComponent(t.dockTabId + ".json"))
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: lineageDir.path)) ?? [] {
            if let pid = Int32(name), !isAlive(pid) {
                try? fm.removeItem(at: lineageDir.appendingPathComponent(name))
            }
        }
        return live
    }

    private func decodeAll<T: Decodable>(_ dir: URL) -> [T] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
    }
}

/// Parses the AppleScript snapshot (see GhosttyBridge.snapshotScript): line 1
/// frontmost, line 2 front window id, then one tab-separated line per terminal.
public func parseSnapshot(_ text: String) -> GhosttySnapshot {
    var lines = text.components(separatedBy: "\n")
    guard lines.count >= 2 else { return .empty }
    let frontmost = lines.removeFirst().trimmingCharacters(in: .whitespaces) == "true"
    let frontWindow = lines.removeFirst().trimmingCharacters(in: .whitespaces)
    var terminals: [GhosttyTerminal] = []
    for line in lines where !line.isEmpty {
        let f = line.components(separatedBy: "\t")
        guard f.count >= 8 else { continue }
        terminals.append(GhosttyTerminal(
            windowId: f[0], windowIndex: Int(f[1]) ?? 0, tabId: f[2], tabIndex: Int(f[3]) ?? 0,
            tabSelected: f[4] == "true", terminalId: f[5], workingDirectory: f[6],
            tabName: f[7...].joined(separator: " ")))
    }
    return GhosttySnapshot(frontmost: frontmost, frontWindowId: frontWindow.isEmpty ? nil : frontWindow,
                           terminals: terminals)
}

/// The folder a launcher was given, from a Ghostty process's arguments
/// ("... -e <launcher> <folder>").
public func launcherFolder(arguments: [String]) -> String? {
    guard let e = arguments.firstIndex(of: "-e"), arguments.count > e + 2 else { return nil }
    return arguments[e + 2]
}
