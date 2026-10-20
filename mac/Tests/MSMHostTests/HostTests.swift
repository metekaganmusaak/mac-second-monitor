import CoreGraphics
import CoreVideo
import Foundation
import MSMClientKit
import MSMProtocol
import Testing
@testable import MSMHost

@Suite struct AnnexBTests {
    @Test func convertsLengthPrefixedUnits() throws {
        let avcc: [UInt8] = [0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 1, 0x06]
        var output = Data()
        let ok = avcc.withUnsafeBytes { bytes in AnnexB.appendConvertingLengthPrefixed(bytes, lengthSize: 4, to: &output) }
        #expect(ok)
        #expect(Array(output) == [0, 0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x06])
    }

    @Test func rejectsTruncatedUnits() {
        let avcc: [UInt8] = [0, 0, 0, 9, 0x65]
        var output = Data()
        let ok = avcc.withUnsafeBytes { bytes in AnnexB.appendConvertingLengthPrefixed(bytes, lengthSize: 4, to: &output) }
        #expect(!ok)
    }

    @Test func h264CodecString() {
        #expect(AnnexB.h264CodecString(sps: Data([0x67, 0x64, 0x0C, 0x33, 0xAC])) == "avc1.640C33")
    }

    @Test func hevcCodecString() {
        // Main profile, main tier, level 5.1 (153), progressive + frame-only constraint flags.
        let sps = Data([0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x99])
        #expect(AnnexB.hevcCodecString(sps: sps) == "hvc1.1.6.L153.90")
    }

    @Test func removesEmulationPrevention() {
        #expect(AnnexB.removingEmulationPrevention([0, 0, 3, 1, 0, 0, 3, 0]) == [0, 0, 1, 0, 0, 0])
    }
}

@Suite struct InputMappingTests {
    @Test func mapsNormalizedPointsInsideDisplay() {
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 1512, y: 0, width: 1280, height: 800))
        #expect(mapper.point(x: 0, y: 0) == CGPoint(x: 1512, y: 0))
        #expect(mapper.point(x: 0.5, y: 0.5) == CGPoint(x: 2152, y: 400))
        // Never past the last point, or the cursor would jump to a neighbouring display.
        #expect(mapper.point(x: 1, y: 1) == CGPoint(x: 2791, y: 799))
        #expect(mapper.point(x: 2, y: -1) == CGPoint(x: 2791, y: 0))
        let delta = mapper.delta(dx: 0.1, dy: -0.25)
        #expect(abs(delta.width - 128) < 0.001 && abs(delta.height + 200) < 0.001)
    }

    @Test func letterboxedMirror() {
        // A 16:10 Mac mirrored onto a 4:3 tablet: bars at the top and bottom.
        let content = CoordinateMapper.aspectFit(source: CGSize(width: 1600, height: 1000), into: CGSize(width: 2048, height: 1536))
        #expect(abs(content.minX) < 1e-9)
        #expect(abs(content.height - 0.8333) < 0.001)
        let mapper = CoordinateMapper(displayBounds: CGRect(x: 0, y: 0, width: 1600, height: 1000), contentRect: content)
        #expect(mapper.point(x: 0.5, y: 0.5) == CGPoint(x: 800, y: 500))
        #expect(mapper.point(x: 0, y: 0.02) == CGPoint(x: 0, y: 0))
    }

    @Test func countsDoubleClicks() {
        var tracker = ClickTracker()
        #expect(tracker.register(.left, at: .zero, time: 1.0, interval: 0.5) == 1)
        #expect(tracker.register(.left, at: CGPoint(x: 3, y: 2), time: 1.2, interval: 0.5) == 2)
        #expect(tracker.register(.left, at: CGPoint(x: 3, y: 2), time: 1.4, interval: 0.5) == 3)
        #expect(tracker.register(.left, at: CGPoint(x: 3, y: 2), time: 2.5, interval: 0.5) == 1)
        #expect(tracker.register(.right, at: CGPoint(x: 3, y: 2), time: 2.6, interval: 0.5) == 1)
        #expect(tracker.register(.right, at: CGPoint(x: 80, y: 2), time: 2.7, interval: 0.5) == 1)
    }

    @Test func hidUsagesMapToMacKeyCodes() {
        #expect(HIDKeyMap.keyCode(forUsage: 0x04) == 0x00) // A
        #expect(HIDKeyMap.keyCode(forUsage: 0x1D) == 0x06) // Z
        #expect(HIDKeyMap.keyCode(forUsage: 0x28) == 0x24) // Return
        #expect(HIDKeyMap.keyCode(forUsage: 0x2A) == 0x33) // Backspace
        #expect(HIDKeyMap.keyCode(forUsage: 0x52) == 0x7E) // Up
        #expect(HIDKeyMap.keyCode(forUsage: 0xE3) == 0x37) // Left GUI → Command
        #expect(HIDKeyMap.modifierFlag(forUsage: 0xE1) == .maskShift)
        #expect(HIDKeyMap.modifierFlag(forUsage: 0x04) == nil)
        #expect(InputInjector.flags(for: [.command, .shift]) == [.maskCommand, .maskShift])
    }
}

