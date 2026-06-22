/// `Data` compatibility surface for the moved ``Base58`` type.
///
/// The Embedded-clean core (``LibP2PCore``) exposes `Base58.encode(_:[UInt8])`
/// and `Base58.decode(_:) -> [UInt8]`. This adapter restores the historical
/// `Data`-based API (`encode(_:Data)`, `decode(_:) -> Data`) and the `Data`
/// extension used for PeerID string representation.

import Foundation
import LibP2PCore

extension Base58 {

    /// Encodes `Data` as a Base58 string.
    public static func encode(_ data: Data) -> String {
        encode([UInt8](data))
    }

    /// Decodes a Base58 string to `Data`.
    /// - Throws: `Base58Error.invalidCharacter` if the string contains invalid characters.
    public static func decode(_ string: String) throws -> Data {
        Data(try decode(string) as [UInt8])
    }
}

// MARK: - Byte-array Extension

extension Array where Element == UInt8 {

    /// Returns a Base58-encoded string representation of these bytes.
    ///
    /// Convenience mirroring `Data.base58EncodedString` for the `[UInt8]`
    /// fields that the Embedded-clean core now exposes (e.g. `Multihash.bytes`).
    public var base58EncodedString: String {
        Base58.encode(self)
    }
}

// MARK: - Data Extension

extension Data {

    /// Returns a Base58-encoded string representation of this data.
    public var base58EncodedString: String {
        Base58.encode([UInt8](self))
    }

    /// Creates data from a Base58-encoded string.
    ///
    /// - Parameter base58String: The Base58-encoded string.
    /// - Throws: `Base58Error` if the string is invalid.
    public init(base58Encoded base58String: String) throws {
        self = Data(try Base58.decode(base58String) as [UInt8])
    }
}
