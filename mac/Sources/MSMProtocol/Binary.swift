import Foundation

public enum ProtocolError: Error, Equatable, Sendable {
    case truncated
    case payloadTooLarge(Int)
    case invalidPayload(String)
}

/// Appends big-endian values to a `Data` buffer.
public struct ByteWriter: Sendable {
    public private(set) var data: Data

    public init(capacity: Int = 0) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    public mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func u16(_ value: UInt16) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func f32(_ value: Float) {
        u32(value.bitPattern)
    }

    public mutating func bytes(_ value: Data) {
        data.append(value)
    }
}

/// Reads big-endian values from a `Data` buffer (any slice, any start index).
public struct ByteReader: Sendable {
    private let data: Data
    private var position: Data.Index

    public init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    public var remaining: Int { data.endIndex - position }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtocolError.truncated }
        defer { position += 1 }
        return data[position]
    }

    public mutating func u16() throws -> UInt16 {
        UInt16(truncatingIfNeeded: try integer(byteCount: 2))
    }

    public mutating func u32() throws -> UInt32 {
        UInt32(truncatingIfNeeded: try integer(byteCount: 4))
    }

    public mutating func u64() throws -> UInt64 {
        try integer(byteCount: 8)
    }

    public mutating func f32() throws -> Float {
        Float(bitPattern: try u32())
    }

    public mutating func skip(_ count: Int) throws {
        guard remaining >= count else { throw ProtocolError.truncated }
        position += count
    }

    /// Returns all bytes that have not been read yet.
    public mutating func rest() -> Data {
        defer { position = data.endIndex }
        return data[position..<data.endIndex]
    }

    private mutating func integer(byteCount: Int) throws -> UInt64 {
        guard remaining >= byteCount else { throw ProtocolError.truncated }
        var value: UInt64 = 0
        for index in position..<(position + byteCount) {
            value = (value << 8) | UInt64(data[index])
        }
        position += byteCount
        return value
    }
}
