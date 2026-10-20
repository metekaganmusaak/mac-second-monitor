import Foundation

/// Once-per-second numbers for the on-screen overlay.
struct StreamStats: Sendable, Equatable {
    var fps: Double
    var latencyMs: Double?
    var rttMs: Double?
    var bitrateKbps: Double?
    var decodeMs: Double
    var droppedFrames: Int
}

/// Accumulates frame measurements between two STATS reports.
struct FrameWindow {
    private var start: UInt64
    private var frames = 0
    private var dropped = 0
    private var latencySumMs = 0.0
    private var latencyCount = 0
    private var workSumMs = 0.0

    init(now: UInt64) {
        start = now
    }

    mutating func recordFrame(latencyMicros: Int64?, workMicros: UInt64) {
        frames += 1
        workSumMs += Double(workMicros) / 1000
        if let latencyMicros {
            latencySumMs += Double(max(latencyMicros, 0)) / 1000
            latencyCount += 1
        }
    }

    mutating func recordDrop() {
        dropped += 1
    }

    /// Returns the averages since the last call and starts a new window.
    mutating func take(now: UInt64) -> (fps: Double, latencyMs: Double?, decodeMs: Double, dropped: Int) {
        let seconds = max(Double(now &- start) / 1_000_000, 0.001)
        let result = (
            fps: Double(frames) / seconds,
            latencyMs: latencyCount > 0 ? latencySumMs / Double(latencyCount) : nil,
            decodeMs: frames > 0 ? workSumMs / Double(frames) : 0,
            dropped: dropped
        )
        self = FrameWindow(now: now)
        return result
    }
}
