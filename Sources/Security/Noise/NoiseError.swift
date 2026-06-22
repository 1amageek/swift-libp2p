/// NoiseError - Error definitions for Noise protocol
///
/// The Noise wire constants now live in the Embedded-clean ``LibP2PCore``
/// (`NoiseFraming`); the file-local aliases below forward to them so existing
/// callers in this module are unchanged.
import Foundation
import P2PCore
import LibP2PCore

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

// These forward to the Embedded-clean core (`NoiseFraming`) so the wire
// constants have a single source of truth. The names are kept module-local so
// existing callers in this module compile unchanged.

/// Maximum Noise message size (including length prefix).
let noiseMaxMessageSize = NoiseFraming.maxMessageSize

/// Maximum plaintext size per frame (max message - auth tag).
let noiseMaxPlaintextSize = NoiseFraming.maxPlaintextSize

/// ChaCha20-Poly1305 auth tag size.
let noiseAuthTagSize = NoiseFraming.authTagSize

/// X25519 public key size.
let noisePublicKeySize = NoiseFraming.publicKeySize

/// Noise protocol name for XX pattern with our cipher suite.
let noiseProtocolName = NoiseFraming.protocolName

/// Prefix for signing the static key.
let noiseStaticKeySignaturePrefix = NoiseFraming.staticKeySignaturePrefix
