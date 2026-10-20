import CoreGraphics
import Foundation
import MSMProtocol

/// What the UI shows for one connected client.
public struct SessionSnapshot: Sendable, Identifiable, Equatable {
    public enum Phase: Sendable, Equatable {
        case handshaking
        /// Waiting for the user to type this code on the client.
        case pairing(code: String)
        case starting
        case streaming
        case closed
    }

    public var id: UUID
    public var deviceId: String?
    public var deviceName: String
    public var platform: String?
    public var transport: TransportKind
    public var width: Int
    public var height: Int
    public var mode: DisplayMode
    public var phase: Phase
    public var pipeline: PipelineStats
    public var client: ClientStats?
    public var connectedAt: Date

    public init(id: UUID = UUID(), deviceId: String?, deviceName: String, platform: String?, transport: TransportKind, width: Int, height: Int, mode: DisplayMode, phase: Phase, pipeline: PipelineStats = PipelineStats(), client: ClientStats? = nil, connectedAt: Date = Date()) {
        self.id = id
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.transport = transport
        self.width = width
        self.height = height
        self.mode = mode
        self.phase = phase
        self.pipeline = pipeline
        self.client = client
        self.connectedAt = connectedAt
    }
}

/// Handles one client connection: handshake, pairing, streaming and input.
/// All state is confined to `queue`.
final class ClientSession: @unchecked Sendable {
    let id = UUID()
    let queue: DispatchQueue
    private let channel: MessageChannel
    private unowned let engine: HostEngine
    private let options: HostEngine.Options

    private var phase: SessionSnapshot.Phase = .handshaking
    private(set) var hello: Hello?
    private var pairing: PairingCode?
    private var pipeline: StreamPipeline?
    private let injector = InputInjector()
    private var clientStats: ClientStats?
    private var lastReceived = Date()
    private var timer: DispatchSourceTimer?
    private let connectedAt = Date()
    private var closed = false
    private var holdsPairingSlot = false

    init(channel: MessageChannel, engine: HostEngine, options: HostEngine.Options) {
        self.channel = channel
        self.engine = engine
        self.options = options
        queue = DispatchQueue(label: "com.macsecondmonitor.session", qos: .userInteractive)
    }

