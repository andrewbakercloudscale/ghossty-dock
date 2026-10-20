// Draws Ghostty Dock's icon: a dark window with a sidebar of status-coloured
// rows beside a terminal prompt. Writes a 1024px PNG to the path given.
//
//   swift scripts/make-icon.swift /tmp/icon.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

// macOS icon grid: an 824px rounded square centred in 1024.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGradient(starting: hex(0x2a2b3d), ending: hex(0x11111b))!.draw(in: shape, angle: -90)

// Sidebar.
NSGraphicsContext.current?.saveGraphicsState()
shape.addClip()
hex(0x181825).setFill()
NSRect(x: 100, y: 100, width: 300, height: 824).fill()
NSGraphicsContext.current?.restoreGraphicsState()

let rows: [(UInt32, CGFloat)] = [(0xfab387, 1), (0xa6e3a1, 0.8), (0xa6e3a1, 0.65), (0x89b4fa, 0.75), (0xcba6f7, 0.55)]
for (i, row) in rows.enumerated() {
    let y = 760 - CGFloat(i) * 128
    if i == 0 {
        hex(0x313244).setFill()
        NSBezierPath(roundedRect: NSRect(x: 128, y: y - 34, width: 248, height: 92), xRadius: 22, yRadius: 22).fill()
    }
    hex(row.0).setFill()
    NSBezierPath(ovalIn: NSRect(x: 156, y: y - 2, width: 28, height: 28)).fill()
    hex(0xcdd6f4).withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 206, y: y + 2, width: 140 * row.1, height: 20), xRadius: 10, yRadius: 10).fill()
}

// Prompt: ">_" in the terminal pane.
let prompt = NSAttributedString(string: ">_", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 250, weight: .bold),
    .foregroundColor: hex(0xcdd6f4),
])
prompt.draw(at: NSPoint(x: 455, y: 380))

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
