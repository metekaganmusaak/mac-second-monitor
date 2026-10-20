import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import MSMProtocol

public enum DisplayMode: String, Sendable, CaseIterable, Codable {
    /// A new virtual display: the client extends the desktop.
    case extend
    /// The main display, scaled to the client.
    case mirror
}

public enum StreamQuality: String, Sendable, CaseIterable, Codable {
    case low
    case balanced
    case high

    /// Target bitrate. Desktop content is mostly static, so these are generous ceilings
    /// that matter during scrolling and video playback.
    public func bitrate(width: Int, height: Int, fps: Int, wired: Bool) -> Int {
        let bitsPerPixel: Double = switch self {
        case .low: 0.05
        case .balanced: 0.09
        case .high: 0.15
        }
        let wiredBitrate = Double(width * height * fps) * bitsPerPixel
        let bitrate = wired ? wiredBitrate : wiredBitrate * 0.6
        return Int(min(max(bitrate, 2_000_000), 80_000_000))
    }
}

struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

/// Per-second counters for the host UI.
public struct PipelineStats: Sendable, Equatable {
    public var fps: Double = 0
    public var bitrateKbps: Double = 0
    public var encodeMs: Double = 0
    /// Frames not encoded because the client had not acknowledged earlier ones.
    public var skippedFrames: Int = 0
    public var lowLatencyEncoder = false
    /// Current encoder target; lower than the quality setting while the link is congested.
    public var targetBitrateKbps: Double = 0

    public init(fps: Double = 0, bitrateKbps: Double = 0, encodeMs: Double = 0, skippedFrames: Int = 0) {
        self.fps = fps
        self.bitrateKbps = bitrateKbps
        self.encodeMs = encodeMs
        self.skippedFrames = skippedFrames
    }
}

/// Capture → encode → send for one client, with latest-frame-wins flow control:
/// at most `maxFramesInFlight` unacknowledged frames; while the window is full,
/// newer captures replace the pending one instead of queueing.
final class StreamPipeline: @unchecked Sendable {
    struct Configuration: Sendable {
        var mode: DisplayMode
        var codec: VideoCodec
        var fps: Int
        var quality: StreamQuality
        var testPattern: Bool
        var maxFramesInFlight = 2
    }

    // Everything below is confined to `queue` (the owning session's queue).
    private let queue: DispatchQueue
    private let channel: MessageChannel
    private let configuration: Configuration
    private let client: DisplayInfo
    private let displayName: String
    private let identity: String

    private(set) var virtualDisplay: VirtualDisplay?
    private var source: FrameSource?
    private var encoder: VideoEncoder?
    private(set) var mapper: CoordinateMapper?
    private(set) var testPattern: TestPatternSource?
    private var mirrorDisplayID: CGDirectDisplayID?

    private var latest: UncheckedSendable<CVPixelBuffer>?
    private var latestCaptureTime: UInt64 = 0
    private var hasNewFrame = false
    private var keyframeRequested = true
    private var encoderBusy = false
    private var nextSeq: UInt32 = 0
    private var lastAcked: Int64 = -1
    private var sentCodecString: String?
    private var stopped = false
    /// After an encoder failure, wait before trying again (a session that can't be recreated
    /// would otherwise spin).
    private var consecutiveFailures = 0
    private var retryAfter: UInt64 = 0

    private var windowStart = HostClock.nowMicros()
    private var windowFrames = 0
    private var windowBytes = 0
    private var windowEncodeMicros: UInt64 = 0
    private var windowSkipped = 0
    private var windowStalls = 0
    private(set) var stats = PipelineStats()
    private var rateControl: AdaptiveBitrate?

    var onFailure: (@Sendable (Error) -> Void)?

    init(queue: DispatchQueue, channel: MessageChannel, client: DisplayInfo, displayName: String, identity: String, configuration: Configuration) {
        self.queue = queue
        self.channel = channel
        self.client = client
        self.displayName = displayName
        self.identity = identity
        self.configuration = configuration
    }

    var width: Int { client.width & ~1 }
    var height: Int { client.height & ~1 }

    /// Display that input events are injected into; nil for the test pattern.
    var targetDisplayID: CGDirectDisplayID? {
        virtualDisplay?.displayID ?? mirrorDisplayID
    }

