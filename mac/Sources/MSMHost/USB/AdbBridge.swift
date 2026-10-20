import Darwin
import Foundation
import MSMProtocol

/// An Android device seen by the ADB server.
public struct AdbDevice: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        /// Ready; the USB tunnel can be set up.
        case device
        /// The user still has to accept the "Allow USB debugging?" prompt.
        case unauthorized
        case offline
        case other(String)
    }

    public enum Bridge: Sendable, Equatable {
        case waiting
        /// `adb reverse` is active; the client can connect to localhost.
        case ready
        case failed(String)
    }

    public var id: String { serial }
    public var serial: String
    public var state: State
    public var model: String?
    public var bridge: Bridge = .waiting
    /// Whether the Android client app is installed, once known.
    public var clientInstalled: Bool?
    /// `versionCode` of the installed app, to offer updates.
    public var clientVersionCode: Int?

    public var displayName: String {
        model?.replacingOccurrences(of: "_", with: " ") ?? serial
    }

    public init(serial: String, state: State, model: String?, bridge: Bridge = .waiting, clientInstalled: Bool? = nil, clientVersionCode: Int? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.bridge = bridge
        self.clientInstalled = clientInstalled
        self.clientVersionCode = clientVersionCode
    }
}

public enum AdbStatus: Sendable, Equatable {
    case disabled
    /// No `adb` binary was found.
    case notFound
    case starting
    case running
    case failed(String)
}

/// Turns USB-connected Android devices into displays: watches the ADB server, sets up
/// `adb reverse tcp:7100 tcp:7100` for every authorized device and optionally launches
/// the client app. The client then connects to 127.0.0.1 and its traffic flows over USB.
public final class AdbBridge: @unchecked Sendable {
    public struct Options: Sendable, Equatable {
        public var adbPath: String?
        public var port: UInt16 = MSMProtocolInfo.nativePort
        public var launchClient = true
        /// Passed to the app when launching it; the app presents it in HELLO over the tunnel.
        public var secret: String?

        public init() {}
    }

    public static let clientPackage = "com.macsecondmonitor.client"
    public static let clientActivity = "com.macsecondmonitor.client/.ui.UsbConnectActivity"
    public static let usbAction = "com.macsecondmonitor.client.action.USB_CONNECT"
    public static let secretExtra = "com.macsecondmonitor.client.extra.SECRET"

    private let lock = NSLock()
    private var options: Options
    private var _devices: [String: AdbDevice] = [:]
    private var _status: AdbStatus = .disabled
    private var running = false
    private var socket: AdbSocket?
    private var thread: Thread?
    private let commandQueue = DispatchQueue(label: "com.macsecondmonitor.adb.commands")

    public var onChange: (@Sendable () -> Void)?

    public init(options: Options = Options()) {
        self.options = options
    }

    public var devices: [AdbDevice] {
        lock.withLock { _devices.values.sorted { $0.serial < $1.serial } }
    }

    public var status: AdbStatus { lock.withLock { _status } }

    public var adbPath: String? {
        Self.locateAdb(preferred: lock.withLock { options.adbPath })
    }

    public func update(_ options: Options) {
        lock.withLock { self.options = options }
    }

    public func start() {
        let alreadyRunning = lock.withLock { () -> Bool in
            defer { running = true }
            return running
        }
        guard !alreadyRunning else { return }
        setStatus(.starting)
        let thread = Thread { [weak self] in self?.trackLoop() }
        thread.name = "com.macsecondmonitor.adb.track"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        let socket = lock.withLock { () -> AdbSocket? in
            running = false
            _devices.removeAll()
            return self.socket
        }
        socket?.close()
        setStatus(.disabled)
    }

