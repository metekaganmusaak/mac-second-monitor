import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: L10n.tr("error.capture.permissionDenied")
        case let .displayNotFound(id): L10n.tr("error.capture.displayNotFound", Int(id))
        }
    }
}

/// Produces frames for the encoder: either a real display or a test pattern.
public protocol FrameSource: AnyObject, Sendable {
    /// Called on an internal queue for every new frame. Static screens produce no frames.
    var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)? { get set }
    var onStop: (@Sendable (Error?) -> Void)? { get set }
    func start() async throws
    func stop() async
}

/// Captures one display with ScreenCaptureKit, scaled to the client's resolution.
public final class ScreenCapturer: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var displayID: CGDirectDisplayID
        public var width: Int
        public var height: Int
        public var fps: Int
        public var showsCursor: Bool

        public init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, showsCursor: Bool = true) {
            self.displayID = displayID
            self.width = width
            self.height = height
            self.fps = fps
            self.showsCursor = showsCursor
        }
    }

    public var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    public var onStop: (@Sendable (Error?) -> Void)?

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "com.macsecondmonitor.capture", qos: .userInteractive)
    private var stream: SCStream?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func start() async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        let display = try await Self.findDisplay(configuration.displayID)
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = configuration.width
        config.height = configuration.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        config.preservesAspectRatio = true
        config.showsCursor = configuration.showsCursor
        config.queueDepth = 5
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.capture.info("Capturing display \(self.configuration.displayID) at \(self.configuration.width)x\(self.configuration.height)@\(self.configuration.fps)")
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// A new virtual display can take a moment to show up in the shareable content.
    private static func findDisplay(_ id: CGDirectDisplayID) async throws -> SCDisplay {
        for attempt in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == id }) {
                return display
            }
            if attempt < 19 {
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        throw CaptureError.displayNotFound(id)
    }

    public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    public func stream(_: SCStream, didStopWithError error: Error) {
        Log.capture.error("Capture stopped: \(error.localizedDescription, privacy: .public)")
        stream = nil
        onStop?(error)
    }
}
