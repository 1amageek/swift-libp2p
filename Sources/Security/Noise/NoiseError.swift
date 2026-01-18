/// NoiseError - Error definitions for Noise protocol
import Foundation
import P2PCore

/// Errors that can occur during Noise protocol operations.
public enum NoiseError: Error, Sendable {
    /// Handshake failed with a descriptive message.
    case handshakeFailed(String)

    /// Decryption of a message failed (invalid ciphertext or auth tag).
    case decryptionFailed

    /// The handshake payload is malformed or invalid.
    case invalidPayload

    /// The signature in the handshake payload is invalid.
    case invalidSignature

    /// The remote peer ID doesn't match the expected peer.
    case peerMismatch(expected: PeerID, actual: PeerID)

    /// A handshake message was received out of order.
    case messageOutOfOrder

    /// The frame exceeds the maximum allowed size.
    case frameTooLarge(size: Int, max: Int)

    /// The connection was closed unexpectedly.
    case connectionClosed

    /// Invalid key material received.
    case invalidKey

    /// Nonce overflow - connection must be rekeyed or closed.
    case nonceOverflow
}

// MARK: - Constants

/// Maximum Noise message size (including length prefix).
let noiseMaxMessageSize = 65535

/// Maximum plaintext size per frame (max message - auth tag).
let noiseMaxPlaintextSize = noiseMaxMessageSize - 16

/// ChaCha20-Poly1305 auth tag size.
let noiseAuthTagSize = 16

/// X25519 public key size.
let noisePublicKeySize = 32

/// Noise protocol name for XX pattern with our cipher suite.
let noiseProtocolName = "Noise_XX_25519_ChaChaPoly_SHA256"

/// Prefix for signing the static key.
let noiseStaticKeySignaturePrefix = "noise-libp2p-static-key:"