    /// Installs (or updates) the Android client from a bundled APK.
    public func install(apk: URL, on serial: String) async throws {
        guard let adb = adbPath else { throw AdbError.notFound }
        let result = try await Self.run(adb, ["-s", serial, "install", "-r", apk.path], timeout: 180)
        guard result.status == 0, result.output.contains("Success") else {
            throw AdbError.commandFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        refreshClientState(serial)
    }

    /// Opens the client app on the device; it connects through the tunnel by itself.
    public func launchClient(on serial: String) {
        guard let adb = adbPath else { return }
        let secret = lock.withLock { options.secret }
        commandQueue.async {
            _ = try? Self.runSync(adb, Self.launchArguments(serial: serial, secret: secret), timeout: 15)
        }
    }

    static func launchArguments(serial: String, secret: String?) -> [String] {
        var arguments = ["-s", serial, "shell", "am", "start", "-a", usbAction, "-n", clientActivity]
        if let secret {
            arguments += ["--es", secretExtra, secret]
        }
        return arguments
    }

    // MARK: Device tracking

    private func trackLoop() {
        var backoff: TimeInterval = 1
        while lock.withLock({ running }) {
            guard let adb = adbPath else {
                setStatus(.notFound)
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            do {
                let socket = try connectToServer(adb: adb)
                lock.withLock { self.socket = socket }
                setStatus(.running)
                backoff = 1
                try track(socket)
            } catch {
                guard lock.withLock({ running }) else { break }
                Log.usb.info("ADB tracking interrupted: \(String(describing: error), privacy: .public)")
                setStatus(.failed(String(describing: error)))
                lock.withLock { _devices.removeAll() }
                onChange?()
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 10)
            }
        }
    }

    private func connectToServer(adb: String) throws -> AdbSocket {
        if let socket = try? AdbSocket.connect() {
            return socket
        }
        // The server is not running yet; the CLI starts it as a daemon.
        _ = try Self.runSync(adb, ["start-server"], timeout: 20)
        return try AdbSocket.connect()
    }

    private func track(_ socket: AdbSocket) throws {
        try socket.send("host:track-devices-l")
        try socket.expectOkay()
        while lock.withLock({ running }) {
            let payload = try socket.readLengthPrefixed()
            apply(Self.parseDeviceList(payload))
        }
    }

    static func parseDeviceList(_ text: String) -> [AdbDevice] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { return nil }
            let state: AdbDevice.State = switch fields[1] {
            case "device": .device
            case "unauthorized": .unauthorized
            case "offline": .offline
            default: .other(String(fields[1]))
            }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst("model:".count)) }
            return AdbDevice(serial: String(fields[0]), state: state, model: model)
        }
    }

    private func apply(_ list: [AdbDevice]) {
        var needsBridge: [String] = []
        lock.withLock {
            var updated: [String: AdbDevice] = [:]
            for var device in list {
                if let previous = _devices[device.serial], previous.state == device.state {
                    device.bridge = previous.bridge
                    device.clientInstalled = previous.clientInstalled
                    device.clientVersionCode = previous.clientVersionCode
                } else if device.state == .device {
                    needsBridge.append(device.serial)
                }
                updated[device.serial] = device
            }
            _devices = updated
        }
        onChange?()
        for serial in needsBridge {
            setUpBridge(serial)
        }
    }

    private func setUpBridge(_ serial: String) {
        guard let adb = adbPath else { return }
        let options = lock.withLock { self.options }
        commandQueue.async { [weak self] in
            guard let self else { return }
            let port = "tcp:\(options.port)"
            do {
                let result = try Self.runSync(adb, ["-s", serial, "reverse", port, port], timeout: 15)
                if result.status == 0 {
                    Log.usb.info("USB tunnel ready for \(serial, privacy: .public)")
                    self.updateDevice(serial) { $0.bridge = .ready }
                } else {
                    self.updateDevice(serial) { $0.bridge = .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    return
                }
            } catch {
                self.updateDevice(serial) { $0.bridge = .failed(String(describing: error)) }
                return
            }

            let version = Self.installedVersionCode(adb: adb, serial: serial)
            let installed = version != nil
            self.updateDevice(serial) {
                $0.clientInstalled = installed
                $0.clientVersionCode = version
            }
            if installed, options.launchClient {
                _ = try? Self.runSync(adb, Self.launchArguments(serial: serial, secret: options.secret), timeout: 15)
            }
        }
    }

    private func refreshClientState(_ serial: String) {
        guard let adb = adbPath else { return }
        commandQueue.async { [weak self] in
            let version = Self.installedVersionCode(adb: adb, serial: serial)
            self?.updateDevice(serial) {
                $0.clientInstalled = version != nil
                $0.clientVersionCode = version
            }
        }
    }

    /// nil when the app isn't installed.
    private static func installedVersionCode(adb: String, serial: String) -> Int? {
        guard let result = try? runSync(adb, ["-s", serial, "shell", "dumpsys", "package", clientPackage], timeout: 15) else { return nil }
        return parseVersionCode(result.output)
    }

    /// Reads `versionCode=N` from `dumpsys package` output.
    static func parseVersionCode(_ dumpsys: String) -> Int? {
        guard let range = dumpsys.range(of: "versionCode=") else { return nil }
        return Int(dumpsys[range.upperBound...].prefix { $0.isNumber })
    }

    private func updateDevice(_ serial: String, _ change: (inout AdbDevice) -> Void) {
        lock.withLock {
            if var device = _devices[serial] {
                change(&device)
                _devices[serial] = device
            }
        }
        onChange?()
    }

    private func setStatus(_ status: AdbStatus) {
        let changed = lock.withLock { () -> Bool in
            defer { _status = status }
            return _status != status
        }
        if changed { onChange?() }
    }

    // MARK: adb binary

    static func locateAdb(preferred: String?) -> String? {
        var candidates: [String] = []
        if let preferred, !preferred.isEmpty { candidates.append(preferred) }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("platform-tools/adb").path {
            candidates.append(bundled)
        }
        let environment = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let root = environment[key] { candidates.append("\(root)/platform-tools/adb") }
        }
        candidates.append(NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb")
        candidates.append(contentsOf: ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/adb" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    struct CommandResult {
        var status: Int32
        var output: String
    }

    static func runSync(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Read without blocking on EOF: a server spawned by adb could inherit the pipe.
        let output = Locked(Data())
        let endOfFile = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                endOfFile.signal()
            } else {
                output.withLock { $0.append(chunk) }
            }
        }
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            throw AdbError.timeout
        }
        _ = endOfFile.wait(timeout: .now() + 1)
        pipe.fileHandleForReading.readabilityHandler = nil
        return CommandResult(status: process.terminationStatus, output: String(decoding: output.current, as: UTF8.self))
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runSync(executable, arguments, timeout: timeout) })
            }
        }
    }
}

