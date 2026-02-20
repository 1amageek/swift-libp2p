/// PeerID implementation conforming to libp2p specification.
/// https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md

import Foundation
import Crypto

/// A unique identifier for a peer in the libp2p network.
///
/// A PeerID is derived from a public key and encoded as a multihash.
/// For Ed25519 keys (≤42 bytes when protobuf-encoded), the identity
/// multihash is used, embedding the full public key. For larger keys,
/// SHA-256 is used.
public struct PeerID: Sendable, Hashable, CustomStringConvertible {

    /// The multihash representation of this PeerID.
    public let multihash: Multihash

    /// Cached Base58 string representation. Pre-computed to avoid
    /// repeated O(n²) Base58 encoding on every `description` access.
    private let _description: String

    /// Creates a PeerID from a public key.
    ///
    /// - Parameter publicKey: The public key to derive the PeerID from
    public init(publicKey: PublicKey) {
        let encoded = publicKey.protobufEncoded

        // Use identity multihash for small keys (Ed25519)
        // Otherwise use SHA-256
        if publicKey.keyType.supportsIdentityEncoding && encoded.count <= 42 {
            self.multihash = Multihash.identity(encoded)
        } else {
            self.multihash = Multihash.sha256(encoded)
        }
        self._description = multihash.bytes.base58EncodedString
    }

    /// Creates a PeerID from a key pair.
    ///
    /// - Parameter keyPair: The key pair to derive the PeerID from
    public init(keyPair: KeyPair) {
        self.init(publicKey: keyPair.publicKey)
    }

    /// Creates a PeerID from its multihash representation.
    ///
    /// - Parameter multihash: The multihash
    public init(multihash: Multihash) {
        self.multihash = multihash
        self._description = multihash.bytes.base58EncodedString
    }

    /// Creates a PeerID from raw multihash bytes.
    ///
    /// - Parameter bytes: The raw multihash bytes
    /// - Throws: `MultihashError` if the bytes are invalid
    public init(bytes: Data) throws {
        self.multihash = try Multihash(bytes: bytes)
        self._description = multihash.bytes.base58EncodedString
    }

    /// Creates a PeerID from a Base58-encoded string.
    ///
    /// - Parameter string: The Base58-encoded PeerID string
    /// - Throws: `PeerIDError` if the string is invalid
    public init(string: String) throws {
        // Handle CIDv1 multibase prefix if present
        let data: Data
        if string.hasPrefix("1") || string.hasPrefix("Qm") {
            // Legacy Base58btc encoded (no multibase prefix)
            data = try Data(base58Encoded: string)
        } else if string.hasPrefix("z") {
            // Multibase Base58btc prefix
            let base58Part = String(string.dropFirst())
            data = try Data(base58Encoded: base58Part)
        } else if string.hasPrefix("f") || string.hasPrefix("b") {
            // Multibase hex or base32 - not yet supported
            throw PeerIDError.unsupportedEncoding
        } else {
            // Try as plain Base58
            data = try Data(base58Encoded: string)
        }

        self.multihash = try Multihash(bytes: data)
        self._description = multihash.bytes.base58EncodedString
    }

    /// The raw bytes of this PeerID (multihash bytes).
    public var bytes: Data {
        multihash.bytes
    }

    /// Extracts the public key if this PeerID uses identity encoding.
    ///
    /// - Returns: The public key, or `nil` if not identity-encoded
    /// - Throws: `PublicKeyError` if decoding fails
    public func extractPublicKey() throws -> PublicKey? {
        guard multihash.code == .identity else {
            return nil
        }
        return try PublicKey(protobufEncoded: multihash.digest)
    }

    /// The Base58btc string representation of this PeerID.
    public var description: String {
        _description
    }

    /// A short representation for logging (last 8 characters).
    public var shortDescription: String {
        let full = description
        if full.count > 8 {
            return String(full.suffix(8))
        }
        return full
    }

    /// Validates that this PeerID matches the given public key.
    ///
    /// - Parameter publicKey: The public key to validate against
    /// - Returns: `true` if the PeerID matches the public key
    public func matches(publicKey: PublicKey) -> Bool {
        let derived = PeerID(publicKey: publicKey)
        return self == derived
    }
}

public enum PeerIDError: Error, Equatable {
    case invalidMultihash
    case unsupportedEncoding
    case publicKeyMismatch
}

// MARK: - Codable

extension PeerID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        try self.init(string: string)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Comparable

extension PeerID: Comparable {
    public static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

// MARK: - ExpressibleByStringLiteral

extension PeerID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        do {
            try self.init(string: value)
        } catch {
            fatalError("Invalid PeerID string literal: \(value)")
        }
    }
}
