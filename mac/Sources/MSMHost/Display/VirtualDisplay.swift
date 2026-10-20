import CGVirtualDisplayKit
import CoreGraphics
import Foundation
import MSMProtocol

public enum VirtualDisplayError: Error, LocalizedError {
    case unsupported
    case creationFailed
    case settingsRejected

    public var errorDescription: String? {
        switch self {
        case .unsupported: L10n.tr("error.virtualDisplay.unsupported")
        case .creationFailed: L10n.tr("error.virtualDisplay.creationFailed")
        case .settingsRejected: L10n.tr("error.virtualDisplay.settingsRejected")
        }
    }
}

/// A macOS display backed by a client's screen. macOS treats it like a real monitor
/// until this object is released.
public final class VirtualDisplay: @unchecked Sendable {
    /// Vendor ID reported to macOS ("MS").
    static let vendorID: UInt32 = 0x4D53
    static let productID: UInt32 = 0x0001

    /// Point-size scale factors offered in System Settings, relative to the client's
    /// native HiDPI size (pixels / 2). 1.0 is the default and sharpest.
    static let scaleFactors: [Double] = [0.8, 1.0, 1.125, 1.25, 1.5]

    public let displayID: CGDirectDisplayID
    public let pixelWidth: Int
    public let pixelHeight: Int
    private let display: MSMVirtualDisplay

    public static var isSupported: Bool { MSMVirtualDisplay.isSupported }

    /// - Parameters:
    ///   - name: Shown in System Settings → Displays.
    ///   - identity: Stable per client device so macOS remembers the arrangement.
    public init(name: String, client: DisplayInfo, identity: String, refreshRate: Double, onTermination: (@Sendable () -> Void)? = nil) throws {
        guard MSMVirtualDisplay.isSupported else { throw VirtualDisplayError.unsupported }

        let width = max(640, client.width)
        let height = max(480, client.height)
        let modes = Self.modes(width: width, height: height, refreshRate: refreshRate)
        let maxWidth = modes.map { Int($0.width) }.max() ?? width
        let maxHeight = modes.map { Int($0.height) }.max() ?? height

        // macOS derives the default scale from the physical size.
        let dpi = client.dpi > 50 ? client.dpi : 220
        let size = CGSize(width: Double(width) / dpi * 25.4, height: Double(height) / dpi * 25.4)
        let serial = max(1, UInt32.fnv1a(identity))

        guard let display = MSMVirtualDisplay(
            name: name,
            maxPixelsWide: UInt32(maxWidth),
            maxPixelsHigh: UInt32(maxHeight),
            sizeInMillimeters: size,
            vendorID: Self.vendorID,
            productID: Self.productID,
            serialNum: serial,
            queue: DispatchQueue.main,
            terminationHandler: onTermination
        ) else {
            throw VirtualDisplayError.creationFailed
        }
        guard display.apply(modes, hiDPI: true) else {
            throw VirtualDisplayError.settingsRejected
        }

        self.display = display
        displayID = display.displayID
        pixelWidth = width
        pixelHeight = height
        Log.display.info("Created virtual display \(display.displayID) \(width)x\(height) for \(name, privacy: .public)")
    }

    deinit {
        Log.display.info("Releasing virtual display \(self.displayID)")
    }

    /// Global bounds in points (changes when the user rearranges displays).
    public var bounds: CGRect {
        CGDisplayBounds(displayID)
    }

    /// Mode list in pixels. With HiDPI each mode also appears at half size in points,
    /// so `width x height` shows up as "looks like width/2 x height/2".
    static func modes(width: Int, height: Int, refreshRate: Double) -> [MSMVirtualDisplayMode] {
        var seen = Set<[Int]>()
        var result: [MSMVirtualDisplayMode] = []
        for factor in scaleFactors {
            let modeWidth = Int((Double(width) * factor / 2).rounded()) * 2
            let modeHeight = Int((Double(height) * factor / 2).rounded()) * 2
            guard seen.insert([modeWidth, modeHeight]).inserted else { continue }
            result.append(MSMVirtualDisplayMode(width: UInt(modeWidth), height: UInt(modeHeight), refreshRate: refreshRate))
        }
        return result
    }
}
