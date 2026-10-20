// msm — command-line host and test tools for Mac Second Monitor.
//
//   msm serve         Run the host without the menu bar app.
//   msm probe         Connect as a client, decode the stream and report fps / latency.
//   msm display-test  Create a virtual display and list the modes macOS offers.
//   msm encode-bench  Measure hardware encode time.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import MSMClientKit
import MSMHost
import MSMProtocol
import UniformTypeIdentifiers
import VideoToolbox

struct Arguments {
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = values.firstIndex(of: name) else { return false }
        values.remove(at: index)
        return true
    }

    mutating func option(_ name: String) -> String? {
        guard let index = values.firstIndex(of: name), index + 1 < values.count else { return nil }
        let value = values[index + 1]
        values.removeSubrange(index...(index + 1))
        return value
    }

    mutating func int(_ name: String, default value: Int) -> Int {
        option(name).flatMap(Int.init) ?? value
    }

    mutating func positional() -> String? {
        guard let index = values.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
        return values.remove(at: index)
    }

    func ensureEmpty() {
        if !values.isEmpty {
            fail("unknown arguments: \(values.joined(separator: " "))")
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("msm: \(message)\n".utf8))
    exit(2)
}

func printLine(_ text: String) {
    print(text)
    fflush(stdout)
}

let usage = """
usage: msm <command> [options]

  serve         [--test-pattern] [--mirror] [--port N] [--web-port N] [--no-web] [--web-root DIR]
                [--no-pairing] [--allow-origin URL] [--no-bonjour] [--fps N] [--quality low|balanced|high] [--hevc]
                [--usb] [--inject] [--state-dir DIR]
  probe         [HOST] [--port N] [--seconds S] [--width W] [--height H] [--code CODE]
                [--screenshot FILE.png] [--save FILE.h264] [--hevc]
  display-test  [--width W] [--height H] [--seconds S]
  encode-bench  [--width W] [--height H] [--frames N] [--codec h264|hevc]
"""

var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
guard let command = arguments.positional() else {
    printLine(usage)
    exit(0)
}

switch command {
case "serve":
    Serve.run(&arguments)
case "probe":
    Probe.run(&arguments)
case "display-test":
    DisplayTest.run(&arguments)
case "encode-bench":
    EncodeBench.run(&arguments)
case "help", "--help", "-h":
    printLine(usage)
default:
    fail("unknown command \(command)\n\(usage)")
}

// MARK: - serve

enum Serve {
    static func run(_ arguments: inout Arguments) {
        var options = HostEngine.Options(hostName: Host.current().localizedName ?? "Mac")
        options.testPattern = arguments.flag("--test-pattern")
        options.displayMode = arguments.flag("--mirror") ? .mirror : .extend
        options.nativePort = UInt16(arguments.int("--port", default: Int(MSMProtocolInfo.nativePort)))
        options.webPort = UInt16(arguments.int("--web-port", default: Int(MSMProtocolInfo.webPort)))
        options.enableWebServer = !arguments.flag("--no-web")
        options.webRoot = arguments.option("--web-root").map { URL(fileURLWithPath: $0) }
        options.requirePairing = !arguments.flag("--no-pairing")
        if let origin = arguments.option("--allow-origin") {
            options.extraWebOrigins = [origin]
        }
        options.advertise = !arguments.flag("--no-bonjour")
        options.fps = arguments.int("--fps", default: 60)
        if let quality = arguments.option("--quality") {
            guard let value = StreamQuality(rawValue: quality) else { fail("bad --quality") }
            options.quality = value
        }
        options.preferHEVC = arguments.flag("--hevc")
        options.injectInputInTestMode = arguments.flag("--inject")
        let usb = arguments.flag("--usb")
        let stateDirectory = arguments.option("--state-dir").map { URL(fileURLWithPath: $0) }
        arguments.ensureEmpty()

        if !options.testPattern, !CGPreflightScreenCaptureAccess() {
            printLine("warning: Screen Recording permission is missing; clients will be rejected. Use --test-pattern or grant the permission.")
            CGRequestScreenCaptureAccess()
        }

        // Tests pass --state-dir so pairings don't land in the app's real trust store.
        let engine = HostEngine(options: options, trustStore: stateDirectory.map { TrustStore(directory: $0) } ?? TrustStore())
        let printer = SessionPrinter(engine: engine)
        engine.onChange = { printer.changed() }
        do {
            try engine.start()
        } catch {
            fail("could not start: \(error.localizedDescription)")
        }

        var bridge: AdbBridge?
        var usbmux: UsbmuxBridge?
        if usb {
            let ios = UsbmuxBridge(port: options.nativePort)
            ios.onChannel = { engine.adopt($0) }
            ios.onChange = { printLine("usb (iOS): \(ios.attachedDevices.map { "\($0.serial) connected=\($0.connected)" })") }
            ios.start()
            usbmux = ios

            var bridgeOptions = AdbBridge.Options()
            bridgeOptions.port = options.nativePort
            bridgeOptions.secret = engine.trustStore.usbSecret
            let adb = AdbBridge(options: bridgeOptions)
            adb.onChange = {
                let list = adb.devices.map { "\($0.displayName) [\($0.serial)] \($0.state) bridge=\($0.bridge) app=\($0.clientInstalled.map(String.init) ?? "?")" }
                printLine("usb: \(adb.status) \(list.joined(separator: "; "))")
            }
            adb.start()
            bridge = adb
        }

        printLine("Serving on tcp/\(options.nativePort) (native) and http/\(options.webPort) (web)\(options.testPattern ? " with test pattern" : ""), mode=\(options.displayMode.rawValue)")
        for address in NetworkInfo.localAddresses() {
            printLine("  \(address.interface): \(address.address)")
        }

        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            printLine("\nStopping…")
            bridge?.stop()
            usbmux?.stop()
            engine.stop(waitingUpTo: 0.5)
            exit(0)
        }
        interrupt.resume()
        withExtendedLifetime((engine, printer, bridge, usbmux, interrupt)) {
            dispatchMain()
        }
    }
}