    func start() async throws {
        let bitrate = configuration.quality.bitrate(width: width, height: height, fps: configuration.fps, wired: channel.transport.isWired)
        let rateControl = AdaptiveBitrate(target: bitrate)
        let encoder = try VideoEncoder(settings: .init(codec: configuration.codec, width: width, height: height, fps: configuration.fps, bitrate: bitrate))

        let source: FrameSource
        var pattern: TestPatternSource?
        var display: VirtualDisplay?
        var mirrorID: CGDirectDisplayID?
        if configuration.testPattern {
            pattern = TestPatternSource(width: width, height: height, fps: configuration.fps)
            source = pattern!
        } else {
            let displayID: CGDirectDisplayID
            switch configuration.mode {
            case .extend:
                let name = displayName
                let client = client
                let identity = identity
                let fps = Double(configuration.fps)
                let created = try await MainActor.run {
                    try VirtualDisplay(name: name, client: client, identity: identity, refreshRate: fps) { [weak self] in
                        guard let self else { return }
                        self.queue.async { self.fail(VirtualDisplayError.creationFailed) }
                    }
                }
                display = created
                displayID = created.displayID
            case .mirror:
                displayID = CGMainDisplayID()
                mirrorID = displayID
            }
            source = ScreenCapturer(configuration: .init(displayID: displayID, width: width, height: height, fps: configuration.fps))
        }

        source.onFrame = { [weak self] buffer, time in
            guard let self else { return }
            let box = UncheckedSendable(value: buffer)
            let micros = HostClock.micros(time)
            self.queue.async { self.frameArrived(box, captureTime: micros) }
        }
        source.onStop = { [weak self] error in
            guard let self else { return }
            self.queue.async { self.fail(error ?? CaptureError.permissionDenied) }
        }

        let configured = queue.sync { () -> Bool in
            guard !stopped else { return false }
            self.encoder = encoder
            self.source = source
            self.testPattern = pattern
            self.virtualDisplay = display
            self.mirrorDisplayID = mirrorID
            self.updateMapper()
            self.rateControl = rateControl
            self.stats.lowLatencyEncoder = encoder.usesLowLatencyRateControl
            self.stats.targetBitrateKbps = Double(bitrate) / 1000
            return true
        }
        guard configured else { return }
        try await source.start()
        // The session may have ended while capture was starting.
        if queue.sync(execute: { stopped }) {
            await source.stop()
        }
    }

    /// Called about once per second so stats decay to zero on a static screen.
    func tick() {
        rollStats()
        pump()
    }

    func stop() async {
        let source = queue.sync { () -> FrameSource? in
            stopped = true
            let source = self.source
            self.source = nil
            encoder?.invalidate()
            encoder = nil
            latest = nil
            return source
        }
        await source?.stop()
        await MainActor.run { [self] in
            // Releasing the last reference removes the virtual display.
            queue.sync { virtualDisplay = nil }
        }
    }

    /// Display bounds change when the user rearranges displays; refresh per input batch.
    func updateMapper() {
        if let displayID = targetDisplayID {
            let bounds = CGDisplayBounds(displayID)
            var mapper = CoordinateMapper(displayBounds: bounds)
            if configuration.mode == .mirror {
                mapper.contentRect = CoordinateMapper.aspectFit(source: bounds.size, into: CGSize(width: width, height: height))
            }
            self.mapper = mapper
        } else {
            mapper = nil
        }
    }

    /// Latest round-trip time reported by the client (STATS), for congestion detection.
    var clientRttMs: Double?

    func requestKeyframe() {
        keyframeRequested = true
        pump()
    }

    func acknowledge(_ seq: UInt32) {
        lastAcked = max(lastAcked, Int64(seq))
        pump()
    }

    private func frameArrived(_ buffer: UncheckedSendable<CVPixelBuffer>, captureTime: UInt64) {
        guard !stopped else { return }
        if hasNewFrame {
            windowSkipped += 1
        }
        latest = buffer
        latestCaptureTime = captureTime
        hasNewFrame = true
        pump()
    }

    private func pump() {
        guard !stopped, !encoderBusy, let encoder, let latest else { return }
        guard hasNewFrame || keyframeRequested else { return }
        guard consecutiveFailures == 0 || HostClock.nowMicros() >= retryAfter else { return }
        let inFlight = Int64(nextSeq) - 1 - lastAcked
        guard inFlight < Int64(configuration.maxFramesInFlight) else {
            windowStalls += 1
            return
        }

        let forceKeyframe = keyframeRequested
        hasNewFrame = false
        keyframeRequested = false
        encoderBusy = true
        encoder.encode(latest.value, captureTimeMicros: latestCaptureTime, forceKeyframe: forceKeyframe) { [weak self] result in
            guard let self else { return }
            let box = UncheckedSendable(value: result)
            self.queue.async { self.encoded(box.value, forcedKeyframe: forceKeyframe) }
        }
    }

