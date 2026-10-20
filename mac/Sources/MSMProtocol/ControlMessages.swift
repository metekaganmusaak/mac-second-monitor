import Foundation

/// Physical properties of the client's screen (or of the view that shows the stream).
public struct DisplayInfo: Codable, Sendable, Equatable {
    /// Size in pixels, in the orientation the client will show the stream.
    public var width: Int
    public var height: Int
    /// Physical pixels per inch; 0 if unknown.
    public var dpi: Double
    /// Panel refresh rate in Hz.
    public var refreshRate: Double

    public init(width: Int, height: Int, dpi: Double, refreshRate: Double) {
        self.width = width
        self.height = height
        self.dpi = dpi
        self.refreshRate = refreshRate
    }
}

/// HELLO (client → host): first message on every connection.
public struct Hello: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var deviceId: String
    public var deviceName: String
    /// `android`, `ios` or `web`.
    public var platform: String
    public var appVersion: String
    public var display: DisplayInfo
    /// Supported codecs in order of preference: `h264`, `hevc`.
    public var codecs: [String]
    public var locale: String?
    /// Token received in an earlier WELCOME; skips pairing for trusted devices.
    public var token: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case deviceId, deviceName, platform, appVersion, display, codecs, locale, token
    }

    public init(
        protocolVersion: Int = MSMProtocolInfo.version,
        deviceId: String,
        deviceName: String,
        platform: String,
        appVersion: String,
        display: DisplayInfo,
        codecs: [String],
        locale: String? = nil,
        token: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
        self.display = display
        self.codecs = codecs
        self.locale = locale
        self.token = token
    }
}

/// WELCOME (host → client): the client is accepted; CONFIG and VIDEO follow.
public struct Welcome: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var hostName: String
    public var sessionId: String
    /// `usb` or `wifi`, as seen by the host.
    public var transport: String
    /// New pairing token; present only right after a successful pairing.
    public var token: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case hostName, sessionId, transport, token
    }

    public init(protocolVersion: Int = MSMProtocolInfo.version, hostName: String, sessionId: String, transport: String, token: String? = nil) {
        self.protocolVersion = protocolVersion
        self.hostName = hostName
        self.sessionId = sessionId
        self.transport = transport
        self.token = token
    }
}

/// PAIR_REQUEST (host → client): the user must type the code shown on the Mac.
public struct PairRequest: Codable, Sendable, Equatable {
    public var codeLength: Int
    public var attemptsLeft: Int
    /// True when the previous code was wrong.
    public var retry: Bool

    public init(codeLength: Int, attemptsLeft: Int, retry: Bool) {
        self.codeLength = codeLength
        self.attemptsLeft = attemptsLeft
        self.retry = retry
    }
}

/// PAIR (client → host).
public struct PairResponse: Codable, Sendable, Equatable {
    public var code: String

    public init(code: String) {
        self.code = code
    }
}

/// ERROR (host → client). The host closes the connection after sending it.
public struct ErrorInfo: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: ErrorCode, message: String) {
        self.code = code.rawValue
        self.message = message
    }
}

public enum ErrorCode: String, Sendable {
    case unsupportedProtocol = "unsupported_protocol"
    case pairingFailed = "pairing_failed"
    case pairingTimeout = "pairing_timeout"
    /// Another device is pairing, or too many wrong codes were entered recently.
    case pairingUnavailable = "pairing_unavailable"
    case rejected = "rejected"
    case permissionMissing = "permission_missing"
    case displayUnavailable = "display_unavailable"
    case internalError = "internal"
}

/// CONFIG (host → client): describes the video stream that follows.
public struct StreamConfig: Codable, Sendable, Equatable {
    /// `h264` or `hevc`.
    public var codec: String
    /// RFC 6381 codec string, e.g. `avc1.640033` (used by WebCodecs).
    public var codecString: String
    public var width: Int
    public var height: Int
    public var fps: Int
    /// `extend` or `mirror`.
    public var mode: String

    public init(codec: String, codecString: String, width: Int, height: Int, fps: Int, mode: String) {
        self.codec = codec
        self.codecString = codecString
        self.width = width
        self.height = height
        self.fps = fps
        self.mode = mode
    }
}

/// STATS (client → host), about once per second.
public struct ClientStats: Codable, Sendable, Equatable {
    public var fps: Double
    public var decodeMs: Double
    /// Capture-to-display estimate, if the client has a clock offset.
    public var latencyMs: Double?
    public var rttMs: Double?
    public var droppedFrames: Int
    public var bitrateKbps: Double

    public init(fps: Double, decodeMs: Double, latencyMs: Double?, rttMs: Double?, droppedFrames: Int, bitrateKbps: Double) {
        self.fps = fps
        self.decodeMs = decodeMs
        self.latencyMs = latencyMs
        self.rttMs = rttMs
        self.droppedFrames = droppedFrames
        self.bitrateKbps = bitrateKbps
    }
}

/// BYE (both directions).
public struct Bye: Codable, Sendable, Equatable {
    public var reason: String

    public init(reason: String) {
        self.reason = reason
    }
}
