// Generates every app icon from one design, so all platforms look the same:
//   macOS   mac/Resources/AppIcon.icns, docs/images/app-icon.png
//   iOS     ios/.../AppIcon.appiconset/AppIcon.png (full bleed, opaque; iOS rounds it)
//   Web     web/public/icons/*.svg and *.png (regular, maskable, apple-touch)
//   Android android/app/src/main/res/drawable/ic_launcher_{background,foreground}.xml
//
// Usage (from mac/): swift scripts/make-icon.swift

import AppKit

// MARK: Design

/// Coordinates are in "body space": the icon's square body is 824×824, origin top-left.
struct RGBA {
    var r, g, b, a: Double
    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }
    var hex: String { String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255)) }
    /// Android's #AARRGGBB.
    var argb: String { String(format: "#%02X%02X%02X%02X", Int(a * 255), Int(r * 255), Int(g * 255), Int(b * 255)) }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum Shape {
    case roundedRect(CGRect, radius: Double, RGBA, shadow: Bool = false)
    case circle(CGRect, RGBA)
}

let bodySize = 824.0
let gradientStart = RGBA.rgb(0.11, 0.20, 0.52) // bottom-left
let gradientEnd = RGBA.rgb(0.18, 0.42, 1.00)   // top-right
let white = RGBA.rgb(1, 1, 1)

/// A Mac display, and a tablet in front of it showing the extended desktop.
let artwork: [Shape] = [
    .roundedRect(CGRect(x: 90, y: 234, width: 460, height: 310), radius: 34, white),
    .roundedRect(CGRect(x: 112, y: 256, width: 416, height: 266), radius: 16, .rgb(0.10, 0.16, 0.36)),
    .roundedRect(CGRect(x: 275, y: 542, width: 90, height: 82), radius: 6, .rgb(1, 1, 1, 0.85)),
    .roundedRect(CGRect(x: 220, y: 614, width: 200, height: 30), radius: 15, white),
    .roundedRect(CGRect(x: 440, y: 274, width: 300, height: 400), radius: 44, .rgb(0.95, 0.96, 1), shadow: true),
    .roundedRect(CGRect(x: 460, y: 294, width: 260, height: 360), radius: 26, gradientEnd),
    .roundedRect(CGRect(x: 486, y: 328, width: 208, height: 86), radius: 12, .rgb(1, 1, 1, 0.92)),
    .roundedRect(CGRect(x: 486, y: 444, width: 129, height: 86), radius: 12, .rgb(1, 1, 1, 0.6)),
    .circle(CGRect(x: 576, y: 674, width: 28, height: 28), .rgb(1, 1, 1, 0.9)),
]
/// Bounding box of the artwork, for the maskable / adaptive safe zones.
let artworkBounds = CGRect(x: 90, y: 234, width: 650, height: 468)

/// How the body sits on the canvas.
struct Layout {
    var canvas: Double
    /// Body rect on the canvas (top-left origin).
    var body: CGRect
    var cornerRadius: Double
    var shadow: Bool
    /// Extra scale for the artwork around the body's centre (maskable icons keep it in the safe zone).
    var artworkScale = 1.0
    var opaque = false

    static func macOS(_ size: Double) -> Layout {
        let s = size / 1024
        return Layout(canvas: size, body: CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), cornerRadius: 185 * s, shadow: true)
    }

    /// Fills the canvas with rounded corners (web "any" icons).
    static func rounded(_ size: Double) -> Layout {
        Layout(canvas: size, body: CGRect(x: 0, y: 0, width: size, height: size), cornerRadius: size * 0.225, shadow: false)
    }

    /// Square, opaque, edge to edge (iOS and apple-touch: the system rounds it).
    static func fullBleed(_ size: Double) -> Layout {
        Layout(canvas: size, body: CGRect(x: 0, y: 0, width: size, height: size), cornerRadius: 0, shadow: false, opaque: true)
    }

    /// Artwork inside the central 80 % circle (Android / PWA maskable icons).
    static func maskable(_ size: Double) -> Layout {
        Layout(canvas: size, body: CGRect(x: 0, y: 0, width: size, height: size), cornerRadius: 0, shadow: false, artworkScale: 0.78, opaque: true)
    }

    /// Maps a body-space point to the canvas.
    func point(_ x: Double, _ y: Double) -> CGPoint {
        let s = body.width / bodySize
        let c = bodySize / 2
        return CGPoint(x: body.minX + (c + (x - c) * artworkScale) * s, y: body.minY + (c + (y - c) * artworkScale) * s)
    }

    func rect(_ r: CGRect) -> CGRect {
        let origin = point(r.minX, r.minY)
        let scale = body.width / bodySize * artworkScale
        return CGRect(x: origin.x, y: origin.y, width: r.width * scale, height: r.height * scale)
    }

    func length(_ value: Double) -> Double { value * body.width / bodySize * artworkScale }
}

