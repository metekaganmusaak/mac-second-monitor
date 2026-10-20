import Foundation
import MSMProtocol
import Network

public enum TransportKind: String, Sendable {
    /// USB tunnel (adb reverse or usbmux); arrives on the loopback interface.
    case usb
    case wifi
    case ethernet
    case local

    public var isWired: Bool { self == .usb || self == .ethernet || self == .local }

    public var localizedName: String {
        L10n.tr("transport.\(rawValue)")
    }
}

/// A bidirectional message pipe to one client. Implementations deliver callbacks on
/// the queue passed to `start`.
public protocol MessageChannel: AnyObject, Sendable {
    var remoteDescription: String { get }
    var transport: TransportKind { get }
    func start(queue: DispatchQueue, onMessage: @escaping @Sendable (Message) -> Void, onClose: @escaping @Sendable (Error?) -> Void)
    /// `completion` runs once the bytes were handed to the network stack.
    func send(_ message: Message, completion: (@Sendable () -> Void)?)
    func close()
    /// `reason` is the BYE reason that ended the session, if any (USB bridges use it to decide
    /// whether to dial the device again).
    func close(reason: String?)
    /// The Mac itself opened this channel to a physical USB device (usbmux), so the peer is the
    /// device on the cable rather than whatever process dialled in.
    var isHostInitiatedUSB: Bool { get }
}

extension MessageChannel {
    public func send(_ message: Message) {
        send(message, completion: nil)
    }

    public func close(reason _: String?) {
        close()
    }

    public var isHostInitiatedUSB: Bool { false }
}

enum NetworkParameters {
    /// TCP tuned for interactive video: no Nagle delay, Wi-Fi video access category.
    static func tcp() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        return parameters
    }

    static func transport(for connection: NWConnection) -> TransportKind {
        if case let .hostPort(host, _) = connection.endpoint, host.isLoopback {
            return .usb
        }
        if let path = connection.currentPath {
            if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
            if path.usesInterfaceType(.loopback) { return .local }
        }
        return .wifi
    }
}

extension NWEndpoint.Host {
    var isLoopback: Bool {
        switch self {
        case let .ipv4(address): address.isLoopback
        case let .ipv6(address): address.isLoopback || address == .loopback || address.asIPv4?.isLoopback == true
        case let .name(name, _): name == "localhost"
        @unknown default: false
        }
    }
}

/// Framed messages over a raw TCP connection (Wi-Fi, Ethernet and USB tunnels).
public final class TCPMessageChannel: MessageChannel, @unchecked Sendable {
    private let connection: NWConnection
    private var decoder = MessageDecoder()
    private var onMessage: (@Sendable (Message) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?
    private var closed = false
    private var queue: DispatchQueue?
    public private(set) var transport: TransportKind = .wifi

    public init(connection: NWConnection, transport: TransportKind? = nil) {
        self.connection = connection
        if let transport {
            self.transport = transport
        }
    }

    public var remoteDescription: String { "\(connection.endpoint)" }

    public func start(queue: DispatchQueue, onMessage: @escaping @Sendable (Message) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        self.queue = queue
        self.onMessage = onMessage
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if self.transport == .wifi {
                    self.transport = NetworkParameters.transport(for: self.connection)
                }
                self.receive()
            case let .failed(error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: Message, completion: (@Sendable () -> Void)?) {
        connection.send(content: message.serialized(), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(error)
            }
            completion?()
        })
    }

    public func close() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.decoder.append(data)
                do {
                    while let message = try self.decoder.next() {
                        self.onMessage?(message)
                    }
                } catch {
                    self.finish(error)
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
                self.connection.cancel()
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        let onClose = onClose
        self.onClose = nil
        onMessage = nil
        onClose?(error)
    }
}
