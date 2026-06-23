/// Typed errors for the Embedded-clean Noise crypto state machine.
///
/// Embedded-clean: no Foundation, no `any`. The `P2PSecurityNoise` adapter maps
/// these onto its public `NoiseError` cases so existing callers are unchanged.
///
/// **No silent fallback**: an AEAD tag mismatch is ``decryptionFailed``, an
/// invalid X25519 peer key is ``invalidKey``, and a forged identity signature is
/// ``invalidSignature`` — never an accepted/empty result.
public enum NoiseCryptoError: Error, Equatable, Sendable {

    /// Decryption failed (AEAD tag mismatch or a too-short ciphertext).
    case decryptionFailed

    /// The handshake payload protobuf is malformed.
    case invalidPayload

    /// The identity signature over the static key did not verify (fail-closed).
    case invalidSignature

    /// Invalid X25519 key material (small-order point or a zero shared secret).
    case invalidKey

    /// A handshake message arrived out of order for the current pattern step.
    case messageOutOfOrder

    /// A handshake message was shorter than its pattern requires.
    case messageTooShort

    /// The 64-bit AEAD nonce counter is exhausted — rekey or close the session.
    case nonceOverflow

    /// The crypto backend failed (key construction / AEAD / signature backend).
    case cryptoFailure
}
