import Foundation
import MSMClientKit
import MSMProtocol
import Network
import SwiftUI

/// Owns the connection to the Mac: connects over Wi-Fi or accepts USB, handles pairing,
/// reconnects after unexpected drops and publishes the state the UI shows.
@MainActor
final class SessionController: ObservableObject {
    @Published private(set) var phase = SessionPhase.idle
    @Published var failure: SessionFailure?
    @Published private(set) var videoSize = CGSize.zero
    @Published private(set) var hasPicture = false
    @Published private(set) var stats: StreamStats?
    @Published private(set) var usbState = USBListener.State.inactive

    let videoOutput = VideoOutput()

    private struct ActiveSession {
        let generation: Int
        let route: SessionRoute
        let connection: ClientConnection
        let receiver: StreamReceiver
        let hello: Hello
        let isReconnect: Bool
        var welcomed = false
    }

    private let recents: RecentHostsStore
    private let usbListener = USBListener()
    private var active: ActiveSession?
    /// Identifies the current connection; events from older ones are ignored.
    private var generation = 0
    private var reconnectPolicy = ReconnectPolicy()
    private var reconnectTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var deferredReconnect: HostTarget?
    /// Last size reported by the visible stream view; zero while it is not shown.
    private var surfaceSize = CGSize.zero
    /// Wi-Fi host to go back to when a USB session that replaced it ends.
    private var wifiFallback: HostTarget?
    private var isForeground = true
    private var launched = false

