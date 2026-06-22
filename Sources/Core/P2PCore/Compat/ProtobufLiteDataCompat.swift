/// `Data` compatibility surface for the moved protobuf-lite helpers.
///
/// The Embedded-clean core (``LibP2PCore``) exposes the wire-type-2 codec over
/// `[UInt8]`: `encodeProtobufField(fieldNumber:data:[UInt8]) -> [UInt8]` and
/// `decodeProtobufFields(from:[UInt8]) -> [ProtobufField]` (where
/// `ProtobufField.data` is `[UInt8]`). These overloads restore the historical
/// `Data`-based API so existing callers and the test suite compile unchanged.
/// `ProtobufField.data` (`[UInt8]`) compares against `Data` via the
/// ``ByteArrayDataCompat`` bridges.

import Foundation
import LibP2PCore

/// Encodes a single protobuf length-delimited field (wire type 2), `Data` in/out.
public func encodeProtobufField(fieldNumber: UInt64, data: Data) -> Data {
    Data(encodeProtobufField(fieldNumber: fieldNumber, data: [UInt8](data)))
}

/// Decodes all protobuf fields (wire type 2) from `Data`.
/// - Throws: `ProtobufLiteError` on invalid data.
public func decodeProtobufFields(
    from data: Data,
    maxFieldSize: Int = 1_048_576
) throws -> [ProtobufField] {
    try decodeProtobufFields(from: [UInt8](data), maxFieldSize: maxFieldSize)
}
