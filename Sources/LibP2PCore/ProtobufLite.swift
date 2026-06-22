/// Lightweight protobuf encode/decode for wire type 2 (length-delimited) fields.
///
/// Used by Noise (NoisePayload) and Plaintext (Exchange) security modules.
/// Scope: wire type 2 only. PublicKey uses mixed wire types and is excluded.
///
/// Embedded-clean: no Foundation. The byte container is `[UInt8]`; the
/// `Data`-based surface lives in the `P2PCore` adapter.

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
public struct ProtobufField: Sendable {
    public let fieldNumber: UInt64

    /// The field data.
    public let data: [UInt8]

    public init(fieldNumber: UInt64, data: [UInt8]) {
        self.fieldNumber = fieldNumber
        self.data = data
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
public func encodeProtobufField(fieldNumber: UInt64, data: [UInt8]) -> [UInt8] {
    let tag = (fieldNumber << 3) | 2
    var result = Varint.encodeBytes(tag)
    result.append(contentsOf: Varint.encodeBytes(UInt64(data.count)))
    result.append(contentsOf: data)
    return result
}

/// Decodes all protobuf fields from bytes, requiring wire type 2 (length-delimited).
///
/// Unknown field numbers are preserved in the result. Wire types other than 2
/// cause an error since the Noise/Plaintext protobuf schemas only use
/// length-delimited fields.
///
/// - Parameters:
///   - bytes: The protobuf-encoded bytes.
///   - maxFieldSize: Maximum allowed size for a single field (default: 1 MB).
/// - Returns: Array of decoded fields in order of appearance.
/// - Throws: `ProtobufLiteError` on invalid data.
public func decodeProtobufFields(
    from bytes: [UInt8],
    maxFieldSize: Int = 1_048_576
) throws(ProtobufLiteError) -> [ProtobufField] {
    var fields: [ProtobufField] = []
    var offset = 0

    while offset < bytes.count {
        let fieldTag: UInt64
        let tagBytes: Int
        do {
            (fieldTag, tagBytes) = try Varint.decode(from: bytes, at: offset)
        } catch {
            throw .truncatedField
        }
        offset += tagBytes

        let fieldNumber = fieldTag >> 3
        let wireType = fieldTag & 0x07

        guard wireType == 2 else {
            throw ProtobufLiteError.unexpectedWireType(wireType)
        }

        let fieldLength: UInt64
        let lengthBytes: Int
        do {
            (fieldLength, lengthBytes) = try Varint.decode(from: bytes, at: offset)
        } catch {
            throw .truncatedField
        }
        offset += lengthBytes

        guard fieldLength <= UInt64(maxFieldSize) else {
            throw ProtobufLiteError.fieldTooLarge(size: fieldLength, max: maxFieldSize)
        }

        let length = Int(fieldLength)

        guard offset + length <= bytes.count else {
            throw ProtobufLiteError.truncatedField
        }

        fields.append(ProtobufField(
            fieldNumber: fieldNumber,
            data: Array(bytes[offset..<(offset + length)])
        ))
        offset += length
    }

    return fields
}
