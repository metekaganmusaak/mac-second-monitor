import Darwin
import Foundation
import MSMProtocol

/// Connects to iOS / iPadOS clients over USB through `usbmuxd` (the daemon Finder and Xcode use).
///
/// The iOS app listens on TCP 7100 *on the device*; for every attached device this bridge asks
/// usbmuxd to open a connection to that port and hands the resulting tunnel to the host as a
/// normal message channel. No network is involved.
public final class UsbmuxBridge: @unchecked Sendable {
    public struct Device: Sendable, Equatable, Identifiable {
        public var id: Int
        public var serial: String
        /// A session over this device is running.
        public var connected: Bool
        /// The user ended the session; don't dial again until the cable is replugged or
        /// `reconnect` is called.
        public var paused = false
    }

    private let port: UInt16
    private let lock = NSLock()
    private var running = false
    private var devices: [Int: Device] = [:]
    private var listenSocket: Int32 = -1
    private let connectQueue = DispatchQueue(label: "com.macsecondmonitor.usbmux.connect")

    /// A tunnel to the iOS app is ready.
    public var onChannel: (@Sendable (MessageChannel) -> Void)?
    public var onChange: (@Sendable () -> Void)?

    public init(port: UInt16 = MSMProtocolInfo.nativePort) {
        self.port = port
    }

    public var attachedDevices: [Device] {
        lock.withLock { devices.values.sorted { $0.id < $1.id } }
    }

    public func start() {
        let alreadyRunning = lock.withLock { () -> Bool in
            defer { running = true }
            return running
        }
        guard !alreadyRunning else { return }
        Thread { [weak self] in self?.listenLoop() }.start()
        // Retry devices whose app was not in the foreground yet. Own thread, so it never blocks
        // the connects triggered by Attached events.
        Thread { [weak self] in self?.retryLoop() }.start()
    }

    /// Dials a device again after the user disconnected it.
    public func reconnect(_ deviceID: Int) {
        lock.withLock { devices[deviceID]?.paused = false }
        onChange?()
        connectQueue.async { [weak self] in self?.tryConnect(deviceID) }
    }

    public func stop() {
        let socket = lock.withLock { () -> Int32 in
            running = false
            devices.removeAll()
            defer { listenSocket = -1 }
            return listenSocket
        }
        if socket >= 0 {
            shutdown(socket, SHUT_RDWR)
            close(socket)
        }
    }

    // MARK: Device events

    private func listenLoop() {
        while lock.withLock({ running }) {
            do {
                let socket = try Usbmux.connectToDaemon()
                lock.withLock { listenSocket = socket }
                defer {
                    // Close here unless `stop()` already did.
                    let owned = lock.withLock { () -> Bool in
                        defer { if listenSocket == socket { listenSocket = -1 } }
                        return listenSocket == socket
                    }
                    if owned { close(socket) }
                }
                try Usbmux.send(socket, Usbmux.request("Listen"), tag: 1)
                _ = try Usbmux.expectResult(socket)
                while lock.withLock({ running }) {
                    let message = try Usbmux.receive(socket)
                    handle(message)
                }
            } catch {
                guard lock.withLock({ running }) else { return }
                Log.usb.debug("usbmuxd: \(String(describing: error), privacy: .public)")
                lock.withLock { devices.removeAll() }
                onChange?()
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["MessageType"] as? String {
        case "Attached":
            guard let id = message["DeviceID"] as? Int,
                  let properties = message["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB"
            else { return }
            let serial = properties["SerialNumber"] as? String ?? "\(id)"
            lock.withLock { devices[id] = Device(id: id, serial: serial, connected: false) }
            Log.usb.info("iOS device attached: \(serial, privacy: .public)")
            onChange?()
            connectQueue.async { [weak self] in self?.tryConnect(id) }
        case "Detached":
            guard let id = message["DeviceID"] as? Int else { return }
            lock.withLock { _ = devices.removeValue(forKey: id) }
            onChange?()
        default:
            break
        }
    }

    private func retryLoop() {
        while lock.withLock({ running }) {
            Thread.sleep(forTimeInterval: 2)
            let waiting = lock.withLock { devices.values.filter { !$0.connected && !$0.paused }.map(\.id) }
            for id in waiting {
                connectQueue.sync { tryConnect(id) }
            }
        }
    }

    /// Runs on `connectQueue`.
    private func tryConnect(_ id: Int) {
        guard lock.withLock({ devices[id].map { !$0.connected && !$0.paused } ?? false }) else { return }
        guard let socket = try? Usbmux.connectToDaemon() else { return }
        do {
            try Usbmux.send(socket, Usbmux.request("Connect", ["DeviceID": id, "PortNumber": Int(Usbmux.networkOrder(port))]), tag: 2)
            guard try Usbmux.expectResult(socket) == 0 else {
                // The app isn't listening (not installed or in the background).
                close(socket)
                return
            }
        } catch {
            close(socket)
            return
        }

        Log.usb.info("USB tunnel to iOS device \(id) ready")
        lock.withLock { devices[id]?.connected = true }
        onChange?()
        let channel = SocketMessageChannel(socket: socket, transport: .usb, description: "usbmux:\(id)") { [weak self] reason in
            self?.lock.withLock {
                self?.devices[id]?.connected = false
                // Either side said "user": stay disconnected instead of dialling straight back.
                if reason == "user" { self?.devices[id]?.paused = true }
            }
            self?.onChange?()
        }
        onChannel?(channel)
    }
}

/// The usbmuxd wire format: a 16-byte little-endian header (length, version 1, type 8 = plist,
/// tag) followed by an XML property list.
enum Usbmux {
    static let socketPath = "/var/run/usbmuxd"

    enum Failure: Error {
        case daemonUnavailable
        case closed
        case malformed
    }

    static func request(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
        var message: [String: Any] = [
            "MessageType": type,
            "ClientVersionString": "MacSecondMonitor",
            "ProgName": "MacSecondMonitor",
            "kLibUSBMuxVersion": 3,
        ]
        message.merge(fields) { $1 }
        return message
    }

    /// usbmuxd expects the port in network byte order inside a host-order integer (htons).
    static func networkOrder(_ port: UInt16) -> UInt16 {
        port.bigEndian
    }

    static func encode(_ message: [String: Any], tag: UInt32) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: message, format: .xml, options: 0)
        var data = Data()
        for value in [UInt32(16 + body.count), 1, 8, tag] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(body)
        return data
    }

    static func decodeBody(_ body: Data) throws -> [String: Any] {
        guard let message = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            throw Failure.malformed
        }
        return message
    }

