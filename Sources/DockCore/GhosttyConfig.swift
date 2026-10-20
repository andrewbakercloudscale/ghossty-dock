import Foundation

/// Edits Ghostty's config for the "one Dock icon" setting: `macos-hidden =
/// always` takes Ghostty out of the Dock and Cmd-Tab, leaving Ghostty Dock's
/// icon as the only one.
public enum GhosttyConfig {
    static let marker = "# ghostty-dock: one Dock icon for all sessions (Ghostty Dock > Settings)"

    /// ~/.config/ghostty/config, or config.ghostty beside it when only that exists.
    public static var path: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ghostty")
        let plain = dir.appendingPathComponent("config")
        let named = dir.appendingPathComponent("config.ghostty")
        if !FileManager.default.fileExists(atPath: plain.path), FileManager.default.fileExists(atPath: named.path) {
            return named
        }
        return plain
    }

    /// Whether the last macos-hidden line (Ghostty's last one wins) says always.
    public static func isHidden(_ text: String) -> Bool {
        var hidden = false
        for line in text.components(separatedBy: "\n") {
            if let v = value(of: "macos-hidden", in: line) { hidden = (v == "always") }
        }
        return hidden
    }

    /// The config with every macos-hidden line removed, plus ours when `on`.
    public static func setHidden(_ on: Bool, in text: String) -> String {
        var lines = text.components(separatedBy: "\n").filter {
            $0 != marker && value(of: "macos-hidden", in: $0) == nil
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if on { lines += ["", marker, "macos-hidden = always"] }
        return lines.joined(separator: "\n") + "\n"
    }

    static func value(of key: String, in line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        guard t[..<eq].trimmingCharacters(in: .whitespaces) == key else { return nil }
        return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }
}
