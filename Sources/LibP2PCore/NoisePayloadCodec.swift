/// Noise XX handshake payload protobuf framing (Embedded-clean).
///
/// Embedded-clean: no Foundation, no Crypto, no `any`. This is the
/// `NoiseHandshakePayload` protobuf *framing* over `[UInt8]`:
///
/// ```protobuf
/// message NoiseHandshakePayload {
///   bytes identity_key = 1;
///   bytes identity_sig = 2;
///   bytes data         = 3;
/// }
/// ```
///
/// The Noise crypto (X25519 / ChaCha20-Poly1305 / HKDF, key sign/verify, PeerID
/// derivation) stays in the `P2PSecurityNoise` adapter via the crypto seam; only
/// the byte framing lives here. Builds on the wire-type-2 `ProtobufLite` helpers
/// already in this core.

/// The decoded fields of a Noise XX handshake payload.
public struct NoisePayloadFields: Sendable, Equatable {

    /// The libp2p identity public key (protobuf encoded), field 1.
    public let identityKey: [UInt8]

    /// Signature over the static-key prefix + Noise static public key, field 2.
    public let identitySig: [UInt8]

    /// Optional additional data (usually empty), field 3.
    public let data: [UInt8]

    public init(identityKey: [UInt8], identitySig: [UInt8], data: [UInt8] = []) {
        self.identityKey = identityKey
        self.identitySig = identitySig
        self.data = data
    }

    /// Encodes the payload fields to protobuf format.
    ///
    /// Empty fields are omitted (matching the historical encoder), so a payload
    /// with empty `data` produces no field-3 bytes.
    public func encode() -> [UInt8] {
        var result = [UInt8]()
        if !identityKey.isEmpty {
            result.append(contentsOf: encodeProtobufField(fieldNumber: 1, data: identityKey))
        }
        if !identitySig.isEmpty {
            result.append(contentsOf: encodeProtobufField(fieldNumber: 2, data: identitySig))
        }
        if !data.isEmpty {
            result.append(contentsOf: encodeProtobufField(fieldNumber: 3, data: data))
        }
        return result
    }

    /// Decodes a Noise handshake payload from protobuf format.
    ///
    /// Unknown fields are ignored. Requires both `identity_key` (field 1) and
    /// `identity_sig` (field 2) to be present.
    ///
    /// - Throws: `NoisePayloadCodecError` on malformed or incomplete input.
    public static func decode(from bytes: [UInt8]) throws(NoisePayloadCodecError) -> NoisePayloadFields {
        let fields: [ProtobufField]
        do {
            fields = try decodeProtobufFields(from: bytes)
        } catch {
            throw .invalidPayload
        }

        var identityKey: [UInt8]?
        var identitySig: [UInt8]?
        var payloadData: [UInt8]?

        for field in fields {
            switch field.fieldNumber {
            case 1: identityKey = field.data
            case 2: identitySig = field.data
            case 3: payloadData = field.data
            default: break
            }
        }

        guard let key = identityKey, let sig = identitySig else {
            throw .invalidPayload
        }
        return NoisePayloadFields(
            identityKey: key,
            identitySig: sig,
            data: payloadData ?? []
        )
    }
}

/// Errors from the Noise payload protobuf framing.
public enum NoisePayloadCodecError: Error, Equatable, Sendable {
    case invalidPayload
}
