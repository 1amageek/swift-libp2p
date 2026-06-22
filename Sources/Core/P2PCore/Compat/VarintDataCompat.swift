/// `Data`/NIO `ByteBuffer` compatibility surface for the moved ``Varint`` type.
///
/// The Embedded-clean core (``LibP2PCore``) exposes the unsigned-varint (LEB128)
/// codec over `[UInt8]`: `encodeBytes(_:)`, `encode(_:into:[UInt8])`,
/// `decode(from:[UInt8],at:)`, `decode(_:[UInt8])`, `toInt(_:)`,
/// `decodeAsInt(_:[UInt8])`. This adapter restores the historical
/// `Data` / `ByteBuffer` / `UnsafeRawBufferPointer` API so existing callers and
/// the test suite compile unchanged. It is pure bridging — no new codec logic.

import Foundation
import NIOCore
import LibP2PCore

extension Varint {

    // MARK: - Encoding (Data)

    /// Encodes a `UInt64` value as an unsigned varint into new `Data`.
    @inlinable
    public static func encode(_ value: UInt64) -> Data {
        Data(encodeBytes(value))
    }

    /// Encodes a `UInt64` value as an unsigned varint, appending to `Data`.
    /// - Returns: Number of bytes written.
    @discardableResult
    @inlinable
    public static func encode(_ value: UInt64, into data: inout Data) -> Int {
        let bytes = encodeBytes(value)
        data.append(contentsOf: bytes)
        return bytes.count
    }

    // MARK: - Encoding (raw buffer / NIO ByteBuffer)

    /// Encodes a `UInt64` value directly into a raw buffer (capacity >= 10).
    /// - Returns: Number of bytes written.
    @inlinable
    public static func encode(_ value: UInt64, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        var n = value
        var i = 0
        while n >= 0x80 {
            buffer[i] = UInt8(n & 0x7F) | 0x80
            n >>= 7
            i += 1
        }
        buffer[i] = UInt8(n)
        return i + 1
    }

    /// Encodes a `UInt64` value into a NIO `ByteBuffer` (zero-copy).
    /// - Returns: Number of bytes written.
    @discardableResult
    @inlinable
    public static func encode(_ value: UInt64, into buffer: inout ByteBuffer) -> Int {
        buffer.reserveCapacity(buffer.writerIndex + 10)
        return buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: 10) { ptr in
            encode(value, into: ptr)
        }
    }

    // MARK: - Decoding (Data)

    /// Decodes an unsigned varint from the given `Data`.
    /// - Returns: A tuple of (decoded value, bytes consumed).
    @inlinable
    public static func decode(_ data: Data) throws -> (value: UInt64, bytesRead: Int) {
        try decode(from: data, at: 0)
    }

    /// Decodes an unsigned varint from `Data` at the given offset.
    /// - Returns: A tuple of (decoded value, bytes consumed).
    @inlinable
    public static func decode(from data: Data, at offset: Int) throws -> (value: UInt64, bytesRead: Int) {
        try data.withUnsafeBytes { ptr in
            try decode(from: ptr, at: offset)
        }
    }

    /// Decodes an unsigned varint directly from a raw buffer pointer.
    /// - Returns: A tuple of (decoded value, bytes consumed).
    @inlinable
    public static func decode(
        from buffer: UnsafeRawBufferPointer, at offset: Int
    ) throws -> (value: UInt64, bytesRead: Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset

        while i < buffer.count {
            let byte = buffer[i]
            i += 1

            if shift >= 63 && byte > 1 {
                throw VarintError.overflow
            }

            value |= UInt64(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                return (value, i - offset)
            }

            shift += 7

            if i - offset >= 10 {
                throw VarintError.overflow
            }
        }

        throw VarintError.insufficientData
    }

    // MARK: - Decoding (NIO ByteBuffer)

    /// Decodes an unsigned varint from a NIO `ByteBuffer` (advances reader index).
    @inlinable
    public static func decode(from buffer: inout ByteBuffer) throws -> UInt64 {
        let result = try buffer.withUnsafeReadableBytes { ptr -> (UInt64, Int) in
            try decode(from: ptr, at: 0)
        }
        buffer.moveReaderIndex(forwardBy: result.1)
        return result.0
    }

    // MARK: - Remainder helpers (Data)

    /// Decodes an unsigned varint, returning the value and remaining `Data`.
    @inlinable
    public static func decodeWithRemainder(_ data: Data) throws -> (value: UInt64, remainder: Data) {
        let (value, bytesRead) = try decode(data)
        return (value, data.dropFirst(bytesRead))
    }

    // MARK: - Int conversion (Data)

    /// Decodes an unsigned varint and converts it to `Int`.
    @inlinable
    public static func decodeAsInt(_ data: Data) throws -> (value: Int, bytesRead: Int) {
        let (value, bytesRead) = try decode(data)
        let intValue = try toInt(value)
        return (intValue, bytesRead)
    }

    /// Decodes an unsigned varint and converts it to `Int`, returning remainder.
    @inlinable
    public static func decodeAsIntWithRemainder(_ data: Data) throws -> (value: Int, remainder: Data) {
        let (value, bytesRead) = try decodeAsInt(data)
        return (value, data.dropFirst(bytesRead))
    }
}
