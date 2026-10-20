import AppKit
import DockCore

/// Everything that talks to Ghostty: AppleScript for the shared instance's
/// tabs, NSWorkspace for the separate processes, and the opener script.
enum GhosttyBridge {
    static let bundleId = "com.mitchellh.ghostty"

    static func runningInstances() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleId && !$0.isTerminated }
    }

    static func instances() -> [GhosttyInstance] {
        runningInstances().map { app in
            let pid = app.processIdentifier
            let started = Int(app.launchDate?.timeIntervalSince1970 ?? 0)
            return GhosttyInstance(pid: pid, folder: launcherFolder(arguments: processArguments(pid)), started: started)
        }
    }

    /// The `tab` keyword inside `tell application "Ghostty"` is Ghostty's tab
    /// class, not the tab character, hence TB.
    static let snapshotScript = """
    set TB to character id 9
    tell application "Ghostty"
        set out to ((frontmost) as text) & linefeed
        set fw to ""
        try
            set fw to id of front window
        end try
        set out to out & fw & linefeed
        set wi to 0
        repeat with w in windows
            set wi to wi + 1
            set wid to id of w
            set sel to ""
            try
                set sel to id of selected tab of w
            end try
            repeat with t in tabs of w
                set tid to id of t
                set tn to ""
                try
                    set tn to name of t
                end try
                if tn is missing value then set tn to ""
                set ix to index of t
                repeat with term in terminals of t
                    set wd to ""
                    try
                        set wd to working directory of term
                    end try
                    if wd is missing value then set wd to ""
                    set out to out & wid & TB & wi & TB & tid & TB & ix & TB & ((tid is sel) as text) & TB & (id of term) & TB & wd & TB & tn & linefeed
                end repeat
            end repeat
        end repeat
        return out
    end tell
    """

    /// Nil when Ghostty is not running (asking would launch it) or did not answer.
    static func snapshot() -> GhosttySnapshot? {
        guard !runningInstances().isEmpty else { return nil }
        guard let out = osascript(snapshotScript, timeout: 4) else { return nil }
        return parseSnapshot(out)
    }

    static func focus(terminal id: String) {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        _ = osascript("""
        tell application "Ghostty"
            focus (first terminal whose id is "\(safe)")
            activate
        end tell
        """, timeout: 4)
    }

    static func activate(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    static var openerPath: String {
        NSHomeDirectory() + "/.local/bin/ghostty-dock-open"
    }

    static var defaultLauncher: String {
        NSHomeDirectory() + "/.local/bin/ghostty-claude-launcher"
    }

    static func openSession(folder: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: openerPath)
        if FileManager.default.isExecutableFile(atPath: defaultLauncher) {
            p.arguments = [defaultLauncher, folder]
        } else {
            p.arguments = ["--shell", folder]
        }
        try? p.run()
    }

    @discardableResult
    static func osascript(_ script: String, timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        input.fileHandleForWriting.write(script.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()

        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global().async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// argv of another process, via KERN_PROCARGS2: argc, the executable
    /// path, padding, then the NUL-separated arguments.
    static func processArguments(_ pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // executable path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}
