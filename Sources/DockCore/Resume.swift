import Foundation

/// Rebuilding a running claude's command line so the same conversation can be
/// reopened in a tab of the shared Ghostty: same flags, but resuming the
/// session rather than pinning or continuing one.
public enum Resume {
    /// Flags that pick the conversation, with whether each takes a value.
    static let sessionFlags: [String: Bool] = [
        "--session-id": true, "--resume": true, "-r": true, "--continue": false, "-c": false,
        "--fork-session": false,
    ]

    /// `arguments` is claude's argv without argv[0].
    public static func arguments(from arguments: [String], sessionId: String?) -> [String] {
        var out: [String] = []
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            let name = a.split(separator: "=", maxSplits: 1).first.map(String.init) ?? a
            if let takesValue = sessionFlags[name] {
                // "--resume" may also appear bare (the picker); only skip a value that is not a flag.
                if takesValue && !a.contains("="), i + 1 < arguments.count, !arguments[i + 1].hasPrefix("-") {
                    i += 1
                }
                i += 1
                continue
            }
            out.append(a)
            i += 1
        }
        if let id = sessionId, !id.isEmpty {
            return ["--resume", id] + out
        }
        return ["--continue"] + out
    }

    /// The value of `--session-id` in claude's argv, if it was pinned.
    public static func pinnedSessionId(_ arguments: [String]) -> String? {
        for (i, a) in arguments.enumerated() {
            if a == "--session-id", i + 1 < arguments.count { return arguments[i + 1] }
            if a.hasPrefix("--session-id=") { return String(a.dropFirst("--session-id=".count)) }
        }
        return nil
    }

    /// Claude Code keeps a folder's transcripts under ~/.claude/projects/<this>.
    public static func projectDirName(_ path: String) -> String {
        String(path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
