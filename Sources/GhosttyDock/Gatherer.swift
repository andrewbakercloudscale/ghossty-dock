import AppKit
import DockCore

/// Moves sessions that run in their own Ghostty app into tabs of the shared
/// window: the old claude is asked to quit (SIGTERM), its Ghostty app is
/// closed, and the same conversation is reopened in a new tab with
/// `claude --resume <id>` and the flags it was started with.
///
/// A session that is working or waiting for an answer is never touched; it
/// is moved once it is idle.
enum Gatherer {
    enum Outcome: Equatable {
        case moved(String)
        case busy(String)
        case skipped(String, String)
    }

    /// The idle test for a session the hook has not reported: its transcript
    /// has not been written for this long.
    static let quietFor: TimeInterval = 90

    static func gather(instance: GhosttyInstance, session: SessionRecord?) -> Outcome {
        let name = session?.name ?? instance.folder.map { ($0 as NSString).lastPathComponent } ?? "pid \(instance.pid)"
        guard instance.folder != nil else {
            return .skipped(name, "this Ghostty was not started for one session, so it is left alone")
        }
        let table = ProcessTable.read()
        let claudes = table.descendants(of: instance.pid).filter { table.name($0) == "claude" }
        guard claudes.count == 1, let claude = claudes.first else {
            return .skipped(name, claudes.isEmpty ? "no Claude Code running in it" : "more than one Claude Code in it")
        }
        let argv = GhosttyBridge.processArguments(claude)
        let exe = executablePath(claude) ?? "claude"
        let flags = Array(argv.dropFirst())
        let sessionId = session?.sessionId.isEmpty == false ? session?.sessionId : Resume.pinnedSessionId(flags)
        let folder = session?.project.isEmpty == false ? session!.project : instance.folder!

        if let s = session, s.status == "running" || s.status == "waiting" { return .busy(name) }
        if session == nil, recentlyWritten(folder: folder, sessionId: sessionId) { return .busy(name) }

        var command = ([exe] + Resume.arguments(from: flags, sessionId: sessionId)).map(Resume.shellQuote)
            .joined(separator: " ")
        if let parent = table.parent(claude), table.name(parent) == "caffeinate" {
            let caf = GhosttyBridge.processArguments(parent)
            let opts = caf.dropFirst().prefix { $0.hasPrefix("-") }
            command = (["/usr/bin/caffeinate"] + opts).map(Resume.shellQuote).joined(separator: " ") + " " + command
        }

        kill(claude, SIGTERM)
        guard waitForExit(claude, seconds: 8) else {
            return .skipped(name, "Claude Code did not quit when asked, so it was left running")
        }
        if let app = NSRunningApplication(processIdentifier: instance.pid) {
            app.forceTerminate()
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: GhosttyBridge.openerPath)
        p.arguments = ["--command", command, folder]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return .skipped(name, "could not run \(GhosttyBridge.openerPath): \(error.localizedDescription)")
        }
        return p.terminationStatus == 0 ? .moved(name) : .skipped(name, "the new tab did not open")
    }

    static func recentlyWritten(folder: String, sessionId: String?) -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/" + Resume.projectDirName(folder))
        let files: [URL]
        if let id = sessionId {
            files = [dir.appendingPathComponent(id + ".jsonl")]
        } else {
            files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
        let now = Date()
        return files.contains { url in
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return m.map { now.timeIntervalSince($0) < quietFor } ?? false
        }
    }

    static func waitForExit(_ pid: Int32, seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !isAlive(pid) { return true }
            usleep(100_000)
        }
        return !isAlive(pid)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}

/// pid -> (parent, executable name), from one `ps`.
struct ProcessTable {
    private var entries: [Int32: (ppid: Int32, name: String)] = [:]

    static func read() -> ProcessTable {
        var t = ProcessTable()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,ppid=,comm="]
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return t }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            t.entries[pid] = (ppid, (String(f[2]) as NSString).lastPathComponent)
        }
        return t
    }

    func name(_ pid: Int32) -> String? { entries[pid]?.name }
    func parent(_ pid: Int32) -> Int32? { entries[pid]?.ppid }

    func descendants(of root: Int32) -> [Int32] {
        var children: [Int32: [Int32]] = [:]
        for (pid, e) in entries { children[e.ppid, default: []].append(pid) }
        var out: [Int32] = [], stack = [root]
        while let p = stack.popLast() {
            for c in children[p] ?? [] { out.append(c); stack.append(c) }
        }
        return out
    }
}
