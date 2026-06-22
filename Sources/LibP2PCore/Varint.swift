/// Unsigned-varint (LEB128) encode/decode — the multiformats unsigned-varint.
/// https://github.com/multiformats/unsigned-varint
///
/// Embedded-clean: no Foundation, no NIO, no `any`. The byte container is
/// `[UInt8]`; the `Data`/`ByteBuffer`/`UnsafeRawBufferPointer` surface lives in
/// the `P2PCore` Foundation adapter as extensions over this namespace.

public enum Varint {

    /// Encodes a `UInt64` value as an unsigned varint into a new byte array.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The varint-encoded bytes.
    @inlinable
    public static func encodeBytes(_ value: UInt64) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(10)
        var n = value
        while n >= 0x80 {
            result.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
        }
        result.append(UInt8(n))
        return result
    }

    /// Encodes a `UInt64` value as an unsigned varint, appending to `array`.
    ///
    /// - Parameters:
    ///   - value: The value to encode.
    ///   - array: Destination array (mutated in place).
    /// - Returns: Number of bytes appended.
    @discardableResult
    @inlinable
    public static func encode(_ value: UInt64, into array: inout [UInt8]) -> Int {
        var n = value
        var count = 0
        while n >= 0x80 {
            array.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
            count += 1
        }
        array.append(UInt8(n))
        return count + 1
    }

    /// Decodes an unsigned varint from a byte array at the given offset.
    ///
    /// Index-based access; no slices or copies are created.
    ///
    /// - Parameters:
    ///   - bytes: Source bytes.
    ///   - offset: Byte offset to start decoding from.
    /// - Returns: Decoded value and number of bytes consumed.
    /// - Throws: `.insufficientData` if incomplete, `.overflow` if malformed.
    @inlinable
    public static func decode(
        from bytes: [UInt8], at offset: Int
    ) throws(VarintError) -> (value: UInt64, bytesRead: Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset

        while i < bytes.count {
            let byte = bytes[i]
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

    /// Decodes an unsigned varint from the start of a byte array.
    ///
    /// - Parameter bytes: The bytes to decode from.
    /// - Returns: Decoded value and number of bytes consumed.
    /// - Throws: `VarintError` if the bytes are malformed.
    @inlinable
    public static func decode(
        _ bytes: [UInt8]
    ) throws(VarintError) -> (value: UInt64, bytesRead: Int) {
        try decode(from: bytes, at: 0)
    }
}

public enum VarintError: Error, Equatable, Sendable {
    case overflow
    case insufficientData
    case valueExceedsIntMax(UInt64)
}

// MARK: - Safe Int Conversion

extension Varint {

    /// Safely converts a `UInt64` to `Int`.
    ///
    /// - Parameter value: The value to convert.
    /// - Returns: The value as `Int`.
    /// - Throws: `VarintError.valueExceedsIntMax` if the value exceeds `Int.max`.
    @inlinable
    public static func toInt(_ value: UInt64) throws(VarintError) -> Int {
        guard let intValue = Int(exactly: value) else {
            throw VarintError.valueExceedsIntMax(value)
        }
        return intValue
    }

    /// Decodes an unsigned varint and converts the value to `Int`.
    ///
    /// - Parameter bytes: The bytes to decode from.
    /// - Returns: Decoded value as `Int` and number of bytes consumed.
    /// - Throws: `VarintError.valueExceedsIntMax` if the value exceeds `Int.max`,
    ///           or other `VarintError` cases for malformed data.
    @inlinable
    public static func decodeAsInt(
        _ bytes: [UInt8]
    ) throws(VarintError) -> (value: Int, bytesRead: Int) {
        let (value, bytesRead) = try decode(bytes)
        let intValue = try toInt(value)
        return (intValue, bytesRead)
    }
}
