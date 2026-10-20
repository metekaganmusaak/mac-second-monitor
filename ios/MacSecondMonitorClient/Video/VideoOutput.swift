import AVFoundation
import UIKit

/// The display layer shared by all sessions, so the last picture survives reconnects.
/// Frames are enqueued from connection queues; `StreamSurfaceView` puts the layer on screen.
final class VideoOutput: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()

    private let lock = NSLock()
    private var resetRequested = false
    private var suspended = false

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        // "Keep screen on" in Settings decides this, not the layer.
        layer.preventsDisplaySleepDuringVideoPlayback = false
    }

    /// While the app is in the background the decoder is unavailable: drop frames quietly
    /// instead of failing and requesting keyframes over and over.
    var isSuspended: Bool {
        get { lock.withLock { suspended } }
        set { lock.withLock { suspended = newValue } }
    }

    /// Asks the receiving queue to flush and wait for a keyframe before the next frame.
    func requestReset() {
        lock.withLock { resetRequested = true }
    }

    func takeResetRequest() -> Bool {
        lock.withLock {
            defer { resetRequested = false }
            return resetRequested
        }
    }

    var needsFlush: Bool {
        if #available(iOS 17.0, *) {
            let renderer = layer.sampleBufferRenderer
            return renderer.status == .failed || renderer.requiresFlushToResumeDecoding
        }
        return layer.status == .failed || layer.requiresFlushToResumeDecoding
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.enqueue(sampleBuffer)
        } else {
            layer.enqueue(sampleBuffer)
        }
    }

    func flush() {
        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.flush()
        } else {
            layer.flush()
        }
    }

    /// Drops the picture as well, e.g. after the user disconnected.
    func clear() {
        if #available(iOS 17.0, *) {
            layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            layer.flushAndRemoveImage()
        }
    }
}
