import CoreMedia
import Foundation
import MSMClientKit
import MSMProtocol

/// Delegate of one `ClientConnection`, called on its queue. Feeds frames straight into the
/// display layer, acknowledges them and forwards everything else as `Event`s.
final class StreamReceiver: ClientConnectionDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case welcome(Welcome)
        case pairingRequested(PairRequest)
        case config(StreamConfig)
        case firstFrame
        case stats(StreamStats)
        case closed(ClientError?)
    }

    private static let keyframeRequestInterval: UInt64 = 300_000

    private let output: VideoOutput
    private let onEvent: @Sendable (Event) -> Void

    // Confined to the connection queue.
    private var factory: SampleBufferFactory?
    private var awaitingKeyframe = true
    private var lastKeyframeRequest: UInt64 = 0
    private var hasShownFrame = false
    private var window = FrameWindow(now: HostClockLite.nowMicros())

    init(output: VideoOutput, onEvent: @escaping @Sendable (Event) -> Void) {
        self.output = output
        self.onEvent = onEvent
    }

    func connection(_ connection: ClientConnection, didReceiveWelcome welcome: Welcome) {
        onEvent(.welcome(welcome))
    }

    func connection(_ connection: ClientConnection, needsPairingCode request: PairRequest) {
        onEvent(.pairingRequested(request))
    }

    func connection(_ connection: ClientConnection, didReceiveConfig config: StreamConfig) {
        factory = SampleBufferFactory(codec: StreamCodec(rawValue: config.codec) ?? .h264)
        awaitingKeyframe = true
        onEvent(.config(config))
    }

    func connection(_ connection: ClientConnection, didReceiveFrame frame: VideoFrame) {
        let started = HostClockLite.nowMicros()
        if display(frame, connection: connection) {
            window.recordFrame(
                latencyMicros: connection.latencyMicros(captureTime: frame.captureTimeMicros),
                workMicros: HostClockLite.nowMicros() - started
            )
            if !hasShownFrame {
                hasShownFrame = true
                onEvent(.firstFrame)
            }
        } else {
            window.recordDrop()
        }
        // Required for every frame, shown or not: the host stops after two unacknowledged frames.
        connection.acknowledge(frame.seq)
    }

    func connection(_ connection: ClientConnection, didCloseWith error: ClientError?) {
        onEvent(.closed(error))
    }

    /// For `ClientConnection.statsProvider`; also pushes the overlay numbers to the UI.
    func hostStats(connection: ClientConnection?) -> (decodeMs: Double, latencyMs: Double?, dropped: Int) {
        let sample = window.take(now: HostClockLite.nowMicros())
        if let connection {
            let onEvent = onEvent
            // Queued behind the current tick, which stores this second's `lastStats`.
            connection.queue.async {
                onEvent(.stats(StreamStats(
                    fps: sample.fps,
                    latencyMs: sample.latencyMs,
                    rttMs: connection.rttMicros.map { Double($0) / 1000 },
                    bitrateKbps: connection.lastStats?.bitrateKbps,
                    decodeMs: sample.decodeMs,
                    droppedFrames: sample.dropped
                )))
            }
        }
        return (sample.decodeMs, sample.latencyMs, sample.dropped)
    }

    /// Returns whether the frame was handed to the layer.
    private func display(_ frame: VideoFrame, connection: ClientConnection) -> Bool {
        if output.isSuspended { return false }
        if output.takeResetRequest() || output.needsFlush {
            output.flush()
            awaitingKeyframe = true
        }
        guard let factory else {
            requestKeyframe(connection)
            return false
        }
        if awaitingKeyframe, !frame.isKeyframe {
            requestKeyframe(connection)
            return false
        }
        guard let sampleBuffer = factory.makeSampleBuffer(frame) else {
            awaitingKeyframe = true
            requestKeyframe(connection)
            return false
        }
        output.enqueue(sampleBuffer)
        awaitingKeyframe = false
        return true
    }

    private func requestKeyframe(_ connection: ClientConnection) {
        let now = HostClockLite.nowMicros()
        guard lastKeyframeRequest == 0 || now - lastKeyframeRequest >= Self.keyframeRequestInterval else { return }
        lastKeyframeRequest = now
        connection.requestKeyframe()
    }
}
