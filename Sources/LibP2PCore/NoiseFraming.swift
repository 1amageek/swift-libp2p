/// Noise message length-prefixed framing and constants (Embedded-clean).
///
/// Embedded-clean: no Foundation, no NIO, no `any`. The Noise transport frames
/// every message with a 2-byte big-endian length prefix: `[len_hi][len_lo][payload]`.
/// This namespace owns that framing and the Noise XX wire constants over
/// `[UInt8]`. The `Data` / NIO `ByteBuffer` surface and the crypto live in the
/// `P2PSecurityNoise` adapter.

public enum NoiseFraming {

    // MARK: - Constants

    /// Maximum Noise message size (including the encrypted payload, excluding
    /// the 2-byte length prefix). A 2-byte BE length tops out here.
    public static let maxMessageSize = 65535

    /// ChaCha20-Poly1305 authentication tag size.
    public static let authTagSize = 16

    /// Maximum plaintext size per frame (max message - auth tag).
    public static let maxPlaintextSize = maxMessageSize - authTagSize

    /// X25519 public key size.
    public static let publicKeySize = 32

    /// Noise protocol name for the XX pattern with this cipher suite.
    public static let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"

    /// Prefix signed together with the Noise static public key to bind the
    /// libp2p identity to the Noise session.
    public static let staticKeySignaturePrefix = "noise-libp2p-static-key:"

    // MARK: - Framing

    /// Reads a 2-byte big-endian length-prefixed message from `bytes`.
    ///
    /// - Returns: The message bytes and the total bytes consumed (prefix +
    ///   payload), or `nil` if the buffer does not yet hold a full frame.
    /// - Throws: `NoiseFramingError.frameTooLarge` if the declared length
    ///   exceeds `maxMessageSize`.
    public static func read(
        from bytes: [UInt8]
    ) throws(NoiseFramingError) -> (message: [UInt8], consumed: Int)? {
        guard bytes.count >= 2 else { return nil }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length <= maxMessageSize else {
            throw .frameTooLarge(size: length, max: maxMessageSize)
        }
        guard bytes.count >= 2 + length else { return nil }
        return (Array(bytes[2..<(2 + length)]), 2 + length)
    }

    /// Encodes a message with a 2-byte big-endian length prefix.
    ///
    /// - Throws: `NoiseFramingError.frameTooLarge` if the message exceeds
    ///   `maxMessageSize`.
    public static func encode(_ message: [UInt8]) throws(NoiseFramingError) -> [UInt8] {
        guard message.count <= maxMessageSize else {
            throw .frameTooLarge(size: message.count, max: maxMessageSize)
        }
        var result = [UInt8]()
        result.reserveCapacity(2 + message.count)
        result.append(UInt8((message.count >> 8) & 0xFF))
        result.append(UInt8(message.count & 0xFF))
        result.append(contentsOf: message)
        return result
    }
}

/// Errors from the Noise message framing.
public enum NoiseFramingError: Error, Equatable, Sendable {
    case frameTooLarge(size: Int, max: Int)
}
