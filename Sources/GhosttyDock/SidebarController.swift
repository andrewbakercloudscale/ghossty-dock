import AppKit
import SwiftUI

/// A borderless panel glued to the left edge of the frontmost Ghostty window,
/// shown only while Ghostty (or the sidebar itself) is the active app.
final class SidebarController {
    static let width: CGFloat = 230

    private let model: DockModel
    private let onSettings: () -> Void
    private let panel: NSPanel
    private var timer: Timer?
    /// The last window frame we moved, so a window is moved once per change
    /// of its frame rather than fought over every tick.
    private var lastNudged: CGRect?
    private var trusted = WindowTracker.trusted

    init(model: DockModel, onSettings: @escaping () -> Void) {
        self.model = model
        self.onSettings = onSettings
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        setContent()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.track() }
        track()
    }

    private func setContent() {
        let view = SidebarView(model: model, trusted: trusted,
                               onTrust: { WindowTracker.askForTrust() },
                               onSettings: onSettings,
                               onDrag: { [weak self] dx, dy in self?.drag(dx: dx, dy: dy) },
                               onQuit: { NSApp.terminate(nil) })
        let host = NSHostingView(rootView: view)
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        panel.contentView = host
    }

    /// Dragging the sidebar's header drags the Ghostty window with it, so
    /// the two move as one window.
    private func drag(dx: CGFloat, dy: CGFloat) {
        let pids = Set(GhosttyBridge.runningInstances().map(\.processIdentifier))
        guard let win = WindowTracker.frontGhosttyWindow(pids: pids) else { return }
        WindowTracker.move(win, dx: dx, dy: dy)
        lastNudged = nil
        track()
    }

    private func track() {
        if WindowTracker.trusted != trusted {
            trusted = WindowTracker.trusted
            setContent()
        }
        let pids = Set(GhosttyBridge.runningInstances().map(\.processIdentifier))
        let front = NSWorkspace.shared.frontmostApplication
        let active = front?.bundleIdentifier == GhosttyBridge.bundleId
            || front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || panel.isKeyWindow
        guard active, let win = WindowTracker.frontGhosttyWindow(pids: pids) else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }

        let screen = NSScreen.screens.first { $0.frame.intersects(win.frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? win.frame
        let gap: CGFloat = 4
        if win.frame.minX - Self.width - gap < visible.minX, SettingsStore.makeRoom, lastNudged != win.cgFrame {
            lastNudged = win.cgFrame
            if WindowTracker.makeRoom(win, minX: visible.minX + Self.width + gap) { return }
        }

        let x = max(visible.minX, win.frame.minX - Self.width - gap)
        let frame = NSRect(x: x, y: win.frame.minY, width: Self.width, height: win.frame.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