@Suite struct HostComponentTests {
    @Test func webSocketAcceptKey() {
        // Example from RFC 6455 section 1.3.
        #expect(WebSocketMessageChannel.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func parsesAdbDeviceList() {
        let devices = AdbBridge.parseDeviceList("""
        A1B2C3D4       device usb:1-1 product:DBY-W09 model:DBY_W09 device:HWDBY transport_id:3
        emulator-5554\tunauthorized
        """)
        #expect(devices.count == 2)
        #expect(devices[0].serial == "A1B2C3D4")
        #expect(devices[0].state == .device)
        #expect(devices[0].displayName == "DBY W09")
        #expect(devices[1].state == .unauthorized)
    }

    @Test func trustStoreRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = TrustStore(directory: directory)
        let token = store.trust(deviceId: "device", name: "MatePad", platform: "android")
        #expect(store.validate(deviceId: "device", token: token))
        #expect(!store.validate(deviceId: "device", token: "wrong"))
        #expect(!store.validate(deviceId: "other", token: token))
        #expect(!store.validate(deviceId: "device", token: nil))

        // Persisted, and only the hash is on disk.
        let reloaded = TrustStore(directory: directory)
        #expect(reloaded.validate(deviceId: "device", token: token))
        let file = try String(contentsOf: directory.appendingPathComponent("trusted-devices.json"), encoding: .utf8)
        #expect(!file.contains(token))

        reloaded.remove(deviceId: "device")
        #expect(!TrustStore(directory: directory).validate(deviceId: "device", token: token))
    }

    @Test func pairingCodeAllowsThreeAttempts() {
        var code = PairingCode()
        #expect(code.value.count == 6)
        let wrong = code.value == "123456" ? "654321" : "123456"
        let rejected = code.verify(wrong)
        #expect(!rejected)
        #expect(code.attemptsLeft == PairingCode.maxAttempts - 1)
        let correct = code.value
        let accepted = code.verify(correct)
        #expect(accepted)
    }

    @Test func pairingCodesAcceptOtherDigitScripts() {
        #expect(PairingCode.asciiDigits("٤٨٢٩١٣") == "482913")
        #expect(PairingCode.asciiDigits("４８２ ９１３") == "482913")
        #expect(PairingCode.asciiDigits("48-29-13") == "482913")
        #expect(PairingCode.asciiDigits("½Ⅻ") == "")
    }

    @Test func bitrateStaysInBounds() {
        let usb = StreamQuality.balanced.bitrate(width: 2560, height: 1600, fps: 60, wired: true)
        let wifi = StreamQuality.balanced.bitrate(width: 2560, height: 1600, fps: 60, wired: false)
        #expect(usb > wifi)
        #expect((15_000_000...30_000_000).contains(usb))
        #expect(StreamQuality.low.bitrate(width: 320, height: 240, fps: 30, wired: false) == 2_000_000)
    }

    @Test func virtualDisplayModesKeepAspectAndEvenSizes() {
        let modes = VirtualDisplay.modes(width: 2560, height: 1600, refreshRate: 60)
        #expect(modes.contains { $0.width == 2560 && $0.height == 1600 })
        for mode in modes {
            #expect(mode.width % 2 == 0 && mode.height % 2 == 0)
            #expect(abs(Double(mode.width) / Double(mode.height) - 1.6) < 0.01)
        }
    }
}

/// Encodes a synthetic frame with VideoToolbox and decodes it with the client kit.
/// Hosted CI runners are VMs without a hardware video encoder, so this only runs locally.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
struct EncodeDecodeRoundTrip {
    @Test func h264RoundTrip() async throws {
        let width = 640
        let height = 400
        let encoder = try VideoEncoder(settings: .init(codec: .h264, width: width, height: height, fps: 60, bitrate: 4_000_000))
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        let buffer = try #require(pixelBuffer)

        let frame: EncodedFrame = try await withCheckedThrowingContinuation { continuation in
            let box = UncheckedSendable(value: buffer)
            encoder.encode(box.value, captureTimeMicros: 42, forceKeyframe: true) { result in
                switch result {
                case let .success(frame): continuation.resume(returning: frame)
                case let .failure(error): continuation.resume(throwing: error)
                case nil: continuation.resume(throwing: EncoderError.encodeFailed(-1))
                }
            }
        }
        #expect(frame.isKeyframe)
        #expect(frame.codecString?.hasPrefix("avc1.") == true)
        #expect(Array(frame.data.prefix(4)) == [0, 0, 0, 1])

        let message = VideoFrame(seq: 0, captureTimeMicros: frame.captureTimeMicros, isKeyframe: true, data: frame.data).message()
        let received = try VideoFrame(message)
        let factory = SampleBufferFactory(codec: .h264)
        let sample = try #require(factory.makeSampleBuffer(received))
        let decoded = try #require(PixelBufferDecoder().decode(sample))
        #expect(CVPixelBufferGetWidth(decoded) == width)
        #expect(CVPixelBufferGetHeight(decoded) == height)
    }
}

