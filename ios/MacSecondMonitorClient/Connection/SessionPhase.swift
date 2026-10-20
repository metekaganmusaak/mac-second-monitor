import Foundation
import MSMProtocol

/// How the current session reaches the Mac.
enum SessionRoute: Equatable, Sendable {
    case network(HostTarget)
    /// usbmux tunnel; the host opened the connection.
    case usb
}

struct PairingPrompt: Equatable {
    let codeLength: Int
    let attemptsLeft: Int
    let isRetry: Bool

    init(_ request: PairRequest) {
        codeLength = request.codeLength
        attemptsLeft = request.attemptsLeft
        isRetry = request.retry
    }
}

enum SessionPhase: Equatable {
    case idle
    case connecting(SessionRoute)
    case pairing(SessionRoute, PairingPrompt)
    case streaming(SessionRoute)
    /// Waiting for, or running, an automatic reconnect. `attempt` is 0 for a planned restart
    /// (e.g. after a rotation changed the display size).
    case reconnecting(SessionRoute, attempt: Int)

    var route: SessionRoute? {
        switch self {
        case .idle: nil
        case let .connecting(route), let .pairing(route, _), let .streaming(route), let .reconnecting(route, _): route
        }
    }
}
