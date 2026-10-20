import CoreMedia
import Foundation
import os

enum Log {
    static let subsystem = "com.macsecondmonitor.host"
    static let display = Logger(subsystem: subsystem, category: "display")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let encoder = Logger(subsystem: subsystem, category: "encoder")
    static let net = Logger(subsystem: subsystem, category: "net")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let usb = Logger(subsystem: subsystem, category: "usb")
}

/// Monotonic host clock in microseconds. Same time base as `CMClockGetHostTimeClock`,
/// which ScreenCaptureKit uses for frame timestamps.
public enum HostClock {
    public static func nowMicros() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000
    }

    static func micros(_ time: CMTime) -> UInt64 {
        guard time.isNumeric else { return nowMicros() }
        return UInt64(max(0, CMTimeGetSeconds(time)) * 1_000_000)
    }
}

/// Thread-safe box for a value shared between queues.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value {
        withLock { $0 }
    }
}

/// Localized strings from `Resources/Localizable.xcstrings`.
public enum L10n {
    /// Inside the .app the SwiftPM resource bundle is copied into Contents/Resources;
    /// during development `Bundle.module` finds it next to the build products.
    public static let bundle: Bundle = {
        let bundleName = "MacSecondMonitor_MSMHost.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(bundleName),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    public static func tr(_ key: String) -> String {
        if let catalog {
            return catalog[key] ?? key
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Languages translated in the catalog; English (the source language) first.
    public static let supportedLanguages = ["en", "tr", "de", "es", "fr", "it", "pt-BR", "ru", "zh-Hans", "ja", "ko", "ar"]

    /// `swift build` copies the String Catalog without compiling it (Xcode compiles it into
    /// .lproj tables). In that case the catalog is read directly for the preferred language.
    private static let catalog: [String: String]? = {
        guard bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") == nil,
              let url = bundle.url(forResource: "Localizable", withExtension: "xcstrings"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = root["strings"] as? [String: [String: Any]]
        else { return nil }

        let language = Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: Locale.preferredLanguages).first ?? "en"
        var result: [String: String] = [:]
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]]
            let unit = (localizations?[language] ?? localizations?["en"])?["stringUnit"] as? [String: Any]
            if let value = unit?["value"] as? String {
                result[key] = value
            }
        }
        return result
    }()

    /// Arguments are formatted without locale grouping (ports, codes and counts read better as-is).
    public static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), arguments: arguments)
    }
}

extension UInt32 {
    /// Stable 32-bit FNV-1a hash, used to derive display serial numbers from device IDs.
    static func fnv1a(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}
