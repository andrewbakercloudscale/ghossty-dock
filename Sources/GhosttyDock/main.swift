import AppKit
import ApplicationServices
import Combine

/// Ghostty Dock can be the one Dock icon for every session: with Settings >
/// "One Dock icon" on, Ghostty runs with `macos-hidden = always`. Clicking the icon, or switching to it with
/// Cmd-Tab, brings the frontmost Ghostty window forward; the icon's badge
/// counts sessions that need you.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = DockModel()
    private var sidebar: SidebarController?
    private var badge: AnyCancellable?
    private let settings = SettingsWindow()
    private var jumpKey: HotKey?
    static let gatherNotification = Notification.Name("consulting.cloudscale.ghosttydock.gather")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = mainMenu()
        // An app that stops answering Accessibility must not freeze the sidebar.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        jumpKey = HotKey(keyCode: HotKey.jumpKeyCode, modifiers: HotKey.jumpModifiers, id: 1) { [weak self] in
            self?.model.jumpToNextWaiting()
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Self.gatherNotification, object: nil, queue: .main
        ) { [weak self] note in
            let only = (note.object as? String).flatMap { Int32($0) }
            self?.model.gatherAll(only: only)
        }
        model.start()
        sidebar = SidebarController(model: model, onSettings: { [weak self] in self?.showSettings() })
        sidebar?.start()
        badge = model.$rows.sink { rows in
            let waiting = rows.filter { $0.status == .waiting }.count
            NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
        }
        if !WindowTracker.trusted { WindowTracker.askForTrust() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !model.choosingFolder, !settings.isVisible else { return }
        showGhostty()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showGhostty()
        return false
    }

    private func showGhostty() {
        let pids = Set(GhosttyBridge.runningInstances().map(\.processIdentifier))
        if let front = WindowTracker.frontGhosttyWindow(pids: pids) {
            GhosttyBridge.activate(pid: front.pid)
        } else if let any = GhosttyBridge.runningInstances().first {
            any.activate()
        } else {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Ghostty.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func mainMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let sub = NSMenu()
        sub.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        sub.addItem(withTitle: "New Session…", action: #selector(newSession), keyEquivalent: "n").target = self
        sub.addItem(withTitle: "Move All Sessions into One Window", action: #selector(gather), keyEquivalent: "").target = self
        sub.addItem(withTitle: "Next Session That Needs You (\(HotKey.jumpLabel))", action: #selector(jump),
                    keyEquivalent: "").target = self
        sub.addItem(.separator())
        sub.addItem(withTitle: "Quit Ghostty Dock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = sub
        return menu
    }

    @objc private func newSession() { model.newSession() }
    @objc private func showSettings() { settings.show() }
    @objc private func gather() { model.gatherAll() }
    @objc private func jump() { model.jumpToNextWaiting() }
}

// One copy only: the LaunchAgent and a manual launch must not give two Dock
// icons and two sidebars. A second launch hands its request to the first:
// `GhosttyDock --gather [ghostty-pid]` moves every session (or one) into one window.
let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if let i = CommandLine.arguments.firstIndex(of: "--gather") {
    let pid = CommandLine.arguments.dropFirst(i + 1).first
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.gatherNotification, object: pid, userInfo: nil, deliverImmediately: true)
    if !others.isEmpty { exit(0) }
}
if !others.isEmpty {
    others.first?.activate()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
