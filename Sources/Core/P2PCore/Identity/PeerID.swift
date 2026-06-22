/// PeerID implementation conforming to libp2p specification.
/// https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md
///
/// The framing decisions (identity-vs-SHA-256 selection, identity-multihash
/// wrap, textual multibase prefix classification) now live in the Embedded-clean
/// ``LibP2PCore`` (`PeerIDFraming`). This adapter keeps the SHA-256 digest call
/// (the Crypto seam) and the `PublicKey` crypto, delegating framing to the core.

import Foundation
import Crypto
import LibP2PCore

/// A unique identifier for a peer in the libp2p network.
///
/// A PeerID is derived from a public key and encoded as a multihash.
/// For Ed25519 keys (≤42 bytes when protobuf-encoded), the identity
/// multihash is used, embedding the full public key. For larger keys,
/// SHA-256 is used.
public struct PeerID: Sendable, Hashable, CustomStringConvertible {

    /// The multihash representation of this PeerID.
    public let multihash: Multihash

    /// Creates a PeerID from a public key.
    ///
    /// - Parameter publicKey: The public key to derive the PeerID from
    public init(publicKey: PublicKey) {
        let encoded = publicKey.protobufEncoded

        // The identity-vs-SHA-256 selection rule lives in the core; the SHA-256
        // digest (Crypto seam) and the identity wrap come from the core/adapter.
        if PeerIDFraming.usesIdentityEncoding(
            supportsIdentityEncoding: publicKey.keyType.supportsIdentityEncoding,
            encodedLength: encoded.count
        ) {
            self.multihash = PeerIDFraming.identityMultihash(forEncodedKey: [UInt8](encoded))
        } else {
            self.multihash = Multihash.sha256(encoded)
        }
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
    }

    /// Creates a PeerID from raw multihash bytes.
    ///
    /// - Parameter bytes: The raw multihash bytes
    /// - Throws: `MultihashError` if the bytes are invalid
    public init(bytes: Data) throws {
        self.multihash = try Multihash(bytes: bytes)
    }

    /// Creates a PeerID from a Base58- or multibase-encoded string.
    ///
    /// ## Prefix handling
    ///
    /// libp2p PeerID strings come in two forms:
    /// - Legacy base58btc multihash, no multibase prefix. These begin with `Qm`
    ///   (SHA-256 multihash) or `1` (identity multihash) — both are
    ///   unambiguous base58btc length/version markers.
    /// - CIDv1 multibase, with a single-character base prefix: `z` (base58btc),
    ///   `f` (base16/hex), `b` (base32).
    ///
    /// ### The `z` assumption
    ///
    /// A leading `z` is treated as the multibase base58btc prefix and stripped.
    /// This is unambiguous in practice because legacy (prefix-less) PeerIDs only
    /// ever start with `Qm` or `1` (their multihash version/length bytes encode
    /// to those leading characters). A raw base58btc multihash does not begin
    /// with `z`, so stripping is safe. If decoding the stripped remainder fails
    /// to produce a valid multihash, the error is surfaced rather than retried
    /// as a prefix-less string (no silent fallback).
    ///
    /// - Parameter string: The encoded PeerID string
    /// - Throws: `PeerIDError`/`MultihashError` if the string is invalid, or
    ///   `PeerIDError.unsupportedEncoding` for the `f`/`b` multibase prefixes.
    public init(string: String) throws {
        // The multibase prefix classification lives in the core; base58btc
        // decode (Foundation Data surface) stays adapter-side.
        let data: Data
        switch PeerIDFraming.classify(string) {
        case .base58btc:
            data = try Data(base58Encoded: string)
        case .multibaseBase58btc(let payload):
            data = try Data(base58Encoded: payload)
        case .unsupported:
            throw PeerIDError.unsupportedEncoding
        }

        self.multihash = try Multihash(bytes: data)
    }

    /// The raw bytes of this PeerID (multihash bytes).
    public var bytes: Data {
        Data(multihash.bytes)
    }

    /// Extracts the public key if this PeerID uses identity encoding.
    ///
    /// - Returns: The public key, or `nil` if not identity-encoded
    /// - Throws: `PublicKeyError` if decoding fails
    public func extractPublicKey() throws -> PublicKey? {
        guard multihash.code == .identity else {
            return nil
        }
        return try PublicKey(protobufEncoded: Data(multihash.digest))
    }

    /// The Base58btc string representation of this PeerID.
    public var description: String {
        multihash.bytes.base58EncodedString
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
        let encoded = publicKey.protobufEncoded

        switch multihash.code {
        case .identity:
            guard publicKey.keyType.supportsIdentityEncoding, encoded.count <= 42 else {
                return false
            }
            return multihash.digest == encoded

        case .sha2_256:
            return multihash.digest == Data(SHA256.hash(data: encoded))

        default:
            return false
        }
    }

    static func __derived_struct_equals(_ lhs: PeerID, _ rhs: PeerID) -> Bool {
        lhs.multihash == rhs.multihash
    }
}

extension PeerID: Equatable {
    public static func == (lhs: PeerID, rhs: PeerID) -> Bool {
        __derived_struct_equals(lhs, rhs)
    }
}

extension PeerID {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(multihash)
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
