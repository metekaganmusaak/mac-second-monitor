import CryptoKit
import Foundation
import MSMProtocol
import Network

/// RFC 6455 server side. Each binary WebSocket message carries one protocol message.
public final class WebSocketMessageChannel: MessageChannel, @unchecked Sendable {
    private enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    private let connection: NWConnection
    /// Bytes read past the HTTP upgrade request.
    private var buffer: Data
    private var fragments = Data()
    private var decoder = MessageDecoder()
    private var callbackQueue: DispatchQueue?
    private var onMessage: (@Sendable (Message) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?
    private var closed = false
    public let transport: TransportKind

    /// `connection` must already be started; `leftover` holds bytes received after the handshake.
    init(connection: NWConnection, leftover: Data) {
        self.connection = connection
        buffer = leftover
        // A browser on this Mac is not a USB device: loopback WebSockets still have to pair.
        let detected = NetworkParameters.transport(for: connection)
        transport = detected == .usb ? .local : detected
    }

    public var remoteDescription: String { "ws://\(connection.endpoint)" }

    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    public func start(queue: DispatchQueue, onMessage: @escaping @Sendable (Message) -> Void, onClose: @escaping @Sendable (Error?) -> Void) {
        callbackQueue = queue
        self.onMessage = onMessage
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error): self?.finish(error)
            case .cancelled: self?.finish(nil)
            default: break
            }
        }
        processBuffer()
        receive()
    }

    public func send(_ message: Message, completion: (@Sendable () -> Void)?) {
        sendFrame(opcode: .binary, payload: message.serialized(), completion: completion)
    }

    public func close() {
        sendFrame(opcode: .close, payload: Data([0x03, 0xE8]), completion: nil)
        connection.cancel()
    }

    private func sendFrame(opcode: Opcode, payload: Data, completion: (@Sendable () -> Void)?) {
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode.rawValue)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.finish(error)
            }
            completion?()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data {
                self.buffer.append(data)
                self.processBuffer()
            }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else if !self.closed {
                self.receive()
            }
        }
    }

    private func processBuffer() {
        while let (opcode, payload, consumed) = parseFrame() {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed))
            handle(opcode: opcode, payload: payload)
            if closed { return }
        }
    }

    /// Returns (opcode, unmasked payload, bytes consumed) for the first complete frame.
    private func parseFrame() -> ((opcode: UInt8, fin: Bool), Data, Int)? {
        let bytes = buffer
        guard bytes.count >= 2 else { return nil }
        let start = bytes.startIndex
        let first = bytes[start]
        let second = bytes[start + 1]
        var length = UInt64(second & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = UInt64(bytes[start + 2]) << 8 | UInt64(bytes[start + 3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = 0
            for index in 0..<8 {
                length = length << 8 | UInt64(bytes[start + 2 + index])
            }
            offset = 10
        }
        guard length <= UInt64(MSMProtocolInfo.maxPayloadSize + MSMProtocolInfo.headerSize) else {
            finish(ProtocolError.payloadTooLarge(Int(clamping: length)))
            connection.cancel()
            return nil
        }
        let masked = second & 0x80 != 0
        let maskOffset = offset
        if masked { offset += 4 }
        guard bytes.count >= offset + Int(length) else { return nil }

        var payload = Data(bytes[(start + offset)..<(start + offset + Int(length))])
        if masked {
            let mask = Array(bytes[(start + maskOffset)..<(start + maskOffset + 4)])
            payload.withUnsafeMutableBytes { raw in
                for index in 0..<raw.count {
                    raw[index] ^= mask[index & 3]
                }
            }
        }
        return ((first & 0x0F, first & 0x80 != 0), payload, offset + Int(length))
    }

    private func handle(opcode header: (opcode: UInt8, fin: Bool), payload: Data) {
        guard let opcode = Opcode(rawValue: header.opcode) else {
            close()
            return
        }
        switch opcode {
        case .binary, .text, .continuation:
            guard fragments.count + payload.count <= MSMProtocolInfo.maxPayloadSize + MSMProtocolInfo.headerSize else {
                finish(ProtocolError.payloadTooLarge(fragments.count + payload.count))
                connection.cancel()
                return
            }
            fragments.append(payload)
            guard header.fin else { return }
            decoder.append(fragments)
            fragments.removeAll(keepingCapacity: true)
            do {
                while let message = try decoder.next() {
                    if let onMessage, let callbackQueue {
                        callbackQueue.async { onMessage(message) }
                    }
                }
            } catch {
                finish(error)
                connection.cancel()
            }
        case .ping:
            sendFrame(opcode: .pong, payload: payload, completion: nil)
        case .pong:
            break
        case .close:
            sendFrame(opcode: .close, payload: Data(), completion: nil)
            connection.cancel()
            finish(nil)
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        let onClose = onClose
        self.onClose = nil
        onMessage = nil
        if let onClose, let callbackQueue {
            callbackQueue.async { onClose(error) }
        }
    }
}
