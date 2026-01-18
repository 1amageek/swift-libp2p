/// Supported cryptographic key types for libp2p.
/// https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md

import Foundation

/// The type of cryptographic key.
public enum KeyType: UInt64, Sendable, CaseIterable {
    /// RSA keys (not recommended for new implementations)
    case rsa = 0

    /// Ed25519 keys (recommended)
    case ed25519 = 1

    /// Secp256k1 keys (used by Bitcoin/Ethereum)
    case secp256k1 = 2

    /// ECDSA keys
    case ecdsa = 3

    /// The protobuf field number for this key type.
    public var protobufFieldNumber: Int {
        switch self {
        case .rsa: return 0
        case .ed25519: return 1
        case .secp256k1: return 2
        case .ecdsa: return 3
        }
    }

    /// Whether this key type supports identity multihash encoding.
    ///
    /// Identity encoding embeds the full public key in the PeerID,
    /// which is only feasible for small keys like Ed25519.
    public var supportsIdentityEncoding: Bool {
        switch self {
        case .ed25519:
            return true
        case .rsa, .secp256k1, .ecdsa:
            return false
        }
    }

    /// The typical raw public key size in bytes.
    public var publicKeySize: Int {
        switch self {
        case .rsa:
            return 0 // Variable
        case .ed25519:
            return 32
        case .secp256k1:
            return 33 // Compressed
        case .ecdsa:
            return 33 // Compressed P-256
        }
    }
}
