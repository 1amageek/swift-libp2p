// NoiseIdentityVerification.swift
// FAIL-CLOSED libp2p identity verification for the Embedded Noise XX handshake.
// Drives the crypto seam (`SignatureProvider`) to verify the identity signature
// over the Noise static key, dispatching by the libp2p key type. Embedded-clean:
// generic over `C: CryptoProvider`, `[UInt8]` currency, no `any`, typed throws.
//
// The cross-type `do/catch` that folds the seam's `CryptoError` into the node's
// typed error MUST live in named functions (never a closure literal) — Embedded
// Swift rejects a cross-type `catch` inside a closure literal (it binds `any Error`).

import P2PCoreBytes
import P2PCoreCrypto
import LibP2PCore

/// The libp2p identity key types this minimal node admits.
///
/// The varint `keyType` in the `PublicKey` protobuf (libp2p peer-id spec):
/// 0 = RSA, 1 = Ed25519, 2 = Secp256k1, 3 = ECDSA. The minimal node supports
/// Ed25519 and ECDSA P-256; the others are rejected (no silent accept).
enum LibP2PIdentityKeyType: UInt64 {
    case ed25519 = 1
    case ecdsa = 3
}

/// Verifies a Noise handshake payload's libp2p identity, fail-closed.
///
/// Generic over the crypto seam `C` so it specialises at `DefaultCryptoProvider`
/// (host swift-crypto / Embedded BoringSSL). The verified output is the remote's
/// identity public-key bytes (the protobuf-encoded key), from which the PeerID is
/// derived; a verification failure throws, never returns a default.
enum NoiseIdentityVerification<C: CryptoProvider> {

    /// Verifies that `payload` proves ownership of `noiseStaticPublicKey` by the
    /// libp2p identity key it carries.
    ///
    /// Reconstructs the signed message (`"noise-libp2p-static-key:" || staticKey`),
    /// decodes the identity public key, dispatches the signature check by key type,
    /// and returns the protobuf-encoded identity key on success.
    ///
    /// - Throws: ``EmbeddedNodeError/noiseIdentityVerificationFailed`` on a bad
    ///   signature, ``EmbeddedNodeError/noiseUnsupportedIdentityKeyType`` for an
    ///   unsupported key type, ``EmbeddedNodeError/noiseInvalidPayload`` on a
    ///   malformed key.
    static func verify(
        payload: NoisePayloadFields,
        noiseStaticPublicKey: [UInt8]
    ) throws(EmbeddedNodeError) -> [UInt8] {
        // Reconstruct the signed content: prefix bytes || noise static key.
        var signed = [UInt8](NoiseFraming.staticKeySignaturePrefix.utf8)
        signed.append(contentsOf: noiseStaticPublicKey)

        // Decode the libp2p PublicKey protobuf (keyType + raw key bytes).
        let key: PublicKeyProtobuf
        do {
            key = try PublicKeyProtobuf.decode(from: payload.identityKey)
        } catch {
            // `error` binds as `PublicKeyProtobufError`; bare catch (no `as`).
            throw .noiseInvalidPayload
        }

        guard let keyType = LibP2PIdentityKeyType(rawValue: key.keyType) else {
            throw .noiseUnsupportedIdentityKeyType(key.keyType)
        }

        let valid: Bool
        switch keyType {
        case .ed25519:
            valid = verifyEd25519(
                rawPublicKey: key.keyData, signature: payload.identitySig, message: signed
            )
        case .ecdsa:
            valid = verifyECDSAP256(
                rawPublicKey: key.keyData, signature: payload.identitySig, message: signed
            )
        }

        guard valid else {
            throw .noiseIdentityVerificationFailed
        }
        return payload.identityKey
    }

    // MARK: - Named seam helpers (cross-type catch lives here, not in a closure)

    /// Verifies an Ed25519 signature through the crypto seam. Any import/verify
    /// error means the key/signature is unusable → not valid (fail-closed).
    private static func verifyEd25519(
        rawPublicKey: [UInt8], signature: [UInt8], message: [UInt8]
    ) -> Bool {
        let verifyingKey: C.Ed25519.VerifyingKey
        do {
            verifyingKey = try C.Ed25519.verifyingKey(rawRepresentation: rawPublicKey.span)
        } catch {
            return false
        }
        return C.Ed25519.isValid(
            signature: signature.span, for: message.span, with: verifyingKey
        )
    }

    /// Verifies an ECDSA P-256 signature through the crypto seam. libp2p ECDSA keys
    /// are X.509 SubjectPublicKeyInfo / DER-signature encoded; the seam's
    /// `verifyingKey(rawRepresentation:)` / `isValid` accept the provider's native
    /// representation. Any error → not valid (fail-closed).
    private static func verifyECDSAP256(
        rawPublicKey: [UInt8], signature: [UInt8], message: [UInt8]
    ) -> Bool {
        let verifyingKey: C.P256Signature.VerifyingKey
        do {
            verifyingKey = try C.P256Signature.verifyingKey(rawRepresentation: rawPublicKey.span)
        } catch {
            return false
        }
        return C.P256Signature.isValid(
            signature: signature.span, for: message.span, with: verifyingKey
        )
    }
}
