import Foundation

/// VIDEO (host → client): one encoded access unit in Annex-B format.
///
/// Payload: `seq: u32, captureTime: u64 (µs, host clock), data`. Header flag bit 0 marks a
/// keyframe; keyframes start with the codec's parameter sets.
public struct VideoFrame: Sendable, Equatable {
    public static let keyframeFlag: UInt8 = 0x01
    public static let headerSize = 12

    public var seq: UInt32
    public var captureTimeMicros: UInt64
    public var isKeyframe: Bool
    public var data: Data

    public init(seq: UInt32, captureTimeMicros: UInt64, isKeyframe: Bool, data: Data) {
        self.seq = seq
        self.captureTimeMicros = captureTimeMicros
        self.isKeyframe = isKeyframe
        self.data = data
    }

    public init(_ message: Message) throws {
        var reader = ByteReader(message.payload)
        seq = try reader.u32()
        captureTimeMicros = try reader.u64()
        isKeyframe = message.flags & Self.keyframeFlag != 0
        data = reader.rest()
    }

    public func message() -> Message {
        var writer = ByteWriter(capacity: Self.headerSize + data.count)
        writer.u32(seq)
        writer.u64(captureTimeMicros)
        writer.bytes(data)
        return Message(type: .video, flags: isKeyframe ? Self.keyframeFlag : 0, payload: writer.data)
    }
}

/// ACK (client → host): the frame with this sequence number reached the decoder.
public struct FrameAck: Sendable, Equatable {
    public var seq: UInt32

    public init(seq: UInt32) {
        self.seq = seq
    }

    public init(_ message: Message) throws {
        var reader = ByteReader(message.payload)
        seq = try reader.u32()
    }

    public func message() -> Message {
        var writer = ByteWriter(capacity: 4)
        writer.u32(seq)
        return Message(type: .ack, payload: writer.data)
    }
}

/// PING (both directions): `time: u64` in the sender's clock (µs).
public struct Ping: Sendable, Equatable {
    public var time: UInt64

    public init(time: UInt64) {
        self.time = time
    }

    public init(_ message: Message) throws {
        var reader = ByteReader(message.payload)
        time = try reader.u64()
    }

    public func message() -> Message {
        var writer = ByteWriter(capacity: 8)
        writer.u64(time)
        return Message(type: .ping, payload: writer.data)
    }
}

/// PONG: echoes the PING time and adds the responder's clock (µs).
public struct Pong: Sendable, Equatable {
    public var echoedTime: UInt64
    public var responderTime: UInt64

    public init(echoedTime: UInt64, responderTime: UInt64) {
        self.echoedTime = echoedTime
        self.responderTime = responderTime
    }

    public init(_ message: Message) throws {
        var reader = ByteReader(message.payload)
        echoedTime = try reader.u64()
        responderTime = try reader.u64()
    }

    public func message() -> Message {
        var writer = ByteWriter(capacity: 16)
        writer.u64(echoedTime)
        writer.u64(responderTime)
        return Message(type: .pong, payload: writer.data)
    }
}
