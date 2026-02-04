/// Lightweight protobuf encode/decode for wire type 2 (length-delimited) fields.
///
/// Used by Noise (NoisePayload) and Plaintext (Exchange) security modules.
/// Scope: wire type 2 only. PublicKey uses mixed wire types and is excluded.

import Foundation

/// Errors from lightweight protobuf decode operations.
public enum ProtobufLiteError: Error, Sendable, Equatable {
    /// Encountered a wire type other than 2 (length-delimited).
    case unexpectedWireType(UInt64)
    /// Field data extends beyond available bytes.
    case truncatedField
    /// Field size exceeds the allowed maximum.
    case fieldTooLarge(size: UInt64, max: Int)
}

/// A decoded protobuf field (wire type 2 only).
///
/// Stores a reference to the source data and offset/length to avoid copying.
/// The `data` property returns a slice that shares storage with the source.
public struct ProtobufField: Sendable {
    public let fieldNumber: UInt64

    /// Source data containing the field.
    private let sourceData: Data

    /// Offset from sourceData.startIndex to the field data.
    private let dataOffset: Int

    /// Length of the field data.
    private let dataLength: Int

    /// The field data as a slice of the source (zero-copy).
    public var data: Data {
        let start = sourceData.startIndex + dataOffset
        return sourceData[start ..< start + dataLength]
    }

    internal init(fieldNumber: UInt64, sourceData: Data, offset: Int, length: Int) {
        self.fieldNumber = fieldNumber
        self.sourceData = sourceData
        self.dataOffset = offset
        self.dataLength = length
    }
}

/// Encodes a single protobuf length-delimited field (wire type 2).
///
/// Format: tag (varint) + length (varint) + data
/// where tag = (fieldNumber << 3) | 2
///
/// - Parameters:
///   - fieldNumber: The protobuf field number (1-based).
///   - data: The field data to encode.
/// - Returns: Encoded bytes for this field.
public func encodeProtobufField(fieldNumber: UInt64, data: Data) -> Data {
    var result = Data()
    let tag = (fieldNumber << 3) | 2
    result.append(contentsOf: Varint.encode(tag))
    result.append(contentsOf: Varint.encode(UInt64(data.count)))
    result.append(data)
    return result
}

/// Decodes all protobuf fields from data, requiring wire type 2 (length-delimited).
///
/// Unknown field numbers are preserved in the result. Wire types other than 2
/// cause an error since the Noise/Plaintext protobuf schemas only use
/// length-delimited fields.
///
/// - Parameters:
///   - data: The protobuf-encoded data.
///   - maxFieldSize: Maximum allowed size for a single field (default: 1 MB).
/// - Returns: Array of decoded fields in order of appearance.
/// - Throws: `ProtobufLiteError` on invalid data.
public func decodeProtobufFields(
    from data: Data,
    maxFieldSize: Int = 1_048_576
) throws -> [ProtobufField] {
    var fields: [ProtobufField] = []
    var offset = 0

    while offset < data.count {
        let (fieldTag, tagBytes) = try Varint.decode(from: data, at: offset)
        offset += tagBytes

        let fieldNumber = fieldTag >> 3
        let wireType = fieldTag & 0x07

        guard wireType == 2 else {
            throw ProtobufLiteError.unexpectedWireType(wireType)
        }

        let (fieldLength, lengthBytes) = try Varint.decode(from: data, at: offset)
        offset += lengthBytes

        guard fieldLength <= UInt64(maxFieldSize) else {
            throw ProtobufLiteError.fieldTooLarge(size: fieldLength, max: maxFieldSize)
        }

        let length = Int(fieldLength)

        guard offset + length <= data.count else {
            throw ProtobufLiteError.truncatedField
        }

        // Zero-copy: store reference to source data with offset/length
        fields.append(ProtobufField(
            fieldNumber: fieldNumber,
            sourceData: data,
            offset: offset,
            length: length
        ))
        offset += length
    }

    return fields
}