    func start() {
        channel.start(queue: queue, onMessage: { [weak self] message in
            self?.handle(message)
        }, onClose: { [weak self] error in
            if let error {
                Log.session.info("Connection closed: \(error.localizedDescription, privacy: .public)")
            }
            self?.finish()
        })

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func snapshot() -> SessionSnapshot {
        queue.sync {
            SessionSnapshot(
                id: id,
                deviceId: hello?.deviceId,
                deviceName: hello?.deviceName ?? channel.remoteDescription,
                platform: hello?.platform,
                transport: channel.transport,
                width: pipeline?.width ?? hello?.display.width ?? 0,
                height: pipeline?.height ?? hello?.display.height ?? 0,
                mode: options.displayMode,
                phase: phase,
                pipeline: pipeline?.stats ?? PipelineStats(),
                client: clientStats,
                connectedAt: connectedAt
            )
        }
    }

    /// Ends the session from the host side (user action, replacement or shutdown).
    func disconnect(reason: String) {
        queue.async { [self] in
            guard !closed else { return }
            // Close only after BYE is out, so the client knows whether to reconnect.
            channel.send(.json(.bye, Bye(reason: reason))) { [channel] in
                channel.close(reason: reason)
            }
            finish()
        }
    }

    // MARK: Messages

    private func handle(_ message: Message) {
        guard !closed else { return }
        lastReceived = Date()
        do {
            switch message.type {
            case .hello:
                try handleHello(message.decodeJSON(Hello.self))
            case .pair:
                try handlePair(message.decodeJSON(PairResponse.self))
            case .ack:
                pipeline?.acknowledge(try FrameAck(message).seq)
            case .keyframeRequest:
                pipeline?.requestKeyframe()
            case .input:
                guard phase == .streaming else { return }
                handleInput(try InputEvent(message))
            case .ping:
                let ping = try Ping(message)
                channel.send(Pong(echoedTime: ping.time, responderTime: HostClock.nowMicros()).message())
            case .pong:
                break
            case .stats:
                let stats = try message.decodeJSON(ClientStats.self)
                clientStats = stats
                pipeline?.clientRttMs = stats.rttMs
            case .bye:
                let reason = (try? message.decodeJSON(Bye.self))?.reason
                channel.close(reason: reason)
                finish()
            case .welcome, .pairRequest, .error, .config, .video:
                // Host-to-client messages; a client must not send them.
                break
            }
        } catch {
            Log.session.error("Bad \(String(describing: message.type), privacy: .public) message: \(String(describing: error), privacy: .public)")
            if phase == .handshaking {
                fail(.internalError, L10n.tr("error.protocol.invalidMessage"))
            }
        }
    }

    private func handleHello(_ hello: Hello) {
        guard phase == .handshaking, self.hello == nil else { return }
        guard hello.protocolVersion == MSMProtocolInfo.version else {
            fail(.unsupportedProtocol, L10n.tr("error.protocol.version", hello.protocolVersion, MSMProtocolInfo.version))
            return
        }
        guard (320...8192).contains(hello.display.width), (320...8192).contains(hello.display.height) else {
            fail(.rejected, L10n.tr("error.protocol.resolution"))
            return
        }
        self.hello = hello
        Log.session.info("HELLO from \(hello.deviceName, privacy: .public) (\(hello.platform, privacy: .public)) \(hello.display.width)x\(hello.display.height) via \(self.channel.transport.rawValue, privacy: .public)")

        if isTrusted(hello) {
            accept(token: nil)
            return
        }
        switch engine.pairingGate.begin(id) {
        case .granted:
            holdsPairingSlot = true
            pairing = PairingCode()
            phase = .pairing(code: pairing!.value)
            channel.send(.json(.pairRequest, PairRequest(codeLength: PairingCode.length, attemptsLeft: PairingCode.maxAttempts, retry: false)))
            engine.sessionChanged()
        case .busy:
            fail(.pairingUnavailable, L10n.tr("error.pairing.busy"))
        case let .locked(seconds):
            fail(.pairingUnavailable, L10n.tr("error.pairing.locked", seconds))
        }
    }

    /// Who may skip pairing:
    /// - the device on the other end of a usbmux tunnel the Mac opened itself,
    /// - our Android app over the `adb reverse` tunnel, which proves itself with the secret the
    ///   Mac handed it through adb (other apps on the device can reach the tunnel too),
    /// - devices holding a token from an earlier pairing.
    private func isTrusted(_ hello: Hello) -> Bool {
        if !options.requirePairing || channel.isHostInitiatedUSB { return true }
        if channel.transport == .usb, engine.trustStore.isUSBSecret(hello.token) { return true }
        return engine.trustStore.validate(deviceId: hello.deviceId, token: hello.token)
    }

    private func handlePair(_ response: PairResponse) {
        guard case .pairing = phase, var pairing, let hello else { return }
        if pairing.isExpired {
            fail(.pairingTimeout, L10n.tr("error.pairing.timeout"))
            return
        }
        if pairing.verify(response.code) {
            self.pairing = nil
            releasePairingSlot(succeeded: true)
            let token = engine.trustStore.trust(deviceId: hello.deviceId, name: hello.deviceName, platform: hello.platform)
            accept(token: token)
        } else if pairing.attemptsLeft > 0 {
            self.pairing = pairing
            channel.send(.json(.pairRequest, PairRequest(codeLength: PairingCode.length, attemptsLeft: pairing.attemptsLeft, retry: true)))
        } else {
            // Wrong three times: pairing pauses for everyone, with growing delays.
            releasePairingSlot(succeeded: false)
            fail(.pairingFailed, L10n.tr("error.pairing.failed"))
        }
    }

    private func releasePairingSlot(succeeded: Bool?) {
        guard holdsPairingSlot else { return }
        holdsPairingSlot = false
        engine.pairingGate.end(id, outcome: succeeded)
    }

    private func accept(token: String?) {
        guard let hello else { return }
        // Only an authenticated device may replace its own stale session.
        engine.sessionIdentified(self, deviceId: hello.deviceId)
        if !options.testPattern, !CGPreflightScreenCaptureAccess() {
            engine.reportMissingScreenRecordingPermission()
            fail(.permissionMissing, L10n.tr("error.capture.permissionDenied"))
            return
        }

        phase = .starting
        let transport = channel.transport == .usb ? "usb" : "wifi"
        channel.send(.json(.welcome, Welcome(hostName: options.hostName, sessionId: id.uuidString, transport: transport, token: token)))

        let codec: VideoCodec = options.preferHEVC && hello.codecs.contains("hevc") ? .hevc : .h264
        let configuration = StreamPipeline.Configuration(
            mode: options.displayMode,
            codec: codec,
            fps: min(options.fps, max(30, Int(hello.display.refreshRate.rounded()))),
            quality: options.quality,
            testPattern: options.testPattern
        )
        let pipeline = StreamPipeline(
            queue: queue,
            channel: channel,
            client: hello.display,
            displayName: hello.deviceName,
            identity: hello.deviceId,
            configuration: configuration
        )
        pipeline.onFailure = { [weak self] error in
            guard let self else { return }
            self.queue.async { self.fail(.displayUnavailable, error.localizedDescription) }
        }
        self.pipeline = pipeline
        engine.sessionChanged()

        Task { [weak self] in
            do {
                try await pipeline.start()
                guard let self else { return }
                self.queue.async {
                    guard !self.closed else { return }
                    self.phase = .streaming
                    self.engine.sessionChanged()
                }
            } catch {
                Log.session.error("Pipeline failed to start: \(error.localizedDescription, privacy: .public)")
                guard let self else { return }
                self.queue.async {
                    if case CaptureError.permissionDenied = error {
                        self.engine.reportMissingScreenRecordingPermission()
                    }
                    self.fail(.displayUnavailable, error.localizedDescription)
                }
            }
        }
    }

    private func handleInput(_ event: InputEvent) {
        guard let pipeline else { return }
        if let pattern = pipeline.testPattern {
            if case let .pointer(_, _, _, x, y, _) = event {
                pattern.showPointer(x: Double(x), y: Double(y))
            } else if case let .scroll(_, _, x, y, _, _) = event {
                pattern.showPointer(x: Double(x), y: Double(y))
            }
            guard options.injectInputInTestMode else { return }
        }
        // Refresh at the start of each gesture: the user may have moved the display.
        if pipeline.mapper == nil || event.startsGesture {
            pipeline.updateMapper()
        }
        guard let mapper = pipeline.mapper ?? (options.injectInputInTestMode ? CoordinateMapper(displayBounds: CGDisplayBounds(CGMainDisplayID())) : nil) else { return }
        injector.handle(event, mapper: mapper)
    }

    // MARK: Lifecycle

    private func tick() {
        guard !closed else { return }
        pipeline?.tick()
        if case .pairing = phase, pairing?.isExpired == true {
            fail(.pairingTimeout, L10n.tr("error.pairing.timeout"))
            return
        }
        // Clients ping every second; a silent client is gone (e.g. Wi-Fi dropped).
        if Date().timeIntervalSince(lastReceived) > 10 {
            Log.session.info("Client timed out")
            channel.close()
            finish()
            return
        }
        engine.sessionChanged()
    }

    private func fail(_ code: ErrorCode, _ message: String) {
        guard !closed else { return }
        Log.session.error("Closing session: \(code.rawValue, privacy: .public) \(message, privacy: .public)")
        channel.send(.json(.error, ErrorInfo(code: code, message: message))) { [channel] in
            channel.close()
        }
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        releasePairingSlot(succeeded: nil)
        phase = .closed
        timer?.cancel()
        timer = nil
        injector.releaseAll()
        let pipeline = pipeline
        self.pipeline = nil
        Task {
            await pipeline?.stop()
        }
        engine.sessionEnded(self)
    }
}

extension InputEvent {
    var startsGesture: Bool {
        switch self {
        case .pointer(.down, _, _, _, _, _), .scroll(.began, _, _, _, _, _), .scroll(.none, _, _, _, _, _): true
        default: false
        }
    }
}
