import Foundation
import MSMProtocol
import Network

public enum ListenerStatus: Sendable, Equatable {
    case stopped
    case starting
    case ready
    case failed(String)
}

/// Owns the listeners and all client sessions. Used by both the menu bar app and the CLI.
public final class HostEngine: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        public var hostName: String
        public var nativePort: UInt16 = MSMProtocolInfo.nativePort
        public var webPort: UInt16 = MSMProtocolInfo.webPort
        public var enableWebServer = true
        /// Directory with the built web client.
        public var webRoot: URL?
        public var advertise = true
        /// Network clients must pair once. USB clients are trusted (see `ClientSession.isTrusted`).
        public var requirePairing = true
        /// Extra origins allowed to open the web client's WebSocket (development servers).
        public var extraWebOrigins: Set<String> = []
        public var displayMode: DisplayMode = .extend
        public var quality: StreamQuality = .balanced
        public var fps = 60
        public var preferHEVC = false
        /// Stream synthetic frames instead of a display (development and tests).
        public var testPattern = false
        public var injectInputInTestMode = false

        public init(hostName: String) {
            self.hostName = hostName
        }
    }

    public let trustStore: TrustStore
    let pairingGate = PairingGate()
    private let lock = NSLock()
    private var _options: Options
    private var sessions: [UUID: ClientSession] = [:]
    private var deviceIds: [UUID: String] = [:]
    private var nativeListener: NativeListener?
    private var webServer: WebServer?
    private var _nativeStatus: ListenerStatus = .stopped
    private var _webStatus: ListenerStatus = .stopped

    /// Called on an internal queue (coalesced) when sessions or listener states change.
    public var onChange: (@Sendable () -> Void)?
    private let notifyQueue = DispatchQueue(label: "com.macsecondmonitor.engine.notify")
    private var notifyPending = false
    /// Called when a client could not start because Screen Recording is not granted.
    public var onScreenRecordingPermissionMissing: (@Sendable () -> Void)?

    public init(options: Options, trustStore: TrustStore = TrustStore()) {
        _options = options
        self.trustStore = trustStore
    }

    public var options: Options {
        get { lock.withLock { _options } }
        set { lock.withLock { _options = newValue } }
    }

    public var nativeStatus: ListenerStatus { lock.withLock { _nativeStatus } }
    public var webStatus: ListenerStatus { lock.withLock { _webStatus } }

    /// Applies new options. Listener settings take effect after restarting; stream settings
    /// apply to the next connection.
    public func update(_ options: Options) {
        let restart = lock.withLock { () -> Bool in
            let old = _options
            _options = options
            return old.nativePort != options.nativePort || old.webPort != options.webPort
                || old.enableWebServer != options.enableWebServer || old.advertise != options.advertise
                || old.hostName != options.hostName || old.webRoot != options.webRoot
                || old.extraWebOrigins != options.extraWebOrigins
        }
        if restart, nativeListener != nil {
            stop()
            try? start()
        }
    }

    public func start() throws {
        let options = self.options
        let native = try NativeListener(port: options.nativePort, webPort: options.webPort, serviceName: options.hostName, advertise: options.advertise)
        native.onChannel = { [weak self] channel in self?.accept(channel) }
        native.onStateChange = { [weak self] state in self?.setStatus(state, web: false) }
        setStatus(.setup, web: false)
        native.start()
        nativeListener = native

        if options.enableWebServer {
            do {
                let web = try WebServer(port: options.webPort, root: options.webRoot, extraOrigins: options.extraWebOrigins)
                web.onChannel = { [weak self] channel in self?.accept(channel) }
                web.onStateChange = { [weak self] state in self?.setStatus(state, web: true) }
                web.start()
                webServer = web
            } catch {
                lock.withLock { _webStatus = .failed(error.localizedDescription) }
            }
        }
    }

    /// Tells every client the host is going away (BYE `shutdown`) and stops listening.
    /// - Parameter timeout: how long to block until the BYEs are out. Pass a short timeout when
    ///   the process is about to exit, so clients don't mistake the exit for a network drop.
    public func stop(waitingUpTo timeout: TimeInterval = 0) {
        nativeListener?.stop()
        webServer?.stop()
        nativeListener = nil
        webServer = nil
        lock.withLock {
            _nativeStatus = .stopped
            _webStatus = .stopped
        }
        let group = DispatchGroup()
        for session in lock.withLock({ Array(sessions.values) }) {
            group.enter()
            session.disconnect(reason: "shutdown") { group.leave() }
        }
        if timeout > 0 {
            _ = group.wait(timeout: .now() + timeout)
        }
        notify()
    }

    public func snapshots() -> [SessionSnapshot] {
        lock.withLock { Array(sessions.values) }
            .map { $0.snapshot() }
            .sorted { $0.connectedAt < $1.connectedAt }
    }

    /// `reason` is sent in BYE: clients stay disconnected after `user` and reconnect otherwise.
    public func disconnect(_ id: UUID, reason: String = "user") {
        lock.withLock { sessions[id] }?.disconnect(reason: reason)
    }

    /// Starts a session on a channel opened elsewhere (e.g. a usbmux tunnel to an iOS device).
    public func adopt(_ channel: MessageChannel) {
        accept(channel)
    }

    // MARK: Session callbacks

    private func accept(_ channel: MessageChannel) {
        let session = ClientSession(channel: channel, engine: self, options: options)
        lock.withLock { sessions[session.id] = session }
        Log.net.info("New connection from \(channel.remoteDescription, privacy: .public)")
        session.start()
        notify()
    }

    /// One device, one display: a reconnecting device replaces its stale session.
    func sessionIdentified(_ session: ClientSession, deviceId: String) {
        let stale = lock.withLock { () -> [ClientSession] in
            let ids = deviceIds.filter { $0.key != session.id && $0.value == deviceId }.map(\.key)
            deviceIds[session.id] = deviceId
            return ids.compactMap { sessions[$0] }
        }
        for old in stale {
            old.disconnect(reason: "replaced")
        }
    }

    func sessionChanged() {
        notify()
    }

    func sessionEnded(_ session: ClientSession) {
        lock.withLock {
            sessions.removeValue(forKey: session.id)
            deviceIds.removeValue(forKey: session.id)
        }
        notify()
    }

    /// Sessions call this from their own queue, so the callback must never run inline:
    /// `snapshots()` syncs onto every session queue.
    private func notify() {
        let schedule = lock.withLock { () -> Bool in
            defer { notifyPending = true }
            return !notifyPending
        }
        guard schedule else { return }
        notifyQueue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.notifyPending = false }
            self.onChange?()
        }
    }

    func reportMissingScreenRecordingPermission() {
        onScreenRecordingPermissionMissing?()
    }

    private func setStatus(_ state: NWListener.State, web: Bool) {
        let status: ListenerStatus? = switch state {
        case .setup, .waiting: .starting
        case .ready: .ready
        case let .failed(error): .failed(error.localizedDescription)
        case .cancelled: .stopped
        @unknown default: nil
        }
        guard let status else { return }
        lock.withLock {
            if web { _webStatus = status } else { _nativeStatus = status }
        }
        notify()
    }
}
