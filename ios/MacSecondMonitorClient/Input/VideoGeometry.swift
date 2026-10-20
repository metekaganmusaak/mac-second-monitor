import AVFoundation
import CoreGraphics

/// Maps view points to normalized video-frame coordinates. The layer letterboxes the video
/// (`resizeAspect`), so the frame covers only part of the view when the aspect ratios differ.
struct VideoGeometry {
    var bounds: CGRect
    var videoSize: CGSize

    var contentRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0, !bounds.isEmpty else { return bounds }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    /// (0, 0) is the top-left of the frame, (1, 1) the bottom-right; points in the bars clamp to the edge.
    func normalizedPoint(_ point: CGPoint) -> (x: Float, y: Float) {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        return (Float(x), Float(y))
    }

    /// A distance (or velocity) in points as a fraction of the frame size.
    func normalizedDelta(_ delta: CGPoint) -> CGVector {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGVector(dx: delta.x / rect.width, dy: delta.y / rect.height)
    }
}
