import CryptoKit
import Foundation
import Security

public struct TrustedDevice: Codable, Sendable, Identifiable, Equatable {
    public var id: String { deviceId }
    public var deviceId: String
    public var name: String
    public var platform: String
    /// SHA-256 of the token, hex encoded. The token itself is only stored on the client.
    var tokenHash: String
    public var pairedAt: Date
    public var lastSeen: Date
}

/// Devices that completed pairing over the network. USB clients never need it.
public final class TrustStore: @unchecked Sendable {
    private let directory: URL
    private let url: URL
    private let lock = NSLock()
    private var devices: [String: TrustedDevice]
    private var cachedSecret: String?

    public init(directory: URL = TrustStore.defaultDirectory) {
        self.directory = directory
        url = directory.appendingPathComponent("trusted-devices.json")
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder.iso.decode([TrustedDevice].self, from: data) {
            devices = Dictionary(list.map { ($0.deviceId, $0) }, uniquingKeysWith: { $1 })
        } else {
            devices = [:]
        }
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacSecondMonitor", isDirectory: true)
    }

    /// Handed to Android devices by `adb` when the Mac launches the app. Proves that a connection
    /// arriving through the `adb reverse` tunnel comes from our app, not from another app on the
    /// device that dialled 127.0.0.1.
    public var usbSecret: String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSecret { return cachedSecret }
        let url = directory.appendingPathComponent("usb-secret")
        if let stored = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), stored.count >= 32 {
            cachedSecret = stored
            return stored
        }
        // URL-safe so it survives being passed through `adb shell am start --es`.
        let secret = Self.randomToken().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(secret.utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.session.error("Could not save the USB secret: \(error.localizedDescription, privacy: .public)")
        }
        cachedSecret = secret
        return secret
    }

    func isUSBSecret(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return Self.constantTimeEquals(token, usbSecret)
    }

    public var all: [TrustedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Checks the token presented in HELLO and refreshes `lastSeen` on success.
    func validate(deviceId: String, token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard var device = devices[deviceId],
              Self.constantTimeEquals(device.tokenHash, Self.hash(token))
        else { return false }
        device.lastSeen = Date()
        devices[deviceId] = device
        saveLocked()
        return true
    }

    /// Stores a new device and returns the token to hand to it.
    func trust(deviceId: String, name: String, platform: String) -> String {
        let token = Self.randomToken()
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        devices[deviceId] = TrustedDevice(deviceId: deviceId, name: name, platform: platform, tokenHash: Self.hash(token), pairedAt: now, lastSeen: now)
        saveLocked()
        return token
    }

    public func remove(deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        devices.removeValue(forKey: deviceId)
        saveLocked()
    }

    private func saveLocked() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.iso.encode(Array(devices.values))
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.session.error("Could not save trusted devices: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}

/// Limits pairing to one device at a time and pauses it after wrong codes, so the 6-digit code
/// can't be brute-forced by opening many connections.
final class PairingGate: @unchecked Sendable {
    enum Decision: Equatable {
        case granted
        case busy
        /// Seconds until pairing is allowed again.
        case locked(Int)
    }

    private let lock = NSLock()
    private var holder: UUID?
    private var failures = 0
    private var lockedUntil = Date.distantPast
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func begin(_ session: UUID) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        let remaining = lockedUntil.timeIntervalSince(now())
        if remaining > 0 { return .locked(Int(remaining.rounded(.up))) }
        if let holder, holder != session { return .busy }
        holder = session
        return .granted
    }

    /// `outcome`: true = paired, false = wrong codes, nil = abandoned (disconnect, timeout).
    func end(_ session: UUID, outcome: Bool?) {
        lock.lock()
        defer { lock.unlock() }
        guard holder == session else { return }
        holder = nil
        switch outcome {
        case true?:
            failures = 0
        case false?:
            failures += 1
            // 30 s, 60 s, 120 s … capped at 10 minutes.
            let delay = min(30 * pow(2, Double(failures - 1)), 600)
            lockedUntil = now().addingTimeInterval(delay)
        case nil:
            break
        }
    }
}

/// Six-digit codes shown on the Mac while a network client waits to pair.
struct PairingCode {
    static let length = 6
    static let maxAttempts = 3
    static let lifetime: TimeInterval = 120

    let value: String
    let expires: Date
    var attemptsLeft = PairingCode.maxAttempts

    init(now: Date = Date()) {
        var random: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &random)
        value = String(format: "%06u", random % 1_000_000)
        expires = now.addingTimeInterval(Self.lifetime)
    }

    var isExpired: Bool { Date() > expires }

    /// Returns true on a match; otherwise consumes an attempt.
    mutating func verify(_ candidate: String) -> Bool {
        if TrustStore.constantTimeEquals(Self.asciiDigits(candidate), value) {
            return true
        }
        attemptsLeft -= 1
        return false
    }

    /// Keyboards in some languages type other digits (Arabic-Indic ٤٨٢, full-width ４８２).
    static func asciiDigits(_ text: String) -> String {
        String(text.compactMap { character in
            guard character.isNumber, let digit = character.wholeNumberValue, (0...9).contains(digit) else { return nil }
            return Character(String(digit))
        })
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}