    private func encoded(_ result: Result<EncodedFrame, Error>?, forcedKeyframe: Bool) {
        encoderBusy = false
        guard !stopped else { return }

        switch result {
        case nil:
            if forcedKeyframe { keyframeRequested = true }
        case let .failure(error):
            consecutiveFailures += 1
            // 50 ms, 100 ms … up to 2 s; the next capture or tick retries.
            let delay = min(UInt64(50_000) << UInt64(min(consecutiveFailures - 1, 6)), 2_000_000)
            retryAfter = HostClock.nowMicros() + delay
            if consecutiveFailures == 1 || consecutiveFailures % 20 == 0 {
                Log.encoder.error("Encode failed (\(self.consecutiveFailures)x): \(error.localizedDescription, privacy: .public)")
            }
            keyframeRequested = true
        case let .success(frame):
            consecutiveFailures = 0
            send(frame)
        }
        rollStats()
        pump()
    }

    private func send(_ frame: EncodedFrame) {
        if frame.isKeyframe, let codecString = frame.codecString, codecString != sentCodecString {
            sentCodecString = codecString
            let config = StreamConfig(codec: configuration.codec.rawValue, codecString: codecString, width: width, height: height, fps: configuration.fps, mode: configuration.mode.rawValue)
            channel.send(.json(.config, config))
        }
        guard sentCodecString != nil else {
            // The decoder can't start without parameter sets.
            keyframeRequested = true
            return
        }

        let message = VideoFrame(seq: nextSeq, captureTimeMicros: frame.captureTimeMicros, isKeyframe: frame.isKeyframe, data: frame.data).message()
        nextSeq &+= 1
        channel.send(message)

        windowFrames += 1
        windowBytes += frame.data.count
        windowEncodeMicros += frame.encodeMicros
    }

    private func rollStats() {
        let now = HostClock.nowMicros()
        let elapsed = now - windowStart
        guard elapsed >= 1_000_000 else { return }
        let seconds = Double(elapsed) / 1_000_000
        stats.fps = Double(windowFrames) / seconds
        stats.bitrateKbps = Double(windowBytes * 8) / seconds / 1000
        stats.encodeMs = windowFrames > 0 ? Double(windowEncodeMicros) / Double(windowFrames) / 1000 : 0
        stats.skippedFrames = windowSkipped
        if var rateControl, let encoder {
            if let bitrate = rateControl.update(stalls: windowStalls, frames: windowFrames, rttMs: clientRttMs) {
                encoder.setBitrate(bitrate)
                Log.encoder.info("Bitrate → \(bitrate / 1000) kbps")
            }
            stats.targetBitrateKbps = Double(rateControl.current) / 1000
            self.rateControl = rateControl
        }
        windowStalls = 0
        windowStart = now
        windowFrames = 0
        windowBytes = 0
        windowEncodeMicros = 0
        windowSkipped = 0
    }

    private func fail(_ error: Error) {
        guard !stopped else { return }
        onFailure?(error)
    }
}

/// Lowers the bitrate quickly when the link backs up (the ACK window fills or the RTT grows
/// well above its baseline) and creeps back towards the target once it is calm again.
struct AdaptiveBitrate: Equatable {
    let target: Int
    private(set) var current: Int
    private var calmSeconds = 0
    private var baselineRtt: Double?

    init(target: Int) {
        self.target = target
        current = target
    }

    var minimum: Int { max(1_000_000, target / 5) }

    /// Called once per second; returns a new bitrate when it changed.
    mutating func update(stalls: Int, frames: Int, rttMs: Double?) -> Int? {
        if let rttMs {
            baselineRtt = min(baselineRtt ?? rttMs, rttMs)
        }
        let rttGrew = rttMs.map { $0 > (baselineRtt ?? $0) + 40 } ?? false
        // Stalling on a few frames is normal around keyframes; sustained stalls are congestion.
        let congested = stalls > max(3, frames / 4) || rttGrew

        let previous = current
        if congested {
            calmSeconds = 0
            current = max(minimum, Int(Double(current) * 0.7))
        } else {
            calmSeconds += 1
            if calmSeconds >= 3, current < target {
                current = min(target, Int(Double(current) * 1.15))
            }
        }
        return current == previous ? nil : current
    }
}
