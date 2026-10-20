import CoreMedia
import CoreVideo
import Foundation
import MSMProtocol
import VideoToolbox

/// Splits an Annex-B byte stream into NAL units (without start codes).
public enum AnnexBParser {
    public static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start {
                    var end = index
                    // A 4-byte start code's leading zero belongs to the start code.
                    if end > start, bytes[end - 1] == 0 { end -= 1 }
                    units.append(Data(bytes[start..<end]))
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count {
            units.append(Data(bytes[start...]))
        }
        return units
    }
}

public enum StreamCodec: String, Sendable {
    case h264
    case hevc

    func isParameterSet(_ nal: Data) -> Bool {
        guard let first = nal.first else { return false }
        switch self {
        case .h264: return [7, 8].contains(first & 0x1F)
        case .hevc: return [32, 33, 34].contains((first >> 1) & 0x3F)
        }
    }
}

/// Converts wire frames into `CMSampleBuffer`s (AVCC / HVCC) for VideoToolbox or
/// `AVSampleBufferDisplayLayer`, tracking the format description from keyframes.
public final class SampleBufferFactory {
    public private(set) var formatDescription: CMVideoFormatDescription?
    public var codec: StreamCodec

    public init(codec: StreamCodec) {
        self.codec = codec
    }

    public func makeSampleBuffer(_ frame: VideoFrame) -> CMSampleBuffer? {
        let units = AnnexBParser.nalUnits(in: frame.data)
        let parameterSets = units.filter(codec.isParameterSet)
        if !parameterSets.isEmpty {
            updateFormat(parameterSets)
        }
        guard let formatDescription else { return nil }

        var avcc = Data()
        for unit in units where !codec.isParameterSet(unit) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        guard !avcc.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer
        else { return nil }
        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame.captureTimeMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: formatDescription, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer
        else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !frame.isKeyframe {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sampleBuffer
    }

    private func updateFormat(_ sets: [Data]) {
        let pointers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: pointer, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let constPointers = pointers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var description: CMFormatDescription?
        let status: OSStatus = switch codec {
        case .h264:
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: constPointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
        case .hevc:
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: constPointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
        }
        if status == noErr, let description {
            formatDescription = description
        }
    }
}

/// Hardware decoder producing pixel buffers (used by the CLI probe and tests).
public final class PixelBufferDecoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private let pixelFormat: OSType

    public init(pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.pixelFormat = pixelFormat
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    /// Decodes synchronously and returns the image, or nil on failure.
    public func decode(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        if session == nil || !(self.format.map { CMFormatDescriptionEqual($0, otherFormatDescription: format) } ?? false) {
            if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
                self.format = format
            } else {
                createSession(format)
            }
        }
        guard let session else { return nil }

        let result = Locked<CVPixelBuffer?>(nil)
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer {
                result.set(imageBuffer)
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr ? result.get() : nil
    }

    private func createSession(_ format: CMVideoFormatDescription) {
        if let session { VTDecompressionSessionInvalidate(session) }
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: pixelFormat]
        var created: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary, outputCallback: nil, decompressionSessionOut: &created)
        session = created
        self.format = format
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&value)
        lock.unlock()
    }
}
