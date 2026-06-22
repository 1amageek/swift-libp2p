/// PeerID framing (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md
///
/// Embedded-clean: no Foundation, no Crypto, no `any`. A PeerID is the multihash
/// of the protobuf-encoded public key: an *identity* multihash that embeds the
/// full key for small keys (Ed25519, protobuf form <= 42 bytes), otherwise a
/// SHA-256 multihash. This namespace owns the framing decisions over `[UInt8]`:
/// the identity-vs-SHA-256 selection rule, the identity-multihash wrap, and the
/// textual base58btc/multibase prefix handling. The actual SHA-256 digest is a
/// crypto call that stays in the `P2PCore` adapter via the `HashFunction` seam;
/// the public-key crypto (key types, sign/verify) stays adapter-side too.

public enum PeerIDFraming {

    /// Maximum protobuf-encoded public-key length eligible for identity encoding.
    /// Identity encoding embeds the whole key in the PeerID, so it is only used
    /// for small keys (Ed25519 protobuf form is 36 bytes).
    public static let identityEncodingMaxLength = 42

    /// Whether a protobuf-encoded public key should use an identity multihash.
    ///
    /// - Parameters:
    ///   - supportsIdentityEncoding: Whether the key type permits identity
    ///     encoding (true only for Ed25519 in this project).
    ///   - encodedLength: The byte length of the protobuf-encoded public key.
    /// - Returns: `true` if the identity multihash should be used, `false` if
    ///   SHA-256 should be used instead.
    public static func usesIdentityEncoding(
        supportsIdentityEncoding: Bool, encodedLength: Int
    ) -> Bool {
        supportsIdentityEncoding && encodedLength <= identityEncodingMaxLength
    }

    /// Wraps a protobuf-encoded public key as an identity multihash.
    ///
    /// - Parameter protobufEncodedKey: The protobuf-encoded public key bytes.
    /// - Returns: The identity multihash embedding the key.
    public static func identityMultihash(forEncodedKey protobufEncodedKey: [UInt8]) -> Multihash {
        Multihash.identity(protobufEncodedKey)
    }

    // MARK: - Textual prefix handling

    /// The textual encodings a PeerID string can use.
    public enum TextEncoding: Sendable, Equatable {
        /// Legacy base58btc multihash (no multibase prefix). Begins with `Qm`
        /// (SHA-256) or `1` (identity).
        case base58btc
        /// Multibase base58btc — the leading `z` prefix is stripped; the
        /// associated value is the remainder to decode.
        case multibaseBase58btc(String)
        /// Multibase hex (`f`) or base32 (`b`) — not supported by this project.
        case unsupported
    }

    /// Classifies a PeerID string by its (multibase) prefix and returns the
    /// base58btc payload to decode.
    ///
    /// A leading `z` is the multibase base58btc prefix and is stripped. This is
    /// unambiguous because legacy (prefix-less) PeerIDs only ever start with
    /// `Qm` or `1`; a raw base58btc multihash never begins with `z`. `f`/`b`
    /// (hex/base32 multibase) are reported as unsupported. No silent fallback:
    /// if the resulting payload fails to decode, the caller surfaces the error.
    ///
    /// - Parameter string: The encoded PeerID string.
    /// - Returns: The classified encoding and the base58btc payload to decode
    ///   (for the supported cases).
    public static func classify(_ string: String) -> TextEncoding {
        if string.hasPrefix("Qm") || string.hasPrefix("1") {
            return .base58btc
        } else if string.hasPrefix("z") {
            return .multibaseBase58btc(String(string.dropFirst()))
        } else if string.hasPrefix("f") || string.hasPrefix("b") {
            return .unsupported
        } else {
            // Plain base58btc.
            return .base58btc
        }
    }
}
