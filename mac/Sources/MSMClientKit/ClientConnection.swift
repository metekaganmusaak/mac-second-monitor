import Foundation
import MSMProtocol
import Network

public enum ClientError: Error, Equatable, Sendable {
    /// The host sent ERROR.
    case host(code: String, message: String)
    case closedByHost(reason: String)
    case network(String)
    case protocolViolation(String)
}

public protocol ClientConnectionDelegate: AnyObject, Sendable {
    func connection(_ connection: ClientConnection, didReceiveWelcome welcome: Welcome)
    /// The user must type the code shown on the Mac; answer with `sendPairingCode`.
    func connection(_ connection: ClientConnection, needsPairingCode request: PairRequest)
    func connection(_ connection: ClientConnection, didReceiveConfig config: StreamConfig)
    /// Called on the connection queue. Call `acknowledge` once the frame is queued for decoding.
    func connection(_ connection: ClientConnection, didReceiveFrame frame: VideoFrame)
    func connection(_ connection: ClientConnection, didCloseWith error: ClientError?)
}

/// Client side of the protocol over TCP. Sends HELLO, keeps the host alive with PINGs,
/// measures RTT and the host clock offset, and reports STATS.
public final class ClientConnection: @unchecked Sendable {
    public let queue = DispatchQueue(label: "com.macsecondmonitor.client.connection", qos: .userInteractive)
    public weak var delegate: ClientConnectionDelegate?

    private let connection: NWConnection
    private let hello: Hello
    private var decoder = MessageDecoder()
    private var timer: DispatchSourceTimer?
    private var closed = false

    private struct Measurements {
        var rttMicros: UInt64?
        var clockOffsetMicros: Int64?
        var lastStats: ClientStats?
    }

    /// Written on `queue`, readable from any thread (e.g. a UI overlay).
    private let measurements = Locked(Measurements())

    public var rttMicros: UInt64? { measurements.get().rttMicros }
    /// `hostClock - clientClock` in microseconds, from the best (lowest RTT) PONG.
    public var clockOffsetMicros: Int64? { measurements.get().clockOffsetMicros }
    /// Most recent once-per-second measurement, for an on-screen overlay.
    public var lastStats: ClientStats? { measurements.get().lastStats }

    private var bestRtt = UInt64.max
    private var receivedBytes = 0
    private var receivedFrames = 0
    private var windowStart = HostClockLite.nowMicros()
    public var statsProvider: (@Sendable () -> (decodeMs: Double, latencyMs: Double?, dropped: Int))?

    public convenience init(host: String, port: UInt16 = MSMProtocolInfo.nativePort, hello: Hello) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        self.init(connection: NWConnection(to: endpoint, using: Self.parameters()), hello: hello)
    }

    /// Wraps an existing connection, e.g. one accepted from the host over usbmux.
    public init(connection: NWConnection, hello: Hello) {
        self.connection = connection
        self.hello = hello
    }

    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !self.closed else { return }
                self.send(.json(.hello, self.hello))
                self.receive()
                self.startTimer()
            case let .failed(error), let .waiting(error):
                // `.waiting` (e.g. connection refused) would retry forever in the background.
                self.finish(.network(error.localizedDescription))
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// `reason` goes into BYE: the host treats `user` as final; anything else (e.g. `reconfigure`
    /// after a rotation) is a temporary disconnect.
    public func close(reason: String = "user") {
        queue.async { [self] in
            guard !closed else { return }
            send(.json(.bye, Bye(reason: reason)))
            connection.cancel()
            finish(nil)
        }
    }

    public func sendPairingCode(_ code: String) {
        send(.json(.pair, PairResponse(code: code)))
    }

    public func send(_ event: InputEvent) {
        send(event.message())
    }

    public func requestKeyframe() {
        send(Message(type: .keyframeRequest))
    }

    public func acknowledge(_ seq: UInt32) {
        send(FrameAck(seq: seq).message())
    }

    /// Estimated capture-to-now latency for a frame, if the clock offset is known.
    public func latencyMicros(captureTime: UInt64, now: UInt64 = HostClockLite.nowMicros()) -> Int64? {
        guard let offset = clockOffsetMicros else { return nil }
        return Int64(now) + offset - Int64(captureTime)
    }

    private func send(_ message: Message) {
        connection.send(content: message.serialized(), completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.receivedBytes += data.count
                self.decoder.append(data)
                do {
                    while let message = try self.decoder.next() {
                        try self.handle(message)
                        if self.closed { return }
                    }
                } catch {
                    self.connection.cancel()
                    self.finish(.protocolViolation(String(describing: error)))
                    return
                }
            }
            if let error {
                self.finish(.network(error.localizedDescription))
            } else if isComplete {
                self.connection.cancel()
                self.finish(.network("closed"))
            } else {
                self.receive()
            }
        }
    }

    private func handle(_ message: Message) throws {
        switch message.type {
        case .welcome:
            delegate?.connection(self, didReceiveWelcome: try message.decodeJSON(Welcome.self))
        case .pairRequest:
            delegate?.connection(self, needsPairingCode: try message.decodeJSON(PairRequest.self))
        case .error:
            let info = try message.decodeJSON(ErrorInfo.self)
            connection.cancel()
            finish(.host(code: info.code, message: info.message))
        case .config:
            delegate?.connection(self, didReceiveConfig: try message.decodeJSON(StreamConfig.self))
        case .video:
            receivedFrames += 1
            delegate?.connection(self, didReceiveFrame: try VideoFrame(message))
        case .ping:
            send(Pong(echoedTime: try Ping(message).time, responderTime: HostClockLite.nowMicros()).message())
        case .pong:
            let pong = try Pong(message)
            let now = HostClockLite.nowMicros()
            guard now >= pong.echoedTime else { return }
            let rtt = now - pong.echoedTime
            // Assume symmetric paths; keep the sample with the lowest RTT (least queueing).
            let improved = rtt <= bestRtt
            if improved { bestRtt = rtt }
            measurements.update {
                $0.rttMicros = rtt
                if improved {
                    $0.clockOffsetMicros = Int64(pong.responderTime) - Int64(pong.echoedTime + rtt / 2)
                }
            }
        case .bye:
            let reason = (try? message.decodeJSON(Bye.self).reason) ?? "bye"
            connection.cancel()
            finish(.closedByHost(reason: reason))
        case .hello, .pair, .keyframeRequest, .ack, .input, .stats:
            break
        }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        send(Ping(time: HostClockLite.nowMicros()).message())
        // Slowly forget the best RTT so the offset can follow clock drift.
        if bestRtt != .max { bestRtt += 200 }

        let now = HostClockLite.nowMicros()
        let seconds = Double(now - windowStart) / 1_000_000
        guard seconds > 0 else { return }
        let extra = statsProvider?()
        let stats = ClientStats(
            fps: Double(receivedFrames) / seconds,
            decodeMs: extra?.decodeMs ?? 0,
            latencyMs: extra?.latencyMs,
            rttMs: measurements.get().rttMicros.map { Double($0) / 1000 },
            droppedFrames: extra?.dropped ?? 0,
            bitrateKbps: Double(receivedBytes * 8) / seconds / 1000
        )
        send(.json(.stats, stats))
        measurements.update { $0.lastStats = stats }
        receivedFrames = 0
        receivedBytes = 0
        windowStart = now
    }

    private func finish(_ error: ClientError?) {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        connection.cancel()
        delegate?.connection(self, didCloseWith: error)
    }
}

/// Same time base as the host's clock on Apple platforms (CLOCK_UPTIME_RAW).
public enum HostClockLite {
    public static func nowMicros() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000
    }
}
