import Foundation
import MSMClientKit
import MSMProtocol

/// A problem shown to the user on the connect screen.
struct SessionFailure: Identifiable, Equatable {
    let id = UUID()
    let message: String

    static func connectFailed(_ name: String) -> SessionFailure {
        SessionFailure(message: L10n.format(String(localized: "error.connectFailed"), name))
    }

    static var connectionLost: SessionFailure { SessionFailure(message: String(localized: "error.connectionLost")) }
    static var endedOnMac: SessionFailure { SessionFailure(message: String(localized: "error.endedOnMac")) }
    static var replaced: SessionFailure { SessionFailure(message: String(localized: "error.replaced")) }
    static var protocolError: SessionFailure { SessionFailure(message: String(localized: "error.protocol")) }
    static var noDisplay: SessionFailure { SessionFailure(message: String(localized: "error.noDisplay")) }

    /// The host's own `message` is localized for the Mac's language; prefer our text for known codes.
    static func host(code: String, message: String) -> SessionFailure {
        let text: String
        switch ErrorCode(rawValue: code) {
        case .permissionMissing: text = String(localized: "error.permissionMissing")
        case .pairingFailed: text = String(localized: "error.pairingFailed")
        case .pairingTimeout: text = String(localized: "error.pairingTimeout")
        case .unsupportedProtocol: text = String(localized: "error.unsupportedProtocol")
        case .displayUnavailable: text = String(localized: "error.displayUnavailable")
        case .rejected: text = String(localized: "error.rejected")
        case .pairingUnavailable:
            // Says how long pairing is paused; only the host knows.
            text = message.isEmpty ? String(localized: "error.unknown") : message
        case .internalError, nil:
            text = message.isEmpty ? String(localized: "error.unknown") : L10n.format(String(localized: "error.internal"), message)
        }
        return SessionFailure(message: text)
    }
}

/// How the app reacts when a connection ends.
enum CloseOutcome: Equatable {
    /// Closed by this app; nothing to report.
    case quiet
    /// Unexpected drop: reconnect if the session had been established.
    case reconnect(SessionFailure)
    /// Final: show the failure and stay disconnected.
    case fail(SessionFailure)

    init(_ error: ClientError?) {
        switch error {
        case nil:
            self = .quiet
        case let .host(code, message):
            self = .fail(.host(code: code, message: message))
        case .closedByHost(reason: "user"), .closedByHost(reason: "shutdown"):
            // "shutdown": the Mac app quit. Over USB it dials back once it is reopened; there is
            // nothing to gain from retrying in a loop.
            self = .fail(.endedOnMac)
        case .closedByHost(reason: "replaced"):
            self = .fail(.replaced)
        case .closedByHost, .network:
            self = .reconnect(.connectionLost)
        case .protocolViolation:
            self = .reconnect(.protocolError)
        }
    }
}

/// Exponential backoff for automatic reconnects: 1, 2, 4, 8, 8… seconds.
struct ReconnectPolicy {
    static let maxAttempts = 10
    private(set) var attempt = 0

    mutating func reset() {
        attempt = 0
    }

    /// Delay before the next attempt, or nil when it is time to give up.
    mutating func nextDelay() -> TimeInterval? {
        guard attempt < Self.maxAttempts else { return nil }
        attempt += 1
        return min(pow(2, Double(attempt - 1)), 8)
    }
}
