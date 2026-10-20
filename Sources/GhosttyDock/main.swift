import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = DockModel()
    private var sidebar: SidebarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        sidebar = SidebarController(model: model)
        sidebar?.start()
        if !WindowTracker.trusted { WindowTracker.askForTrust() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
