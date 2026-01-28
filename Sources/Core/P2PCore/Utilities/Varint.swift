/// Utilities for encoding and decoding unsigned varints.
/// https://github.com/multiformats/unsigned-varint

import Foundation

public enum Varint {

    /// Encodes a UInt64 value as an unsigned varint.
    ///
    /// - Parameter value: The value to encode
    /// - Returns: The varint-encoded bytes
    public static func encode(_ value: UInt64) -> Data {
        var n = value
        var bytes = Data()

        while n >= 0x80 {
            bytes.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
        }
        bytes.append(UInt8(n))

        return bytes
    }

    /// Decodes an unsigned varint from the given data.
    ///
    /// - Parameter data: The data to decode from
    /// - Returns: A tuple of (decoded value, bytes consumed)
    /// - Throws: `VarintError` if the data is malformed
    public static func decode(_ data: Data) throws -> (value: UInt64, bytesRead: Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var bytesRead = 0

        for byte in data {
            bytesRead += 1

            if shift >= 63 && byte > 1 {
                throw VarintError.overflow
            }

            value |= UInt64(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                return (value, bytesRead)
            }

            shift += 7

            if bytesRead >= 10 {
                throw VarintError.overflow
            }
        }

        throw VarintError.insufficientData
    }

    /// Decodes an unsigned varint from data at the given offset.
    ///
    /// Uses direct index-based access for zero-copy performance.
    /// Suitable for hot paths where creating Data slices would be costly.
    ///
    /// - Parameters:
    ///   - data: Source data (may be a slice with non-zero startIndex)
    ///   - offset: Logical offset from the start of data
    /// - Returns: Decoded value and number of bytes consumed
    /// - Throws: `.insufficientData` if incomplete, `.overflow` if malformed
    public static func decode(from data: Data, at offset: Int) throws -> (value: UInt64, bytesRead: Int) {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var bytesRead = 0
        var index = data.startIndex + offset

        while index < data.endIndex {
            let byte = data[index]
            bytesRead += 1
            index += 1

            if shift >= 63 && byte > 1 {
                throw VarintError.overflow
            }

            value |= UInt64(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                return (value, bytesRead)
            }

            shift += 7

            if bytesRead >= 10 {
                throw VarintError.overflow
            }
        }

        throw VarintError.insufficientData
    }

    /// Decodes an unsigned varint from the given data, returning the value and remaining data.
    ///
    /// - Parameter data: The data to decode from
    /// - Returns: A tuple of (decoded value, remaining data)
    /// - Throws: `VarintError` if the data is malformed
    public static func decodeWithRemainder(_ data: Data) throws -> (value: UInt64, remainder: Data) {
        let (value, bytesRead) = try decode(data)
        return (value, data.dropFirst(bytesRead))
    }
}

public enum VarintError: Error, Equatable {
    case overflow
    case insufficientData
    case valueExceedsIntMax(UInt64)
}

// MARK: - Safe Int Conversion

extension Varint {

    /// Decodes an unsigned varint and converts it to Int.
    ///
    /// This method provides a safe way to decode a varint when the result
    /// needs to be used as an Int (e.g., for array indexing or Data operations).
    /// It throws an error if the decoded value exceeds Int.max.
    ///
    /// - Parameter data: The data to decode from
    /// - Returns: A tuple of (decoded value as Int, bytes consumed)
    /// - Throws: `VarintError.valueExceedsIntMax` if the value is too large,
    ///           or other `VarintError` cases for malformed data
    public static func decodeAsInt(_ data: Data) throws -> (value: Int, bytesRead: Int) {
        let (value, bytesRead) = try decode(data)
        guard let intValue = Int(exactly: value) else {
            throw VarintError.valueExceedsIntMax(value)
        }
        return (intValue, bytesRead)
    }

    /// Decodes an unsigned varint and converts it to Int, returning remainder.
    ///
    /// - Parameter data: The data to decode from
    /// - Returns: A tuple of (decoded value as Int, remaining data)
    /// - Throws: `VarintError.valueExceedsIntMax` if the value is too large
    public static func decodeAsIntWithRemainder(_ data: Data) throws -> (value: Int, remainder: Data) {
        let (value, bytesRead) = try decodeAsInt(data)
        return (value, data.dropFirst(bytesRead))
    }

    /// Safely converts a UInt64 to Int.
    ///
    /// - Parameter value: The UInt64 value to convert
    /// - Returns: The value as Int
    /// - Throws: `VarintError.valueExceedsIntMax` if the value exceeds Int.max
    public static func toInt(_ value: UInt64) throws -> Int {
        guard let intValue = Int(exactly: value) else {
            throw VarintError.valueExceedsIntMax(value)
        }
        return intValue
    }
}
