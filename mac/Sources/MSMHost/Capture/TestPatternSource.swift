import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation

/// Animated synthetic frames. Lets the whole pipeline (encode, transport, decode, input)
/// be tested without Screen Recording permission or a virtual display.
public final class TestPatternSource: FrameSource, @unchecked Sendable {
    public var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    public var onStop: (@Sendable (Error?) -> Void)?

    private let width: Int
    private let height: Int
    private let fps: Int
    private let queue = DispatchQueue(label: "com.macsecondmonitor.testpattern", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frameIndex = 0
    /// Last pointer position reported through `showPointer`, normalized.
    private let pointer = Locked<CGPoint?>(nil)

    public init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    /// Draws a marker where the client last touched, to check input mapping visually.
    public func showPointer(x: Double, y: Double) {
        pointer.withLock { $0 = CGPoint(x: x, y: y) }
    }

    public func start() async throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .microseconds(500))
        timer.setEventHandler { [weak self] in self?.renderFrame() }
        timer.resume()
        self.timer = timer
    }

    public func stop() async {
        timer?.cancel()
        timer = nil
    }

    private func renderFrame() {
        guard let pool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            draw(in: context)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        frameIndex += 1
        onFrame?(buffer, CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private func draw(in context: CGContext) {
        let w = CGFloat(width)
        let h = CGFloat(height)
        // CoreGraphics' origin is bottom-left; flip so drawing matches screen coordinates.
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Colour bars.
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1)]
        let barWidth = w / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            context.setFillColor(CGColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth + 1, height: h * 0.25))
        }

        // Moving block: shows motion smoothness and latency.
        let phase = CGFloat(frameIndex % (fps * 4)) / CGFloat(fps * 4)
        let blockSize = h * 0.12
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 1, alpha: 1))
        context.fill(CGRect(x: phase * (w - blockSize), y: h * 0.4, width: blockSize, height: blockSize))

        // One-pixel grid in the corner: shows chroma / scaling artifacts.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for x in stride(from: 0, to: 200, by: 2) {
            context.fill(CGRect(x: CGFloat(x) + 20, y: h - 220, width: 1, height: 200))
        }

        let text = String(format: "Mac Second Monitor  %dx%d  frame %d  t=%.3f", width, height, frameIndex, Double(HostClock.nowMicros()) / 1_000_000)
        // Fit portrait screens too: the caption is ~32 em wide.
        drawText(text, at: CGPoint(x: 40, y: h * 0.62), size: min(h * 0.035, (w - 80) / 32), in: context)

        if let pointer = pointer.current {
            let center = CGPoint(x: pointer.x * w, y: pointer.y * h)
            context.setStrokeColor(CGColor(srgbRed: 1, green: 0.3, blue: 0.3, alpha: 1))
            context.setLineWidth(4)
            context.strokeEllipse(in: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
        }
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.saveGState()
        // Undo the flip for text so glyphs are upright.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
