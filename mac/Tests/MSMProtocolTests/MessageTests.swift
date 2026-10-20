import Foundation
import Testing
@testable import MSMProtocol

@Suite struct MessageFramingTests {
    @Test func headerLayoutIsBigEndian() {
        let message = Message(type: .video, flags: 0x01, payload: Data([0xAA, 0xBB, 0xCC]))
        #expect(Array(message.serialized()) == [0x11, 0x01, 0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC])
    }

    @Test func decodesMessagesSplitAcrossChunks() throws {
        let first = Message(type: .ping, payload: Data(repeating: 7, count: 8))
        let second = Message(type: .bye, payload: Data("{}".utf8))
        let stream = first.serialized() + second.serialized()

        var decoder = MessageDecoder()
        var decoded: [Message] = []
        for byte in stream {
            decoder.append(Data([byte]))
            while let message = try decoder.next() {
                decoded.append(message)
            }
        }
        #expect(decoded == [first, second])
    }

    @Test func skipsUnknownMessageTypes() throws {
        var unknown = ByteWriter()
        unknown.u8(0x6E)
        unknown.u8(0)
        unknown.u32(2)
        unknown.bytes(Data([1, 2]))
        let known = Message(type: .keyframeRequest)

        var decoder = MessageDecoder()
        decoder.append(unknown.data + known.serialized())
        #expect(try decoder.next() == known)
        #expect(try decoder.next() == nil)
    }

    @Test func rejectsOversizedPayload() {
        var writer = ByteWriter()
        writer.u8(MessageType.video.rawValue)
        writer.u8(0)
        writer.u32(UInt32(MSMProtocolInfo.maxPayloadSize + 1))

        var decoder = MessageDecoder()
        decoder.append(writer.data)
        #expect(throws: ProtocolError.payloadTooLarge(MSMProtocolInfo.maxPayloadSize + 1)) {
            try decoder.next()
        }
    }

    @Test func compactsLargeStreams() throws {
        var decoder = MessageDecoder()
        let message = Message(type: .video, payload: Data(repeating: 1, count: 40_000))
        for _ in 0..<10 {
            decoder.append(message.serialized())
            #expect(try decoder.next() == message)
        }
        #expect(try decoder.next() == nil)
    }
}

@Suite struct PayloadTests {
    @Test func helloUsesProtocolKey() throws {
        let hello = Hello(
            deviceId: "id",
            deviceName: "MatePad 11",
            platform: "android",
            appVersion: "0.1.0",
            display: DisplayInfo(width: 2560, height: 1600, dpi: 276, refreshRate: 120),
            codecs: ["h264"]
        )
        let message = Message.json(.hello, hello)
        let json = try #require(String(data: message.payload, encoding: .utf8))
        #expect(json.contains("\"protocol\":1"))
        #expect(try message.decodeJSON(Hello.self) == hello)
    }

    @Test func videoFrameRoundTrip() throws {
        let frame = VideoFrame(seq: 42, captureTimeMicros: 123_456_789, isKeyframe: true, data: Data([0, 0, 0, 1, 0x67]))
        let message = frame.message()
        #expect(message.flags == VideoFrame.keyframeFlag)
        #expect(try VideoFrame(message) == frame)
    }

    @Test func pingPongAckRoundTrip() throws {
        #expect(try Ping(Ping(time: 99).message()) == Ping(time: 99))
        #expect(try Pong(Pong(echoedTime: 1, responderTime: 2).message()) == Pong(echoedTime: 1, responderTime: 2))
        #expect(try FrameAck(FrameAck(seq: 7).message()) == FrameAck(seq: 7))
    }

    @Test(arguments: [
        InputEvent.pointer(action: .down, button: .right, tool: .stylus, x: 0.25, y: 0.75, pressure: 0.5),
        InputEvent.scroll(phase: .changed, unit: .normalized, x: 0.5, y: 0.5, dx: -0.01, dy: 0.02),
        InputEvent.key(action: .down, usage: 0x04, modifiers: [.command, .shift]),
        InputEvent.text("Merhaba, dünya! 👋"),
    ])
    func inputRoundTrip(event: InputEvent) throws {
        #expect(try InputEvent(event.message()) == event)
    }

    @Test func pointerWireLayout() {
        let payload = InputEvent.pointer(action: .up, button: .left, tool: .finger, x: 1, y: 0, pressure: 1).message().payload
        #expect(payload.count == 17)
        #expect(Array(payload.prefix(5)) == [0x01, 0x02, 0x00, 0x01, 0x00])
        #expect(Array(payload[5..<9]) == [0x3F, 0x80, 0x00, 0x00])
    }

    @Test func truncatedPayloadThrows() {
        #expect(throws: ProtocolError.truncated) {
            try VideoFrame(Message(type: .video, payload: Data([0, 0, 0])))
        }
    }
}
