// Renders the app icon and writes Resources/AppIcon.icns and docs/images/app-icon.png.
// Usage: swift scripts/make-icon.swift   (from mac/)

import AppKit

/// Draws at exactly `size` pixels (not points, so Retina screens don't double it).
func render(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824 pt body centred in 1024 with a soft shadow.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let corner = 185 * s
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let path = CGPath(roundedRect: body, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.addPath(path)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        NSColor(srgbRed: 0.11, green: 0.20, blue: 0.52, alpha: 1).cgColor,
        NSColor(srgbRed: 0.18, green: 0.42, blue: 1.00, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])

    func roundedRect(_ rect: CGRect, _ radius: CGFloat, fill: NSColor) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(fill.cgColor)
        context.fillPath()
    }

    // Mac display with stand.
    let display = CGRect(x: 190 * s, y: 380 * s, width: 460 * s, height: 310 * s)
    roundedRect(display, 34 * s, fill: .white)
    roundedRect(display.insetBy(dx: 22 * s, dy: 22 * s), 16 * s, fill: NSColor(srgbRed: 0.10, green: 0.16, blue: 0.36, alpha: 1))
    roundedRect(CGRect(x: 375 * s, y: 300 * s, width: 90 * s, height: 82 * s), 6 * s, fill: NSColor.white.withAlphaComponent(0.85))
    roundedRect(CGRect(x: 320 * s, y: 280 * s, width: 200 * s, height: 30 * s), 15 * s, fill: .white)

    // Tablet in front, showing the extended desktop.
    let tablet = CGRect(x: 540 * s, y: 250 * s, width: 300 * s, height: 400 * s)
    context.saveGState()
    context.setShadow(offset: CGSize(width: -8 * s, height: -8 * s), blur: 30 * s, color: NSColor.black.withAlphaComponent(0.4).cgColor)
    roundedRect(tablet, 44 * s, fill: NSColor(srgbRed: 0.95, green: 0.96, blue: 1, alpha: 1))
    context.restoreGState()
    let screen = tablet.insetBy(dx: 20 * s, dy: 20 * s)
    roundedRect(screen, 26 * s, fill: NSColor(srgbRed: 0.18, green: 0.42, blue: 1.00, alpha: 1))
    // Windows on the tablet screen.
    roundedRect(CGRect(x: screen.minX + 26 * s, y: screen.maxY - 120 * s, width: screen.width - 52 * s, height: 86 * s), 12 * s, fill: NSColor.white.withAlphaComponent(0.92))
    roundedRect(CGRect(x: screen.minX + 26 * s, y: screen.maxY - 236 * s, width: (screen.width - 52 * s) * 0.62, height: 86 * s), 12 * s, fill: NSColor.white.withAlphaComponent(0.6))
    // Cable dot linking the two.
    context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    context.fillEllipse(in: CGRect(x: 676 * s, y: 222 * s, width: 28 * s, height: 28 * s))
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        guard let png = render(size: pixels).representation(using: .png, properties: [:]) else { fatalError() }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try png.write(to: iconset.appendingPathComponent(name))
    }
}
// The README shows the icon too.
let png = render(size: 256).representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "../docs/images/app-icon.png"))

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try process.run()
process.waitUntilExit()
print(process.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
