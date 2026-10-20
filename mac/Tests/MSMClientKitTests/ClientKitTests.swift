import Foundation
import MSMProtocol
import Testing
@testable import MSMClientKit

@Suite struct AnnexBParserTests {
    @Test func splitsMixedStartCodes() {
        let data = Data([0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65, 3, 4])
        let units = AnnexBParser.nalUnits(in: data)
        #expect(units == [Data([0x67, 1]), Data([0x68, 2]), Data([0x65, 3, 4])])
    }

    @Test func classifiesParameterSets() {
        #expect(StreamCodec.h264.isParameterSet(Data([0x67])))
        #expect(StreamCodec.h264.isParameterSet(Data([0x68])))
        #expect(!StreamCodec.h264.isParameterSet(Data([0x65])))
        #expect(StreamCodec.hevc.isParameterSet(Data([0x40, 0x01])))
        #expect(StreamCodec.hevc.isParameterSet(Data([0x42, 0x01])))
        #expect(!StreamCodec.hevc.isParameterSet(Data([0x26, 0x01])))
    }

    @Test func noFormatBeforeKeyframe() {
        let factory = SampleBufferFactory(codec: .h264)
        let frame = VideoFrame(seq: 1, captureTimeMicros: 0, isKeyframe: false, data: Data([0, 0, 0, 1, 0x41, 0x9A]))
        #expect(factory.makeSampleBuffer(frame) == nil)
    }
}