final class SessionPrinter: @unchecked Sendable {
    private let engine: HostEngine
    private let lock = NSLock()
    private var lastPrint = Date.distantPast
    private var lastSummary = ""
    private var announcedCodes: Set<String> = []

    init(engine: HostEngine) {
        self.engine = engine
    }

    func changed() {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(lastPrint) >= 1 else { return }
        lastPrint = Date()
        let snapshots = engine.snapshots()
        for session in snapshots {
            if case let .pairing(code) = session.phase, announcedCodes.insert(code).inserted {
                printLine("Pairing code for \(session.deviceName): \(code)")
            }
        }
        let lines = snapshots.map { session -> String in
            var line = "\(session.deviceName) [\(session.transport.rawValue)] \(session.width)x\(session.height) \(session.phase)"
            if session.phase == .streaming {
                line += String(format: " | %.0f fps %.1f Mbps enc %.1f ms skipped %d", session.pipeline.fps, session.pipeline.bitrateKbps / 1000, session.pipeline.encodeMs, session.pipeline.skippedFrames)
                if let client = session.client {
                    line += String(format: " | client %.0f fps decode %.1f ms", client.fps, client.decodeMs)
                    if let latency = client.latencyMs { line += String(format: " latency %.1f ms", latency) }
                    if let rtt = client.rttMs { line += String(format: " rtt %.1f ms", rtt) }
                }
            }
            return line
        }
        let summary = lines.isEmpty ? "no clients" : lines.joined(separator: "\n")
        if summary != lastSummary || !lines.isEmpty {
            printLine(summary)
            lastSummary = summary
        }
    }
}

// MARK: - probe

enum Probe {
    static func run(_ arguments: inout Arguments) {
        let port = UInt16(arguments.int("--port", default: Int(MSMProtocolInfo.nativePort)))
        let seconds = Double(arguments.int("--seconds", default: 5))
        let width = arguments.int("--width", default: 2560)
        let height = arguments.int("--height", default: 1600)
        let code = arguments.option("--code")
        let screenshot = arguments.option("--screenshot")
        let save = arguments.option("--save")
        let hevc = arguments.flag("--hevc")
        let host = arguments.positional() ?? "127.0.0.1"
        arguments.ensureEmpty()

        let hello = Hello(
            deviceId: "msm-probe-\(width)x\(height)",
            deviceName: "msm probe",
            platform: "macos",
            appVersion: "0.1.1",
            display: DisplayInfo(width: width, height: height, dpi: 220, refreshRate: 60),
            codecs: hevc ? ["hevc", "h264"] : ["h264"],
            locale: Locale.current.identifier
        )
        let client = ProbeClient(seconds: seconds, code: code, screenshot: screenshot, save: save)
        let connection = ClientConnection(host: host, port: port, hello: hello)
        connection.delegate = client
        client.connection = connection
        connection.start()
        withExtendedLifetime((client, connection)) {
            dispatchMain()
        }
    }
}

