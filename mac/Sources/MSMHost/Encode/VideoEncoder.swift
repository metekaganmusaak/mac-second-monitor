import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum VideoCodec: String, Sendable, CaseIterable {
    case h264
    case hevc
}

public struct EncodedFrame: Sendable {
    /// Annex-B access unit; keyframes start with the parameter sets.
    public var data: Data
    public var isKeyframe: Bool
    public var captureTimeMicros: UInt64
    public var encodeMicros: UInt64
    /// RFC 6381 codec string, present on keyframes.
    public var codecString: String?
}

public enum EncoderError: Error, LocalizedError {
    case sessionCreationFailed(OSStatus)
    case encodeFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .sessionCreationFailed(status): L10n.tr("error.encoder.create", Int(status))
        case let .encodeFailed(status): L10n.tr("error.encoder.encode", Int(status))
        }
    }
}

/// Hardware H.264 / HEVC encoder tuned for latency: real-time, no frame reordering,
/// low-latency rate control where available, keyframes only on request.
public final class VideoEncoder: @unchecked Sendable {
    public struct Settings: Sendable, Equatable {
        public var codec: VideoCodec
        public var width: Int
        public var height: Int
        public var fps: Int
        /// Bits per second.
        public var bitrate: Int

        public init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrate: Int) {
            self.codec = codec
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrate = bitrate
        }
    }

    public private(set) var settings: Settings
    public private(set) var usesLowLatencyRateControl = false
    private var session: VTCompressionSession?
    private var lastTimestamp: Int64 = 0
    private let lock = NSLock()

    public init(settings: Settings) throws {
        self.settings = settings
        try createSession()
    }

    deinit {
        invalidate()
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    public func setBitrate(_ bitrate: Int) {
        lock.lock()
        defer { lock.unlock() }
        settings.bitrate = bitrate
        if let session {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        }
    }

    /// Encodes one frame. `completion` runs on a VideoToolbox thread with the encoded
    /// frame, or `nil` if the encoder dropped it.
    public func encode(
        _ pixelBuffer: CVPixelBuffer,
        captureTimeMicros: UInt64,
        forceKeyframe: Bool,
        completion: @escaping @Sendable (Result<EncodedFrame, Error>?) -> Void
    ) {
        lock.lock()
        if session == nil {
            try? createSession()
        }
        guard let session else {
            lock.unlock()
            completion(.failure(EncoderError.sessionCreationFailed(kVTInvalidSessionErr)))
            return
        }
        // Timestamps must increase even when the same image is re-encoded.
        let timestamp = max(Int64(HostClock.nowMicros()), lastTimestamp + 1)
        lastTimestamp = timestamp
        lock.unlock()

        let started = HostClock.nowMicros()
        let codec = settings.codec
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            : nil

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: timestamp, timescale: 1_000_000),
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { status, flags, sampleBuffer in
            if status != noErr {
                completion(.failure(EncoderError.encodeFailed(status)))
                return
            }
            guard !flags.contains(.frameDropped), let sampleBuffer,
                  var frame = Self.makeFrame(sampleBuffer, codec: codec)
            else {
                completion(nil)
                return
            }
            frame.captureTimeMicros = captureTimeMicros
            frame.encodeMicros = HostClock.nowMicros() - started
            completion(.success(frame))
        }

        if status != noErr {
            if status == kVTInvalidSessionErr {
                // Happens after sleep / GPU changes; rebuild on the next frame.
                invalidate()
            }
            completion(.failure(EncoderError.encodeFailed(status)))
        }
    }

    // Must be called with `lock` held (or from init).
    private func createSession() throws {
        let codecType = settings.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        var lowLatency = settings.codec == .h264

        func makeSession(lowLatency: Bool) -> OSStatus {
            var specification: [CFString: Any] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue!,
            ]
            if lowLatency {
                specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = kCFBooleanTrue!
            }
            return VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(settings.width),
                height: Int32(settings.height),
                codecType: codecType,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
        }

        var status = makeSession(lowLatency: lowLatency)
        if status != noErr && lowLatency {
            Log.encoder.notice("Low-latency rate control unavailable (\(status)); falling back")
            lowLatency = false
            status = makeSession(lowLatency: false)
        }
        guard status == noErr, let session = created else {
            throw EncoderError.sessionCreationFailed(status)
        }

        func set(_ key: CFString, _ value: CFTypeRef) {
            let result = VTSessionSetProperty(session, key: key, value: value)
            if result != noErr {
                Log.encoder.debug("Property \(key as String, privacy: .public) not supported (\(result))")
            }
        }

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, settings.fps as CFNumber)
        set(kVTCompressionPropertyKey_AverageBitRate, settings.bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if settings.codec == .h264 {
            let profile = lowLatency ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
            set(kVTCompressionPropertyKey_ProfileLevel, profile)
            set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        } else {
            set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        self.session = session
        usesLowLatencyRateControl = lowLatency
        Log.encoder.info("Encoder \(self.settings.codec.rawValue, privacy: .public) \(self.settings.width)x\(self.settings.height)@\(self.settings.fps) \(self.settings.bitrate / 1000) kbps lowLatency=\(lowLatency)")
    }

    static func makeFrame(_ sampleBuffer: CMSampleBuffer, codec: VideoCodec) -> EncodedFrame? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              let format = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        let (parameterSets, lengthSize) = Self.parameterSets(format, codec: codec)
        var output = Data()
        output.reserveCapacity(CMBlockBufferGetDataLength(dataBuffer) + 256)

        var codecString: String?
        if isKeyframe {
            AnnexB.appendParameterSets(parameterSets, to: &output)
            if codec == .h264, let sps = parameterSets.first(where: { ($0.first ?? 0) & 0x1F == 7 }) {
                codecString = AnnexB.h264CodecString(sps: sps)
            } else if codec == .hevc, let sps = parameterSets.first(where: { (($0.first ?? 0) >> 1) & 0x3F == 33 }) {
                codecString = AnnexB.hevcCodecString(sps: sps)
            }
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var contiguous = Data(count: length)
        let copied = contiguous.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base) == kCMBlockBufferNoErr
        }
        guard copied else { return nil }

        let converted = contiguous.withUnsafeBytes { buffer in
            AnnexB.appendConvertingLengthPrefixed(buffer, lengthSize: lengthSize, to: &output)
        }
        guard converted else {
            Log.encoder.error("Malformed encoder output")
            return nil
        }
        return EncodedFrame(data: output, isKeyframe: isKeyframe, captureTimeMicros: 0, encodeMicros: 0, codecString: codecString)
    }

    private static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> ([Data], Int) {
        var count = 0
        var lengthSize: Int32 = 4
        var sets: [Data] = []

        switch codec {
        case .h264:
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        case .hevc:
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &lengthSize)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        }
        return (sets, Int(lengthSize))
    }
}
