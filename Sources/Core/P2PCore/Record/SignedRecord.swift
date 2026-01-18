import Foundation

/// A protocol for records that can be signed and wrapped in an envelope.
public protocol SignedRecord: Sendable {
    /// The domain string for this record type.
    static var domain: String { get }

    /// The codec for this record type (as defined in multicodec).
    static var codec: Data { get }

    /// Serializes the record to bytes.
    func marshal() throws -> Data

    /// Deserializes a record from bytes.
    static func unmarshal(_ data: Data) throws -> Self
}