    static func connectToDaemon() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.daemonUnavailable }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let path = Array(socketPath.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw Failure.daemonUnavailable
        }
        return fd
    }

    static func send(_ fd: Int32, _ message: [String: Any], tag: UInt32) throws {
        try SocketIO.write(fd, try encode(message, tag: tag))
    }

    static func receive(_ fd: Int32) throws -> [String: Any] {
        let header = try SocketIO.read(fd, count: 16)
        let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard length >= 16, length < 1 << 20 else { throw Failure.malformed }
        return try decodeBody(try SocketIO.read(fd, count: length - 16))
    }

    /// Reads a `Result` message and returns its `Number` (0 = success).
    static func expectResult(_ fd: Int32) throws -> Int {
        let message = try receive(fd)
        guard message["MessageType"] as? String == "Result", let number = message["Number"] as? Int else {
            throw Failure.malformed
        }
        return number
    }
}

enum SocketIO {
    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Usbmux.Failure.closed }
                offset += written
            }
        }
    }

    static func read(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + offset, count - offset) }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { throw Usbmux.Failure.closed }
            offset += received
        }
        return data
    }
}

/// Framed messages over a connected file descriptor (a usbmux tunnel). A reader thread parses
/// incoming bytes; writes go through a serial queue.
final class SocketMessageChannel: MessageChannel, @unchecked Sendable {
    private let fd: Int32
    private let writeQueue = DispatchQueue(label: "com.macsecondmonitor.socket.write", qos: .userInteractive)
    private let closed = Locked(false)
    private let closeReason = Locked<String?>(nil)
    private let onFinish: @Sendable (String?) -> Void
    let transport: TransportKind
    let remoteDescription: String
    var isHostInitiatedUSB: Bool { true }

    init(socket: Int32, transport: TransportKind, description: String, onFinish: @escaping @Sendable (String?) -> Void) {
        fd = socket
        self.transport = transport
        remoteDescription = description
        self.onFinish = onFinish
        var noDelay: Int32 = 1
        // A no-op for unix sockets; harmless if usbmuxd ever hands out TCP.
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
    }

    func start(queue: DispatchQueue, onMessage: @escaping @Sendable (Message) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        let thread = Thread { [self] in
            var decoder = MessageDecoder()
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            var failure: Error?
            while !closed.current {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break }
                decoder.append(Data(buffer[0..<count]))
                do {
                    while let message = try decoder.next() {
                        queue.async { onMessage(message) }
                    }
                } catch {
                    failure = error
                    break
                }
            }
            let error = failure
            close()
            queue.async { onClose(error) }
        }
        thread.name = "com.macsecondmonitor.socket.read"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func send(_ message: Message, completion: (@Sendable () -> Void)?) {
        let data = message.serialized()
        writeQueue.async { [self] in
            if !closed.current {
                do {
                    try SocketIO.write(fd, data)
                } catch {
                    close()
                }
            }
            completion?()
        }
    }

    func close() {
        let wasClosed = closed.withLock { value -> Bool in
            defer { value = true }
            return value
        }
        guard !wasClosed else { return }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        onFinish(closeReason.current)
    }

    func close(reason: String?) {
        closeReason.withLock { $0 = reason }
        close()
    }
}