    init(recents: RecentHostsStore) {
        self.recents = recents
        usbListener.onStateChange = { [weak self] in self?.usbState = $0 }
        usbListener.onConnection = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.acceptUSB(connection)
        }
    }

    var showsStream: Bool {
        switch phase {
        case .streaming, .reconnecting: true
        default: false
        }
    }

    var pairingPrompt: PairingPrompt? {
        if case let .pairing(_, prompt) = phase { return prompt }
        return nil
    }

    var route: SessionRoute? { phase.route }

    func displayName(for route: SessionRoute) -> String {
        switch route {
        case .usb:
            return String(localized: "connect.usb.title")
        case let .network(target):
            return recents.hostName(for: target) ?? target.displayName
        }
    }

    // MARK: User actions

    func launch() {
        guard !launched else { return }
        launched = true
        usbListener.start()
        #if DEBUG
        // e.g. `-autoConnect 127.0.0.1:7400` as a launch argument, for simulator tests.
        if let text = UserDefaults.standard.string(forKey: "autoConnect"), let target = HostTarget(parsing: text) {
            connect(to: target)
        }
        #endif
    }

    func connect(to target: HostTarget) {
        cancelPendingWork()
        failure = nil
        wifiFallback = nil
        reconnectPolicy.reset()
        closeActive()
        open(.network(target), isReconnect: false)
    }

    func disconnect() {
        cancelPendingWork()
        wifiFallback = nil
        closeActive()
        finish(with: nil)
    }

    func submitPairingCode(_ code: String) {
        guard case .pairing = phase else { return }
        active?.connection.sendPairingCode(code)
    }

    func cancelPairing() {
        guard case .pairing = phase else { return }
        disconnect()
    }

    func send(_ event: InputEvent) {
        guard case .streaming = phase else { return }
        active?.connection.send(event)
    }

    /// The layer was (re)attached to a window; make sure it gets a decodable picture.
    func streamViewAppeared() {
        active?.connection.requestKeyframe()
    }

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            guard !isForeground else { return }
            isForeground = true
            videoOutput.isSuspended = false
            usbListener.start()
            if active != nil {
                videoOutput.requestReset()
                active?.connection.requestKeyframe()
            }
            if let target = deferredReconnect {
                deferredReconnect = nil
                open(.network(target), isReconnect: true)
            }
        case .background:
            isForeground = false
            videoOutput.isSuspended = true
            usbListener.stop()
        default:
            // .inactive (Control Center, app switcher): keep streaming.
            break
        }
    }

    /// Pixel size of the stream view. A rotation reconnects so the Mac recreates the display in
    /// the new orientation: Wi-Fi sessions dial again; over USB the Mac dials back through usbmux.
    func surfaceSizeChanged(_ size: CGSize) {
        surfaceSize = size
        resizeTask?.cancel()
        guard let active, active.welcomed else { return }
        let current = CGSize(width: active.hello.display.width, height: active.hello.display.height)
        guard size != current, size.width >= 320, size.height >= 320 else { return }
        let route = active.route
        resizeTask = Task { [weak self] in
            // Let the rotation animation settle before asking for a new display.
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            switch route {
            case let .network(target):
                self.closeActive()
                self.reconnectPolicy.reset()
                self.open(.network(target), isReconnect: true)
            case .usb:
                // Not "user": the Mac's usbmux bridge reconnects within a few seconds.
                self.closeActive(reason: "reconfigure")
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled, self.active == nil { self.finish(with: nil) }
            }
        }
    }

    // MARK: Connections

    private func acceptUSB(_ connection: NWConnection) {
        guard isForeground else { return connection.cancel() }
        let wasStreaming = showsStream
        // USB wins over Wi-Fi; remember the Wi-Fi host for when the cable goes away.
        if case let .network(target) = phase.route, wasStreaming {
            wifiFallback = target
        }
        cancelPendingWork()
        closeActive()
        failure = nil
        reconnectPolicy.reset()
        // Keep the stream on screen while switching transports.
        open(.usb, accepted: connection, isReconnect: wasStreaming)
    }

    private func open(_ route: SessionRoute, accepted: NWConnection? = nil, isReconnect: Bool) {
        guard let display = DeviceProfile.currentDisplay() else {
            accepted?.cancel()
            finish(with: .noDisplay)
            return
        }

        let client: ClientConnection
        let hello: Hello
        switch route {
        case let .network(target):
            hello = DeviceProfile.hello(display: display, token: TokenStore.token(for: tokenKeys(for: target)))
            client = target.makeConnection(hello: hello)
        case .usb:
            guard let accepted else { return }
            // USB is trusted without pairing; never hand a token to whatever dialled in.
            hello = DeviceProfile.hello(display: display, token: nil)
            client = ClientConnection(connection: accepted, hello: hello)
        }

        generation += 1
        let generation = generation
        let receiver = StreamReceiver(output: videoOutput) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handle(event, generation: generation) }
            }
        }
        client.delegate = receiver
        client.statsProvider = { [weak receiver, weak client] in
            receiver?.hostStats(connection: client) ?? (decodeMs: 0, latencyMs: nil, dropped: 0)
        }
        active = ActiveSession(generation: generation, route: route, connection: client, receiver: receiver, hello: hello, isReconnect: isReconnect)
        phase = isReconnect ? .reconnecting(route, attempt: reconnectPolicy.attempt) : .connecting(route)
        client.start()
    }

    private func handle(_ event: StreamReceiver.Event, generation: Int) {
        guard var session = active, session.generation == generation else { return }
        switch event {
        case let .welcome(welcome):
            session.welcomed = true
            active = session
            reconnectPolicy.reset()
            failure = nil
            if case let .network(target) = session.route {
                if let token = welcome.token {
                    TokenStore.save(token, for: [target.tokenKey, HostTarget.tokenKey(hostName: welcome.hostName)])
                }
                recents.record(target, hostName: welcome.hostName)
            }
            phase = .streaming(session.route)
            // The view may have rotated again while this session was being set up.
            if surfaceSize != .zero { surfaceSizeChanged(surfaceSize) }
        case let .pairingRequested(request):
            phase = .pairing(session.route, PairingPrompt(request))
            submitDebugPairingCode(request)
        case let .config(config):
            videoSize = CGSize(width: config.width, height: config.height)
        case .firstFrame:
            hasPicture = true
        case let .stats(stats):
            self.stats = stats
        case let .closed(error):
            active = nil
            sessionEnded(session, error: error)
        }
    }

    private func sessionEnded(_ session: ActiveSession, error: ClientError?) {
        switch (session.route, CloseOutcome(error)) {
        case (_, .quiet):
            finish(with: nil)
        case let (_, .fail(failure)):
            finish(with: failure)
        case let (.usb, .reconnect(failure)):
            if let target = wifiFallback {
                wifiFallback = nil
                reconnectPolicy.reset()
                scheduleReconnect(to: target, failure: failure)
            } else {
                // A dropped probe before WELCOME is not worth an alert.
                finish(with: session.welcomed ? failure : nil)
            }
        case let (.network(target), .reconnect(failure)):
            if session.welcomed || session.isReconnect {
                scheduleReconnect(to: target, failure: failure)
            } else if case .network = error {
                finish(with: .connectFailed(displayName(for: session.route)))
            } else {
                finish(with: failure)
            }
        }
    }

    private func scheduleReconnect(to target: HostTarget, failure: SessionFailure) {
        guard let delay = reconnectPolicy.nextDelay() else {
            finish(with: failure)
            return
        }
        phase = .reconnecting(.network(target), attempt: reconnectPolicy.attempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.isForeground {
                self.open(.network(target), isReconnect: true)
            } else {
                self.deferredReconnect = target
            }
        }
    }

    private func finish(with failure: SessionFailure?) {
        phase = .idle
        self.failure = failure
        hasPicture = false
        surfaceSize = .zero
        videoSize = .zero
        stats = nil
        videoOutput.clear()
    }

    /// Clearing `active` first makes the connection's own close callback a stale event.
    private func closeActive(reason: String = "user") {
        guard let session = active else { return }
        active = nil
        session.connection.close(reason: reason)
    }

    private func cancelPendingWork() {
        reconnectTask?.cancel()
        reconnectTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        deferredReconnect = nil
    }

    private func tokenKeys(for target: HostTarget) -> [String] {
        var keys = [target.tokenKey]
        if let name = target.serviceName ?? recents.hostName(for: target) {
            keys.append(HostTarget.tokenKey(hostName: name))
        }
        return keys
    }

    private func submitDebugPairingCode(_ request: PairRequest) {
        #if DEBUG
        // `-pairingCode 123456` answers the first prompt automatically (simulator tests).
        guard !request.retry, let code = UserDefaults.standard.string(forKey: "pairingCode") else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.submitPairingCode(code)
        }
        #endif
    }
}
