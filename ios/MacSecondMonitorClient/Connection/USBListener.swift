import Foundation
import MSMClientKit
import MSMProtocol
import Network

/// USB via usbmux: the Mac connects to this port through the cable, so the app listens and
/// the host dials in. Protocol roles stay the same (the app still sends HELLO first).
@MainActor
final class USBListener {
    enum State: Equatable {
        case inactive
        /// The simulator shares the Mac's network stack, where the host already owns the port.
        case unavailable
        case listening
        case failed
    }

    static let port: UInt16 = MSMProtocolInfo.nativePort

    var onConnection: (NWConnection) -> Void = { $0.cancel() }
    var onStateChange: (State) -> Void = { _ in }

    private(set) var state = State.inactive {
        didSet { if state != oldValue { onStateChange(state) } }
    }
    private var listener: NWListener?
    private var retryTask: Task<Void, Never>?

    func start() {
        #if targetEnvironment(simulator)
        state = .unavailable
        #else
        guard listener == nil else { return }
        let parameters = ClientConnection.parameters()
        // usbmuxd delivers tunnelled connections on loopback; never accept them from the LAN.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: parameters, on: port)
        else {
            failed()
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                self.onConnection(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        #endif
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        listener?.cancel()
        listener = nil
        if state != .unavailable { state = .inactive }
    }

    private func listenerChanged(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            state = .listening
        case .failed:
            failed()
        default:
            break
        }
    }

    /// Typically the port is still held by a previous instance; try again shortly.
    private func failed() {
        listener?.cancel()
        listener = nil
        state = .failed
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.start()
        }
    }
}