final class ProbeClient: ClientConnectionDelegate, @unchecked Sendable {
    weak var connection: ClientConnection?
    private let seconds: Double
    private let code: String?
    private let screenshot: String?
    private let saveHandle: FileHandle?
    private var factory = SampleBufferFactory(codec: .h264)
    private let decoder = PixelBufferDecoder()
    private var config: StreamConfig?
    private var started: UInt64?
    private var frames = 0
    private var keyframes = 0
    private var decoded = 0
    private var bytes = 0
    private var latencies: [Double] = []
    private var decodeTimes: [Double] = []
    private var lastImage: CVPixelBuffer?

    init(seconds: Double, code: String?, screenshot: String?, save: String?) {
        self.seconds = seconds
        self.code = code
        self.screenshot = screenshot
        if let save {
            FileManager.default.createFile(atPath: save, contents: nil)
            saveHandle = FileHandle(forWritingAtPath: save)
        } else {
            saveHandle = nil
        }
    }

    func connection(_ connection: ClientConnection, didReceiveWelcome welcome: Welcome) {
        printLine("Connected to \(welcome.hostName) via \(welcome.transport)\(welcome.token != nil ? " (paired)" : "")")
    }

    func connection(_ connection: ClientConnection, needsPairingCode request: PairRequest) {
        if let code, !request.retry {
            connection.sendPairingCode(code)
            return
        }
        print(request.retry ? "Wrong code, \(request.attemptsLeft) attempts left. Code: " : "Pairing code shown on the Mac: ", terminator: "")
        fflush(stdout)
        DispatchQueue.global().async {
            let line = readLine() ?? ""
            connection.sendPairingCode(line)
        }
    }

    func connection(_ connection: ClientConnection, didReceiveConfig config: StreamConfig) {
        self.config = config
        factory = SampleBufferFactory(codec: config.codec == "hevc" ? .hevc : .h264)
        printLine("CONFIG \(config.codec) \(config.codecString) \(config.width)x\(config.height)@\(config.fps) mode=\(config.mode)")
    }

    func connection(_ connection: ClientConnection, didReceiveFrame frame: VideoFrame) {
        if started == nil {
            started = HostClockLite.nowMicros()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.finish() }
        }
        frames += 1
        bytes += frame.data.count
        if frame.isKeyframe { keyframes += 1 }
        saveHandle?.write(frame.data)

