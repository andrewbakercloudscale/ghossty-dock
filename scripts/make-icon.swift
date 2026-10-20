// Draws Ghostty Dock's icon: Ghostty's blue screen in a silver bezel, with a
// crowd of smiling ghosts, one per session, tinted with the sidebar's status
// colours. Writes a 1024px PNG to the path given.
//
//   swift scripts/make-icon.swift /tmp/icon.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: alpha)
}

func withShadow(_ color: NSColor, blur: CGFloat, y: CGFloat = 0, _ draw: () -> Void) {
    NSGraphicsContext.current?.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = color
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: y)
    s.set()
    draw()
    NSGraphicsContext.current?.restoreGraphicsState()
}

// macOS icon grid: an 824px rounded square centred in 1024.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bezel = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
withShadow(hex(0x000000, 0.45), blur: 28, y: -12) {
    NSGradient(starting: hex(0xf2f3f7), ending: hex(0x8d909c))!.draw(in: bezel, angle: -90)
}
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 34, dy: 34), xRadius: 152, yRadius: 152)
hex(0x0b0d18).setFill()
rim.fill()

// The screen: deep blue with a fine pixel grid, brighter in the middle.
let screenRect = body.insetBy(dx: 58, dy: 58)
let screen = NSBezierPath(roundedRect: screenRect, xRadius: 128, yRadius: 128)
NSGradient(colors: [hex(0x3a62ff), hex(0x1532c2), hex(0x0a1a72)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: screen, relativeCenterPosition: NSPoint(x: 0, y: 0.25))
NSGraphicsContext.current?.saveGraphicsState()
screen.addClip()
hex(0x000000, 0.18).setFill()
var g = screenRect.minX
while g < screenRect.maxX { NSRect(x: g, y: screenRect.minY, width: 2, height: screenRect.height).fill(); g += 9 }
g = screenRect.minY
while g < screenRect.maxY { NSRect(x: screenRect.minX, y: g, width: screenRect.width, height: 2).fill(); g += 9 }

/// A ghost standing on `bottom`, centred on `x`: dome, straight sides, a
/// scalloped hem, two eyes and a big smile.
func ghost(x: CGFloat, bottom: CGFloat, width w: CGFloat, tint: NSColor) {
    let h = w * 1.18
    let r = w / 2
    let left = x - r
    let path = NSBezierPath()
    path.move(to: NSPoint(x: left, y: bottom + h - r))
    path.appendArc(withCenter: NSPoint(x: x, y: bottom + h - r), radius: r, startAngle: 180, endAngle: 0, clockwise: true)
    path.line(to: NSPoint(x: left + w, y: bottom))
    let scallops = 4
    let sw = w / CGFloat(scallops)
    for i in 0..<scallops {
        let x0 = left + w - CGFloat(i) * sw
        path.curve(to: NSPoint(x: x0 - sw, y: bottom),
                   controlPoint1: NSPoint(x: x0 - sw * 0.25, y: bottom + sw * 0.55),
                   controlPoint2: NSPoint(x: x0 - sw * 0.75, y: bottom + sw * 0.55))
    }
    path.close()

    withShadow(tint.withAlphaComponent(0.85), blur: w * 0.28) {
        NSGradient(starting: NSColor.white, ending: tint)!.draw(in: path, angle: -90)
    }

    let eyeW = w * 0.13, eyeH = w * 0.19, eyeY = bottom + h * 0.56
    hex(0x11163a).setFill()
    for dx in [-w * 0.19, w * 0.19] {
        NSBezierPath(ovalIn: NSRect(x: x + dx - eyeW / 2, y: eyeY, width: eyeW, height: eyeH)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x + dx - eyeW * 0.1, y: eyeY + eyeH * 0.55, width: eyeW * 0.4, height: eyeW * 0.4)).fill()
        hex(0x11163a).setFill()
    }

    hex(0xff8fb1, 0.55).setFill()
    for dx in [-w * 0.31, w * 0.31] {
        NSBezierPath(ovalIn: NSRect(x: x + dx - w * 0.07, y: eyeY - w * 0.08, width: w * 0.14, height: w * 0.08)).fill()
    }

    let smile = NSBezierPath()
    smile.appendArc(withCenter: NSPoint(x: x, y: eyeY + w * 0.02), radius: w * 0.17, startAngle: 205, endAngle: 335)
    smile.lineWidth = w * 0.045
    smile.lineCapStyle = .round
    hex(0x11163a).setStroke()
    smile.stroke()
}

// Back row first, so the front ghosts overlap them.
ghost(x: 300, bottom: 470, width: 170, tint: hex(0xcba6f7))   // idle
ghost(x: 724, bottom: 470, width: 170, tint: hex(0x89b4fa))   // finished
ghost(x: 512, bottom: 520, width: 150, tint: hex(0x94e2d5))   // shell
ghost(x: 340, bottom: 230, width: 230, tint: hex(0xa6e3a1))   // running
ghost(x: 684, bottom: 230, width: 230, tint: hex(0xfab387))   // needs you
ghost(x: 512, bottom: 180, width: 290, tint: hex(0xdfe8ff))   // front and centre
NSGraphicsContext.current?.restoreGraphicsState()

// Glass glare across the top of the screen.
NSGraphicsContext.current?.saveGraphicsState()
screen.addClip()
let glare = NSBezierPath(ovalIn: NSRect(x: screenRect.minX - 120, y: screenRect.midY + 120,
                                         width: screenRect.width + 240, height: screenRect.height))
NSGradient(starting: hex(0xffffff, 0.16), ending: hex(0xffffff, 0))!.draw(in: glare, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: out))
