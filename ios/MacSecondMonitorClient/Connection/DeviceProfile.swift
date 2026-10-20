import Foundation
import MSMProtocol
import UIKit

/// What this device tells the host in HELLO.
@MainActor
enum DeviceProfile {
    static let platform = "ios"
    /// VideoToolbox decodes both; the host picks.
    static let codecs = ["hevc", "h264"]

    static var deviceId: String {
        let key = "device.id"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func hello(display: DisplayInfo, token: String?) -> Hello {
        Hello(
            deviceId: deviceId,
            deviceName: UIDevice.current.name,
            platform: platform,
            appVersion: appVersion,
            display: display,
            codecs: codecs,
            locale: Locale.preferredLanguages.first ?? Locale.current.identifier,
            token: token
        )
    }

    /// The full-screen stream view in the current orientation, measured from the key window.
    static func currentDisplay() -> DisplayInfo? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else { return nil }
        let screen = scene.screen
        let size = pixelSize(points: window.bounds.size, scale: screen.scale)
        return DisplayInfo(
            width: Int(size.width),
            height: Int(size.height),
            dpi: pixelsPerInch,
            refreshRate: Double(screen.maximumFramesPerSecond)
        )
    }

    /// Pixels for a size in points, rounded down to even numbers (H.264 / HEVC use 4:2:0).
    nonisolated static func pixelSize(points: CGSize, scale: CGFloat) -> CGSize {
        func even(_ value: CGFloat) -> CGFloat {
            CGFloat(Int((value * scale).rounded()) / 2 * 2)
        }
        return CGSize(width: even(points.width), height: even(points.height))
    }

    /// Best effort: iOS has no API for the panel density.
    static var pixelsPerInch: Double {
        if let known = knownPixelsPerInch[modelIdentifier] { return known }
        return UIDevice.current.userInterfaceIdiom == .pad ? 264 : 460
    }

    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Devices that differ from the 264 (iPad) / 460 (iPhone) defaults.
    private static let knownPixelsPerInch: [String: Double] = [
        // iPad mini 5, 6, A17 Pro
        "iPad11,1": 326, "iPad11,2": 326, "iPad14,1": 326, "iPad14,2": 326, "iPad16,1": 326, "iPad16,2": 326,
        // iPhone 8, SE 2, SE 3, XR, 11
        "iPhone10,1": 326, "iPhone10,4": 326, "iPhone12,8": 326, "iPhone14,6": 326, "iPhone11,8": 326, "iPhone12,1": 326,
        // iPhone 8 Plus
        "iPhone10,2": 401, "iPhone10,5": 401,
        // iPhone 12 mini, 13 mini
        "iPhone13,1": 476, "iPhone14,4": 476,
        // iPhone X, XS, XS Max, 11 Pro, 11 Pro Max, 12 Pro Max, 13 Pro Max, 14 Plus
        "iPhone10,3": 458, "iPhone10,6": 458, "iPhone11,2": 458, "iPhone11,4": 458, "iPhone11,6": 458,
        "iPhone12,3": 458, "iPhone12,5": 458, "iPhone13,4": 458, "iPhone14,3": 458, "iPhone14,8": 458,
    ]
}