@Suite struct UsbmuxTests {
    @Test func framesPlistMessages() throws {
        let data = try Usbmux.encode(Usbmux.request("Connect", ["DeviceID": 7, "PortNumber": Int(Usbmux.networkOrder(7100))]), tag: 2)
        let header = Array(data.prefix(16))
        #expect(header[0...3] == [UInt8(data.count & 0xFF), UInt8(data.count >> 8 & 0xFF), 0, 0])
        #expect(header[4...7] == [1, 0, 0, 0])
        #expect(header[8...11] == [8, 0, 0, 0])
        #expect(header[12...15] == [2, 0, 0, 0])
        let body = try Usbmux.decodeBody(data.dropFirst(16))
        #expect(body["MessageType"] as? String == "Connect")
        #expect(body["DeviceID"] as? Int == 7)
        // htons(7100) = 0xBC1B
        #expect(body["PortNumber"] as? Int == 0xBC1B)
    }
}

@Suite struct AdaptiveBitrateTests {
    @Test func backsOffAndRecovers() {
        var control = AdaptiveBitrate(target: 20_000_000)
        #expect(control.update(stalls: 0, frames: 60, rttMs: 2) == nil)
        // Sustained stalls: drop by 30%.
        #expect(control.update(stalls: 30, frames: 30, rttMs: 3) == 14_000_000)
        #expect(control.update(stalls: 30, frames: 30, rttMs: 3) == 9_800_000)
        // RTT far above the baseline also counts as congestion.
        #expect(control.update(stalls: 0, frames: 60, rttMs: 80) == 6_860_000)
        // Recovers only after three calm seconds, never above the target.
        #expect(control.update(stalls: 0, frames: 60, rttMs: 2) == nil)
        #expect(control.update(stalls: 0, frames: 60, rttMs: 2) == nil)
        #expect(control.update(stalls: 0, frames: 60, rttMs: 2) == Int(6_860_000 * 1.15))
        for _ in 0..<40 { _ = control.update(stalls: 0, frames: 60, rttMs: 2) }
        #expect(control.current == 20_000_000)
    }

    @Test func neverBelowMinimum() {
        var control = AdaptiveBitrate(target: 10_000_000)
        for _ in 0..<20 { _ = control.update(stalls: 60, frames: 10, rttMs: nil) }
        #expect(control.current == 2_000_000)
    }
}

@Suite struct SecurityTests {
    @Test func webSocketOriginMustMatchHost() {
        let extra: Set<String> = ["http://localhost:5173"]
        #expect(WebServer.isAllowedOrigin("http://192.168.1.20:7101", host: "192.168.1.20:7101", extra: []))
        #expect(WebServer.isAllowedOrigin("http://localhost:5173", host: "127.0.0.1:7101", extra: extra))
        // Any other website, or a client hiding its origin, is refused.
        #expect(!WebServer.isAllowedOrigin("https://evil.example", host: "127.0.0.1:7101", extra: extra))
        #expect(!WebServer.isAllowedOrigin(nil, host: "127.0.0.1:7101", extra: extra))
        #expect(!WebServer.isAllowedOrigin("http://127.0.0.1:7101", host: nil, extra: []))
    }

    @Test func pairingGateAllowsOneDeviceAndBacksOff() {
        var now = Date(timeIntervalSince1970: 0)
        let gate = PairingGate(now: { now })
        let first = UUID()
        let second = UUID()
        #expect(gate.begin(first) == .granted)
        #expect(gate.begin(second) == .busy)

        gate.end(first, outcome: false)
        #expect(gate.begin(second) == .locked(30))
        now += 31
        #expect(gate.begin(second) == .granted)
        gate.end(second, outcome: false)
        #expect(gate.begin(first) == .locked(60))

        now += 61
        #expect(gate.begin(first) == .granted)
        gate.end(first, outcome: true)
        #expect(gate.begin(second) == .granted)
        // Abandoning doesn't lock, it only frees the slot.
        gate.end(second, outcome: nil)
        #expect(gate.begin(first) == .granted)
    }

    @Test func usbSecretPersistsAndIsUrlSafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = TrustStore(directory: directory).usbSecret
        #expect(secret.count >= 32)
        #expect(secret.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        let reloaded = TrustStore(directory: directory)
        #expect(reloaded.usbSecret == secret)
        #expect(reloaded.isUSBSecret(secret))
        #expect(!reloaded.isUSBSecret("nope"))
        #expect(!reloaded.isUSBSecret(nil))
    }

    @Test func adbLaunchPassesSecret() {
        let arguments = AdbBridge.launchArguments(serial: "ABC", secret: "s3cret")
        #expect(arguments.prefix(4) == ["-s", "ABC", "shell", "am"])
        #expect(arguments.suffix(3) == ["--es", AdbBridge.secretExtra, "s3cret"])
        #expect(!AdbBridge.launchArguments(serial: "ABC", secret: nil).contains("--es"))
    }
}
