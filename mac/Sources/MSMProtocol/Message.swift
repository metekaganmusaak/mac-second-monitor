import Foundation

/// Constants shared by the host and every client. See docs/PROTOCOL.md.
public enum MSMProtocolInfo {
    public static let version = 1
    /// Raw TCP port for native clients (also the USB tunnel port).
    public static let nativePort: UInt16 = 7100
    /// HTTP + WebSocket port for the web client.
    public static let webPort: UInt16 = 7101
    public static let bonjourServiceType = "_macsecondmon._tcp"
    public static let headerSize = 6
    public static let maxPayloadSize = 16 * 1024 * 1024
}

public enum MessageType: UInt8, Sendable, CaseIterable {
    case hello = 0x01
    case welcome = 0x02
    case pairRequest = 0x03
    case pair = 0x04
    case error = 0x05

    case config = 0x10
    case video = 0x11
    case keyframeRequest = 0x12
    case ack = 0x13

    case input = 0x20

    case ping = 0x30
    case pong = 0x31
    case stats = 0x32

    case bye = 0x7F
}

/// One framed protocol message: `type: u8, flags: u8, length: u32 BE, payload`.
public struct Message: Sendable, Equatable {
    public var type: MessageType
    public var flags: UInt8
    public var payload: Data

    public init(type: MessageType, flags: UInt8 = 0, payload: Data = Data()) {
        self.type = type
        self.flags = flags
        self.payload = payload
    }

    /// Header and payload, ready to be written to a byte stream or a WebSocket message.
    public func serialized() -> Data {
        var writer = ByteWriter(capacity: MSMProtocolInfo.headerSize + payload.count)
        writer.u8(type.rawValue)
        writer.u8(flags)
        writer.u32(UInt32(payload.count))
        writer.bytes(payload)
        return writer.data
    }
}

/// Incremental parser for a stream of framed messages.
///
/// Messages with an unknown type are skipped, so older peers keep working when
/// new message types are added.
public struct MessageDecoder: Sendable {
    private var buffer = Data()
    private var readOffset = 0

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Returns the next complete message, or nil if more bytes are needed.
    public mutating func next() throws -> Message? {
        while true {
            let available = buffer.count - readOffset
            guard available >= MSMProtocolInfo.headerSize else {
                compact()
                return nil
            }

            let start = buffer.startIndex + readOffset
            let rawType = buffer[start]
            let flags = buffer[start + 1]
            let length = Int(buffer[start + 2]) << 24
                | Int(buffer[start + 3]) << 16
                | Int(buffer[start + 4]) << 8
                | Int(buffer[start + 5])
            guard length <= MSMProtocolInfo.maxPayloadSize else {
                throw ProtocolError.payloadTooLarge(length)
            }
            guard available >= MSMProtocolInfo.headerSize + length else {
                compact()
                return nil
            }

            let payloadStart = start + MSMProtocolInfo.headerSize
            let payload = Data(buffer[payloadStart..<(payloadStart + length)])
            readOffset += MSMProtocolInfo.headerSize + length

            if let type = MessageType(rawValue: rawType) {
                return Message(type: type, flags: flags, payload: payload)
            }
        }
    }

    private mutating func compact() {
        guard readOffset > 0 else { return }
        if readOffset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readOffset = 0
        } else if readOffset >= 64 * 1024 {
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + readOffset))
            readOffset = 0
        }
    }
}

// MARK: - JSON payloads

extension Message {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static func json<T: Encodable>(_ type: MessageType, _ value: T) -> Message {
        // Encoding plain value types defined in this module cannot fail.
        let payload = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return Message(type: type, payload: payload)
    }

    public func decodeJSON<T: Decodable>(_: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: payload)
        } catch {
            throw ProtocolError.invalidPayload("\(type): \(error)")
        }
    }
}