public enum AdbError: Error, LocalizedError {
    case notFound
    case connectionFailed
    case protocolError(String)
    case commandFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notFound: L10n.tr("usb.adb.notFound")
        case .connectionFailed: L10n.tr("usb.adb.connectionFailed")
        case let .protocolError(message), let .commandFailed(message): message
        case .timeout: L10n.tr("usb.adb.timeout")
        }
    }
}

/// Minimal blocking client for the ADB server's smart-socket protocol (127.0.0.1:5037).
final class AdbSocket: @unchecked Sendable {
    private let fd: Int32
    private let closed = Locked(false)

    private init(fd: Int32) {
        self.fd = fd
    }

    static func connect(port: UInt16 = 5037) throws -> AdbSocket {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AdbError.connectionFailed }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw AdbError.connectionFailed
        }
        return AdbSocket(fd: fd)
    }

    deinit {
        close()
    }

    func close() {
        let wasClosed = closed.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !wasClosed else { return }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    func send(_ request: String) throws {
        let body = Data(request.utf8)
        try write(Data(String(format: "%04x", body.count).utf8) + body)
    }

    func expectOkay() throws {
        let status = String(decoding: try read(count: 4), as: UTF8.self)
        guard status == "OKAY" else {
            let message = (try? readLengthPrefixed()) ?? status
            throw AdbError.protocolError(message)
        }
    }

    func readLengthPrefixed() throws -> String {
        let lengthText = String(decoding: try read(count: 4), as: UTF8.self)
        guard let length = Int(lengthText, radix: 16) else {
            throw AdbError.protocolError("bad length \(lengthText)")
        }
        return String(decoding: try read(count: length), as: UTF8.self)
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw AdbError.connectionFailed }
                offset += written
            }
        }
    }

    private func read(count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { buffer in
                Darwin.read(fd, buffer.baseAddress! + offset, count - offset)
            }
            guard received > 0 else { throw AdbError.connectionFailed }
            offset += received
        }
        return data
    }
}
