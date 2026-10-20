import AppKit
import ApplicationServices

/// Finds the Ghostty window the sidebar should sit beside, and with
/// Accessibility permission moves that window right so the sidebar does not
/// cover it.
enum WindowTracker {
    struct GhosttyWindow: Equatable {
        var pid: Int32
        /// AppKit coordinates (origin bottom-left of the main screen).
        var frame: CGRect
        /// Core Graphics coordinates (origin top-left), as AX wants them.
        var cgFrame: CGRect
    }

    /// The frontmost on-screen Ghostty window. Bounds need no permission;
    /// only window titles would.
    static func frontGhosttyWindow(pids: Set<Int32>) -> GhosttyWindow? {
        guard !pids.isEmpty,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        for w in info {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  width > 200, height > 150 else { continue }
            let cg = CGRect(x: x, y: y, width: width, height: height)
            let cocoa = CGRect(x: x, y: mainHeight - y - height, width: width, height: height)
            return GhosttyWindow(pid: pid, frame: cocoa, cgFrame: cg)
        }
        return nil
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func askForTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Moves the window's left edge to `minX` (CG coordinates), keeping its
    /// right edge where it was. True when it moved.
    static func makeRoom(_ window: GhosttyWindow, minX: CGFloat) -> Bool {
        guard trusted, window.cgFrame.minX < minX else { return false }
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for w in windows {
            guard let frame = axFrame(w), abs(frame.minX - window.cgFrame.minX) < 3,
                  abs(frame.minY - window.cgFrame.minY) < 3, abs(frame.width - window.cgFrame.width) < 3 else { continue }
            var origin = CGPoint(x: minX, y: frame.minY)
            var size = CGSize(width: max(400, frame.maxX - minX), height: frame.height)
            if let s = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, s)
            }
            if let p = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, p)
            }
            return true
        }
        return false
    }

    /// Titles of a process's windows, via Accessibility (empty without it).
    static func windowTitles(pid: Int32) -> [String] {
        guard trusted else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { w in
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title) == .success else { return nil }
            return title as? String
        }
    }

    private static func axFrame(_ w: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &size) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }
}
