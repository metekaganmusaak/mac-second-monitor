import Foundation

/// Conversions between the length-prefixed (AVCC / HVCC) layout VideoToolbox produces
/// and the Annex-B start-code layout the wire protocol uses.
enum AnnexB {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Rewrites `lengthSize`-byte length prefixes to start codes and appends to `output`.
    static func appendConvertingLengthPrefixed(_ input: UnsafeRawBufferPointer, lengthSize: Int, to output: inout Data) -> Bool {
        var offset = 0
        while offset + lengthSize <= input.count {
            var length = 0
            for index in 0..<lengthSize {
                length = (length << 8) | Int(input[offset + index])
            }
            offset += lengthSize
            guard length > 0, offset + length <= input.count else { return false }
            output.append(contentsOf: startCode)
            output.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[offset..<(offset + length)]))
            offset += length
        }
        return offset == input.count
    }

    static func appendParameterSets(_ sets: [Data], to output: inout Data) {
        for set in sets {
            output.append(contentsOf: startCode)
            output.append(set)
        }
    }

    /// RFC 6381 codec string for H.264 from the SPS: `avc1.PPCCLL`.
    static func h264CodecString(sps: Data) -> String {
        guard sps.count >= 4 else { return "avc1.640033" }
        let bytes = Array(sps.prefix(4))
        return String(format: "avc1.%02X%02X%02X", bytes[1], bytes[2], bytes[3])
    }

    /// RFC 6381 / ISO 14496-15 codec string for HEVC from the SPS, e.g. `hvc1.1.6.L150.B0`.
    static func hevcCodecString(sps: Data) -> String {
        let rbsp = removingEmulationPrevention(Array(sps))
        // 2-byte NAL header, 1 byte (vps id, max sub layers, nesting), then profile_tier_level.
        guard rbsp.count >= 15 else { return "hvc1.1.6.L120.B0" }
        let profileByte = rbsp[3]
        let profileSpace = Int(profileByte >> 6)
        let tierFlag = (profileByte >> 5) & 1
        let profileIdc = Int(profileByte & 0x1F)
        let compatibility = UInt32(rbsp[4]) << 24 | UInt32(rbsp[5]) << 16 | UInt32(rbsp[6]) << 8 | UInt32(rbsp[7])
        let constraints = Array(rbsp[8..<14])
        let level = Int(rbsp[14])

        // The compatibility flags are written in reverse bit order.
        var reversed: UInt32 = 0
        for bit in 0..<32 where compatibility & (1 << bit) != 0 {
            reversed |= 1 << (31 - bit)
        }

        let space = ["", "A", "B", "C"][profileSpace]
        var parts = ["hvc1", "\(space)\(profileIdc)", String(reversed, radix: 16, uppercase: true), "\(tierFlag == 1 ? "H" : "L")\(level)"]
        var trailing = constraints
        while let last = trailing.last, last == 0 {
            trailing.removeLast()
        }
        parts.append(contentsOf: trailing.map { String($0, radix: 16, uppercase: true) })
        return parts.joined(separator: ".")
    }

    static func removingEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 0x03 {
                zeros = 0
                continue
            }
            zeros = byte == 0 ? zeros + 1 : 0
            output.append(byte)
        }
        return output
    }
}
