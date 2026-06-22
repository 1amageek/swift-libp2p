/// `Data`/Crypto compatibility surface for the moved ``Multihash`` type.
///
/// The Embedded-clean core (``LibP2PCore``) owns the multihash *framing*
/// (`init(code:digest:[UInt8])`, `init(bytes:[UInt8])`, `bytes: [UInt8]`,
/// `identity(_:[UInt8])`). This adapter restores the historical `Data`-based
/// inits and the SHA-256 factory, which is the only part that needs Crypto and
/// therefore stays adapter-side (the Crypto seam).

import Foundation
import Crypto
import LibP2PCore

extension Multihash {

    /// Creates a multihash with the specified code and `Data` digest.
    public init(code: HashCode, digest: Data) {
        self.init(code: code, digest: [UInt8](digest))
    }

    /// Decodes a multihash from its binary `Data` representation.
    /// - Throws: `MultihashError` if the data is malformed.
    public init(bytes data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    /// Creates a SHA-256 multihash of the given data (Crypto seam).
    public static func sha256(_ data: Data) -> Multihash {
        let digest = [UInt8](SHA256.hash(data: data))
        return Multihash(code: .sha2_256, digest: digest)
    }

    /// Creates an identity multihash (no hashing, just wraps the data).
    public static func identity(_ data: Data) -> Multihash {
        Multihash(code: .identity, digest: [UInt8](data))
    }
}