// MARK: Raster (CoreGraphics)

func renderPNG(_ layout: Layout) -> Data {
    let pixels = Int(layout.canvas)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    // Draw in a top-left coordinate system like the design.
    context.translateBy(x: 0, y: layout.canvas)
    context.scaleBy(x: 1, y: -1)

    let bodyPath = CGPath(roundedRect: layout.body, cornerWidth: layout.cornerRadius, cornerHeight: layout.cornerRadius, transform: nil)
    if layout.shadow {
        context.saveGState()
        // Shadow offsets ignore the flipped transform: negative y is down.
        context.setShadow(offset: CGSize(width: 0, height: -10 * layout.canvas / 1024), blur: 28 * layout.canvas / 1024, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(bodyPath)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
        context.restoreGState()
    }
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [gradientStart.cg, gradientEnd.cg] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: layout.body.minX, y: layout.body.maxY), end: CGPoint(x: layout.body.maxX, y: layout.body.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    for shape in artwork {
        switch shape {
        case let .roundedRect(rect, radius, color, shadow):
            let r = layout.rect(rect)
            context.saveGState()
            if shadow {
                let unit = layout.length(1)
                context.setShadow(offset: CGSize(width: -8 * unit, height: -8 * unit), blur: 30 * unit, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            }
            context.addPath(CGPath(roundedRect: r, cornerWidth: layout.length(radius), cornerHeight: layout.length(radius), transform: nil))
            context.setFillColor(color.cg)
            context.fillPath()
            context.restoreGState()
        case let .circle(rect, color):
            context.setFillColor(color.cg)
            context.fillEllipse(in: layout.rect(rect))
        }
    }
    context.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    guard layout.opaque, let image = bitmap.cgImage else {
        return bitmap.representation(using: .png, properties: [:])!
    }
    // iOS app icons must not have an alpha channel.
    let flat = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    flat.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    return NSBitmapImageRep(cgImage: flat.makeImage()!).representation(using: .png, properties: [:])!
}

// MARK: Vector (SVG, Android)

func n(_ value: Double) -> String {
    let rounded = (value * 100).rounded() / 100
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

func svg(_ layout: Layout) -> String {
    let b = layout.body
    var out = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(n(layout.canvas)) \(n(layout.canvas))">
      <defs>
        <linearGradient id="bg" x1="\(n(b.minX))" y1="\(n(b.maxY))" x2="\(n(b.maxX))" y2="\(n(b.minY))" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(gradientStart.hex)"/>
          <stop offset="1" stop-color="\(gradientEnd.hex)"/>
        </linearGradient>
      </defs>
      <rect x="\(n(b.minX))" y="\(n(b.minY))" width="\(n(b.width))" height="\(n(b.height))" rx="\(n(layout.cornerRadius))" fill="url(#bg)"/>

    """
    for shape in artwork {
        switch shape {
        case let .roundedRect(rect, radius, color, _):
            let r = layout.rect(rect)
            let opacity = color.a < 1 ? " fill-opacity=\"\(n(color.a))\"" : ""
            out += "  <rect x=\"\(n(r.minX))\" y=\"\(n(r.minY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\" rx=\"\(n(layout.length(radius)))\" fill=\"\(color.hex)\"\(opacity)/>\n"
        case let .circle(rect, color):
            let r = layout.rect(rect)
            let opacity = color.a < 1 ? " fill-opacity=\"\(n(color.a))\"" : ""
            out += "  <circle cx=\"\(n(r.midX))\" cy=\"\(n(r.midY))\" r=\"\(n(r.width / 2))\" fill=\"\(color.hex)\"\(opacity)/>\n"
        }
    }
    return out + "</svg>\n"
}

/// Rounded rectangle as path data (arcs), for Android vector drawables.
func roundedRectPath(_ r: CGRect, _ radius: Double) -> String {
    let k = min(radius, r.width / 2, r.height / 2)
    return "M\(n(r.minX + k)),\(n(r.minY))h\(n(r.width - 2 * k))a\(n(k)),\(n(k)) 0,0 1,\(n(k)),\(n(k))v\(n(r.height - 2 * k))a\(n(k)),\(n(k)) 0,0 1,\(n(-k)),\(n(k))h\(n(-(r.width - 2 * k)))a\(n(k)),\(n(k)) 0,0 1,\(n(-k)),\(n(-k))v\(n(-(r.height - 2 * k)))a\(n(k)),\(n(k)) 0,0 1,\(n(k)),\(n(-k))z"
}

/// Adaptive icons are 108×108 dp; the launcher may cut everything outside the central 66 dp circle.
func androidForeground() -> String {
    let scale = 66 / hypot(artworkBounds.width, artworkBounds.height)
    let offsetX = 54 - artworkBounds.midX * scale
    let offsetY = 54 - artworkBounds.midY * scale
    func map(_ r: CGRect) -> CGRect { CGRect(x: offsetX + r.minX * scale, y: offsetY + r.minY * scale, width: r.width * scale, height: r.height * scale) }

    var paths = ""
    for shape in artwork {
        switch shape {
        case let .roundedRect(rect, radius, color, _):
            let alpha = color.a < 1 ? "\n        android:fillAlpha=\"\(n(color.a))\"" : ""
            paths += """
                <path
                    android:fillColor="\(color.hex)"\(alpha)
                    android:pathData="\(roundedRectPath(map(rect), radius * scale))" />

            """
        case let .circle(rect, color):
            let r = map(rect)
            let alpha = color.a < 1 ? "\n        android:fillAlpha=\"\(n(color.a))\"" : ""
            paths += """
                <path
                    android:fillColor="\(color.hex)"\(alpha)
                    android:pathData="\(roundedRectPath(r, r.width / 2))" />

            """
        }
    }
    return """
    <?xml version="1.0" encoding="utf-8"?>
    <!-- Generated by mac/scripts/make-icon.swift — edit the design there. -->
    <vector xmlns:android="http://schemas.android.com/apk/res/android"
        android:width="108dp"
        android:height="108dp"
        android:viewportWidth="108"
        android:viewportHeight="108">
    \(paths)</vector>

    """
}

func androidBackground() -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <!-- Generated by mac/scripts/make-icon.swift — edit the design there. -->
    <vector xmlns:android="http://schemas.android.com/apk/res/android"
        xmlns:aapt="http://schemas.android.com/aapt"
        android:width="108dp"
        android:height="108dp"
        android:viewportWidth="108"
        android:viewportHeight="108">
        <path android:pathData="M0,0h108v108h-108z">
            <aapt:attr name="android:fillColor">
                <gradient
                    android:type="linear"
                    android:startX="0"
                    android:startY="108"
                    android:endX="108"
                    android:endY="0"
                    android:startColor="\(gradientStart.argb)"
                    android:endColor="\(gradientEnd.argb)" />
            </aapt:attr>
        </path>
    </vector>

    """
}

// MARK: Output

func write(_ data: Data, _ path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    print("Wrote \(path)")
}

func write(_ text: String, _ path: String) throws {
    try write(Data(text.utf8), path)
}

// macOS .icns
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try renderPNG(.macOS(Double(base * scale))).write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns")
try write(renderPNG(.macOS(256)), "../docs/images/app-icon.png")

// iOS
try write(renderPNG(.fullBleed(1024)), "../ios/MacSecondMonitorClient/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

// Web
try write(svg(.rounded(512)), "../web/public/icons/icon.svg")
try write(svg(.maskable(512)), "../web/public/icons/icon-maskable.svg")
try write(renderPNG(.rounded(192)), "../web/public/icons/icon-192.png")
try write(renderPNG(.rounded(512)), "../web/public/icons/icon-512.png")
try write(renderPNG(.maskable(512)), "../web/public/icons/icon-maskable-512.png")
try write(renderPNG(.fullBleed(180)), "../web/public/icons/apple-touch-icon.png")

// Android
try write(androidForeground(), "../android/app/src/main/res/drawable/ic_launcher_foreground.xml")
try write(androidBackground(), "../android/app/src/main/res/drawable/ic_launcher_background.xml")
