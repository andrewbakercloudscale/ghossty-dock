import AppKit
import SwiftUI
import DockCore

/// The settings, each read from where it actually lives: Ghostty's config for
/// the Dock icons, the LaunchAgent file for login, UserDefaults for the rest.
final class SettingsStore: ObservableObject {
    static let makeRoomKey = "makeRoom"
    static var makeRoom: Bool { UserDefaults.standard.object(forKey: makeRoomKey) as? Bool ?? true }

    @Published var hideGhosttyIcons: Bool { didSet { if hideGhosttyIcons != oldValue { applyHidden() } } }
    @Published var makeRoom: Bool { didSet { UserDefaults.standard.set(makeRoom, forKey: Self.makeRoomKey) } }
    @Published var startAtLogin: Bool { didSet { if startAtLogin != oldValue { applyLogin() } } }
    @Published private(set) var error: String?

    static let agentLabel = "consulting.cloudscale.ghosttydock"
    static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    init() {
        let text = (try? String(contentsOf: GhosttyConfig.path, encoding: .utf8)) ?? ""
        hideGhosttyIcons = GhosttyConfig.isHidden(text)
        makeRoom = Self.makeRoom
        startAtLogin = FileManager.default.fileExists(atPath: Self.agentPlist.path)
    }

    /// Writes Ghostty's config, then has every running Ghostty reload it
    /// (SIGUSR2), so the Dock icons go or come back without a restart.
    private func applyHidden() {
        let url = GhosttyConfig.path
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try GhosttyConfig.setHidden(hideGhosttyIcons, in: text).write(to: url, atomically: true, encoding: .utf8)
            error = nil
        } catch {
            self.error = "Could not write \(url.path): \(error.localizedDescription)"
            return
        }
        for app in GhosttyBridge.runningInstances() { kill(app.processIdentifier, SIGUSR2) }
    }

    private func applyLogin() {
        if startAtLogin {
            let exe = Bundle.main.executablePath ?? ""
            let plist: [String: Any] = [
                "Label": Self.agentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive",
            ]
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try FileManager.default.createDirectory(at: Self.agentPlist.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: Self.agentPlist, options: .atomic)
                error = nil
            } catch {
                self.error = "Could not write \(Self.agentPlist.path): \(error.localizedDescription)"
            }
            // Not bootstrapped now: that would start a second copy of this app.
            // launchd loads it at the next login.
        } else {
            // bootout would stop this running copy too, so only the file goes;
            // the agent is not loaded at the next login.
            try? FileManager.default.removeItem(at: Self.agentPlist)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("One Dock icon for all sessions", isOn: $store.hideGhosttyIcons)
                Text("Hides Ghostty's own Dock icons, so only Ghostty Dock's shows. Ghostty also leaves Cmd-Tab: switch to Ghostty Dock instead, which brings the front Ghostty window forward. Sets macos-hidden = always in \(GhosttyConfig.path.path).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Move Ghostty aside to make room for the sidebar", isOn: $store.makeRoom)
                Text(WindowTracker.trusted
                     ? "When a Ghostty window reaches the left edge of the screen, it is moved right so the sidebar does not cover it."
                     : "Needs Accessibility permission (System Settings > Privacy & Security > Accessibility). Without it the sidebar covers the window's left edge.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Start Ghostty Dock at login", isOn: $store.startAtLogin)
                LabeledContent("Next session that needs you", value: HotKey.jumpLabel)
            }
            if let error = store.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

final class SettingsWindow {
    private var window: NSWindow?
    private let store = SettingsStore()

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            w.title = "Ghostty Dock Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