        let decodeStart = HostClockLite.nowMicros()
        if let sample = factory.makeSampleBuffer(frame) {
            connection.acknowledge(frame.seq)
            if let image = decoder.decode(sample) {
                decoded += 1
                lastImage = image
                decodeTimes.append(Double(HostClockLite.nowMicros() - decodeStart) / 1000)
                if let latency = connection.latencyMicros(captureTime: frame.captureTimeMicros) {
                    latencies.append(Double(latency) / 1000)
                }
            }
        } else {
            connection.acknowledge(frame.seq)
            connection.requestKeyframe()
        }
    }

    func connection(_ connection: ClientConnection, didCloseWith error: ClientError?) {
        if let error {
            printLine("Connection closed: \(error)")
            exit(1)
        }
    }

    private func finish() {
        guard let connection else { exit(1) }
        connection.queue.async { [self] in
            let elapsed = Double(HostClockLite.nowMicros() - (started ?? 0)) / 1_000_000
            func average(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
            func percentile(_ values: [Double], _ p: Double) -> Double {
                guard !values.isEmpty else { return 0 }
                let sorted = values.sorted()
                return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
            }
            printLine(String(format: "frames=%d decoded=%d keyframes=%d fps=%.1f bitrate=%.1f Mbps", frames, decoded, keyframes, Double(frames) / elapsed, Double(bytes * 8) / elapsed / 1_000_000))
            printLine(String(format: "decode avg=%.2f ms  latency(capture→decoded) avg=%.1f p50=%.1f p95=%.1f ms  rtt=%.2f ms", average(decodeTimes), average(latencies), percentile(latencies, 0.5), percentile(latencies, 0.95), Double(connection.rttMicros ?? 0) / 1000))
            saveHandle?.closeFile()
            if let screenshot, let lastImage {
                Self.writePNG(lastImage, to: screenshot)
                printLine("Saved \(screenshot)")
            }
            connection.close()
            let success = decoded > 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                exit(success ? 0 : 1)
            }
        }
    }

    static func writePNG(_ buffer: CVPixelBuffer, to path: String) {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        guard let image,
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: - display-test

enum DisplayTest {
    static func run(_ arguments: inout Arguments) {
        let width = arguments.int("--width", default: 2560)
        let height = arguments.int("--height", default: 1600)
        let seconds = Double(arguments.int("--seconds", default: 3))
        arguments.ensureEmpty()

        do {
            let display = try VirtualDisplay(
                name: "msm display-test",
                client: DisplayInfo(width: width, height: height, dpi: 276, refreshRate: 60),
                identity: "msm-display-test",
                refreshRate: 60
            )
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            printLine("display \(display.displayID) bounds \(display.bounds)")
            if let current = CGDisplayCopyDisplayMode(display.displayID) {
                printLine("current mode: \(current.width)x\(current.height) pt, \(current.pixelWidth)x\(current.pixelHeight) px @\(current.refreshRate)")
            }
            let modes = (CGDisplayCopyAllDisplayModes(display.displayID, nil) as? [CGDisplayMode]) ?? []
            for mode in modes where mode.isUsableForDesktopGUI() {
                printLine("  \(mode.width)x\(mode.height) pt  \(mode.pixelWidth)x\(mode.pixelHeight) px  @\(mode.refreshRate)\(mode.pixelWidth > mode.width ? "  HiDPI" : "")")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(max(0, seconds - 1)))
            withExtendedLifetime(display) {}
        } catch {
            fail(error.localizedDescription)
        }
    }
}

// MARK: - encode-bench

enum EncodeBench {
    static func run(_ arguments: inout Arguments) {
        let width = arguments.int("--width", default: 2560)
        let height = arguments.int("--height", default: 1600)
        let frames = arguments.int("--frames", default: 300)
        let codec = VideoCodec(rawValue: arguments.option("--codec") ?? "h264") ?? .h264
        arguments.ensureEmpty()

        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(settings: .init(codec: codec, width: width, height: height, fps: 60, bitrate: StreamQuality.balanced.bitrate(width: width, height: height, fps: 60, wired: true)))
        } catch {
            fail(error.localizedDescription)
        }
        printLine("low-latency rate control: \(encoder.usesLowLatencyRateControl)")

        let source = TestPatternSource(width: width, height: height, fps: 60)
        let results = BenchResults()
        let done = DispatchSemaphore(value: 0)
        source.onFrame = { buffer, time in
            let box = SendableBox(buffer)
            let index = results.nextIndex()
            guard index < frames else { return }
            encoder.encode(box.value, captureTimeMicros: HostClock.nowMicros(), forceKeyframe: index == 0) { result in
                if case let .success(frame) = result {
                    results.add(frame)
                }
                if index == frames - 1 { done.signal() }
            }
        }
        Task { try await source.start() }
        _ = done.wait(timeout: .now() + .seconds(frames / 30 + 10))
        let summary = results.summary()
        printLine(String(format: "%@ %dx%d: %d frames, encode avg %.2f ms, max %.2f ms, keyframe %.0f KB, P-frame avg %.1f KB", codec.rawValue, width, height, summary.count, summary.avgMs, summary.maxMs, summary.keyKB, summary.pKB))
    }
}

struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

final class BenchResults: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private var frames: [EncodedFrame] = []

    func nextIndex() -> Int {
        lock.lock()
        defer { index += 1; lock.unlock() }
        return index
    }

    func add(_ frame: EncodedFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }

    func summary() -> (count: Int, avgMs: Double, maxMs: Double, keyKB: Double, pKB: Double) {
        lock.lock()
        defer { lock.unlock() }
        let times = frames.map { Double($0.encodeMicros) / 1000 }
        let key = frames.first(where: \.isKeyframe).map { Double($0.data.count) / 1024 } ?? 0
        let predicted = frames.filter { !$0.isKeyframe }.map { Double($0.data.count) / 1024 }
        return (
            frames.count,
            times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count),
            times.max() ?? 0,
            key,
            predicted.isEmpty ? 0 : predicted.reduce(0, +) / Double(predicted.count)
        )
    }
}
