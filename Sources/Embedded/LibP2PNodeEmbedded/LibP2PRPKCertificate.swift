// LibP2PRPKCertificate.swift
// The Embedded-clean libp2p raw-public-key (RPK) self-signed certificate for the
// QUIC TLS 1.3 handshake. It mirrors the host `LibP2PCertificateHelper` byte-for-
// byte but binds the crypto to the `C: CryptoProvider` seam (no swift-crypto, no
// Foundation, no swift-certificates): the DER envelope/codec is the Embedded-clean
// `P2PCoreDER` cores (`LibP2PCertificateDER` / `LibP2PSignedKeyDER` /
// `SubjectPublicKeyInfoDER` / `LibP2PIdentity`), with the signing / verification /
// hashing supplied as closures over the seam.
//
// The libp2p QUIC identity model (libp2p TLS spec):
//   * An EPHEMERAL P-256 key is the TLS leaf key. Its SPKI is the cert's
//     subjectPublicKeyInfo; the leaf self-signs the TBS (ECDSA-SHA256), and the
//     TLS CertificateVerify is signed with this same key.
//   * The libp2p IDENTITY key (the node's long-lived Ed25519 key) signs
//     `"libp2p-tls-handshake:" || SPKI(P-256)` — the proof-of-possession carried
//     in the cert's critical libp2p extension (OID 1.3.6.1.4.1.53594.1.1).
//
// Verification is FAIL-CLOSED: a missing/invalid extension, a bad proof-of-
// possession signature, an unsupported identity key type, or a malformed PeerID
// all throw. No unverified peer is ever admitted.

import P2PCoreBytes
import P2PCoreCrypto
import P2PCoreDER

/// A built libp2p RPK certificate: the DER leaf plus the ephemeral P-256 TLS leaf
/// key that signs the handshake (cert TBS + CertificateVerify).
public struct LibP2PRPKCertificate<C: CryptoProvider>: Sendable {

    /// The DER-encoded self-signed leaf certificate (the TLS `cert_data`).
    public let certificateDER: [UInt8]

    /// The ephemeral P-256 TLS leaf signing key (signs the CertificateVerify).
    public let leafSigningKey: C.P256Signature.SigningKey

    /// The ephemeral P-256 TLS leaf signing key bytes (raw scalar), for the
    /// CertificateVerify signer (`TLSSignatureSigner`), which imports from bytes.
    public let leafSigningKeyBytes: [UInt8]
}

/// Builds + verifies the Embedded-clean libp2p RPK certificate over the crypto
/// seam `C`. All members are `static`; the type holds no state.
public enum LibP2PRPKCertificateBuilder<C: CryptoProvider> {

    // MARK: - Build

    /// Builds a self-signed libp2p RPK certificate for `identity`.
    ///
    /// Generates a fresh ephemeral P-256 TLS leaf key, encodes its SPKI, has the
    /// libp2p identity key sign `"libp2p-tls-handshake:" || SPKI`, embeds that as
    /// the critical libp2p extension, and self-signs the TBS with the leaf key.
    ///
    /// - Parameters:
    ///   - identity: The node's libp2p identity (Ed25519 signing key + protobuf
    ///     public key).
    ///   - nowEpochSeconds: The current time as Unix epoch seconds (the validity
    ///     window is `[now - 3600, now + 365 days]`). Sourced from the injected
    ///     clock seam by the caller — there is no `Date` here.
    /// - Throws: ``EmbeddedNodeError/quicHandshakeCertificateFailed`` if any
    ///   crypto/DER step fails (fail-closed — never a malformed cert).
    public static func build(
        identity: EmbeddedNodeIdentity<C>,
        nowEpochSeconds: Int64
    ) throws(EmbeddedNodeError) -> LibP2PRPKCertificate<C> {

        // 1. Ephemeral P-256 TLS leaf key.
        let leafKey: C.P256Signature.SigningKey
        do {
            leafKey = try C.P256Signature.generateSigningKey()
        } catch {
            throw .quicHandshakeCertificateFailed
        }
        let leafKeyBytes = C.P256Signature.rawRepresentation(of: leafKey)
        let leafVerifying = C.P256Signature.verifyingKey(for: leafKey)
        // The verifying-key raw representation is the 65-byte uncompressed point
        // (0x04 || X || Y) — the x963 form the SPKI encoder expects.
        let leafPoint = C.P256Signature.rawRepresentation(of: leafVerifying)

        // 2. Encode the P-256 SubjectPublicKeyInfo.
        let spkiDER: [UInt8]
        do {
            spkiDER = try SubjectPublicKeyInfoDER.encodeP256(uncompressedPoint65: leafPoint)
        } catch {
            throw .quicHandshakeCertificateFailed
        }

        // 3. Identity key signs "libp2p-tls-handshake:" || SPKI.
        let message = LibP2PIdentity.signatureMessage(spkiDER: spkiDER)
        let identitySignature: [UInt8]
        do {
            identitySignature = try identity.signProofOfPossession(message)
        } catch {
            throw .quicHandshakeCertificateFailed
        }

        // 4. SignedKey extension value.
        let signedKeyExtension = LibP2PSignedKeyDER.encode(
            protobufPubKey: identity.protobufPublicKey,
            signature: identitySignature
        )

        // 5. Serial (16 bytes, positive INTEGER) + validity window.
        var serial = C.random.randomBytes(16)
        if serial.count == 16 {
            serial[0] &= 0x7F
        } else {
            // Defensive: the CSPRNG must return the requested count; fail closed.
            throw .quicHandshakeCertificateFailed
        }
        let notBefore = nowEpochSeconds - 3600
        let notAfter = nowEpochSeconds + Int64(365) * 24 * 3600

        // 6. Build + self-sign the leaf (P-256 ECDSA-SHA256 DER over the TBS).
        let certificateDER: [UInt8]
        do {
            certificateDER = try LibP2PCertificateDER.buildSelfSignedCert(
                spkiDER: spkiDER,
                signedKeyExtension: signedKeyExtension,
                serial16: serial,
                notBefore: notBefore,
                notAfter: notAfter,
                signFn: { (tbs: [UInt8]) throws(EmbeddedNodeError) -> [UInt8] in
                    do {
                        return try C.P256Signature.sign(tbs.span, with: leafKey)
                    } catch {
                        throw EmbeddedNodeError.quicHandshakeCertificateFailed
                    }
                }
            )
        } catch {
            // `error` binds as `EmbeddedNodeError` (the signFn's thrown type).
            throw .quicHandshakeCertificateFailed
        }

        return LibP2PRPKCertificate(
            certificateDER: certificateDER,
            leafSigningKey: leafKey,
            leafSigningKeyBytes: leafKeyBytes
        )
    }

    // MARK: - Verify + extract PeerID (fail-closed)

    /// Verifies an inbound libp2p RPK certificate and returns the verified peer.
    ///
    /// Fail-closed pipeline (mirrors the host `validatePeerID`):
    /// 1. Parse the leaf (SPKI verbatim + the libp2p extension value).
    /// 2. Require the libp2p extension to be present.
    /// 3. Parse the SignedKey `{ publicKey, signature }`.
    /// 4. Verify the SignedKey signature over `"libp2p-tls-handshake:" || SPKI`
    ///    with the identity key (Ed25519 raw / ECDSA-P256 DER).
    /// 5. Derive the PeerID multihash from the identity public key.
    ///
    /// A missing/invalid extension, a malformed SignedKey, a bad signature, an
    /// unsupported key type, or a PeerID-derivation failure all throw. The peer
    /// is NEVER admitted on a failure.
    ///
    /// - Returns: the verified PeerID multihash bytes and the leaf SPKI (the
    ///   latter is the P-256 key that signs the TLS CertificateVerify, which the
    ///   handshake driver verifies separately).
    public static func verify(
        certificateDER: [UInt8]
    ) throws(EmbeddedNodeError) -> (peerIDMultihash: [UInt8], leafSPKI: [UInt8]) {

        // 1. Parse the leaf.
        let leaf: LibP2PCertificateDER.LeafView
        do {
            leaf = try LibP2PCertificateDER.parseLeaf(certificateDER)
        } catch {
            throw .quicHandshakePeerVerificationFailed
        }

        // 2. Require the libp2p extension.
        guard let extensionValue = leaf.libp2pExtensionValue else {
            throw .quicHandshakePeerVerificationFailed
        }

        // 3. Parse the SignedKey.
        let parsed: (protobufPubKey: [UInt8], signature: [UInt8])
        do {
            parsed = try LibP2PSignedKeyDER.parse(extensionValue)
        } catch {
            throw .quicHandshakePeerVerificationFailed
        }

        // 4. Verify the proof-of-possession signature.
        let isValid: Bool
        do {
            isValid = try LibP2PIdentity.verifySignedKey(
                protobufPubKey: parsed.protobufPubKey,
                signature: parsed.signature,
                spkiDER: leaf.spkiDER,
                verifyEd25519: { (key, sig, msg) in Self.verifyEd25519(key, sig, msg) },
                verifyP256DER: { (key, sig, msg) in Self.verifyP256DER(key, sig, msg) }
            )
        } catch {
            // Unsupported key type / malformed protobuf — reject.
            throw .quicHandshakePeerVerificationFailed
        }
        guard isValid else {
            throw .quicHandshakePeerVerificationFailed
        }

        // 5. Derive the PeerID multihash.
        let multihash: [UInt8]
        do {
            multihash = try LibP2PIdentity.peerIDMultihash(
                protobufPubKey: parsed.protobufPubKey,
                sha256: { (data) in C.SHA256.hash(data.span) }
            )
        } catch {
            throw .quicHandshakePeerVerificationFailed
        }

        return (multihash, leaf.spkiDER)
    }

    // MARK: - Injected verification crypto (over the seam)

    /// Ed25519 raw-signature verification. Returns `false` on an unconstructable
    /// key (fail-closed) — the signature is then treated as invalid.
    private static func verifyEd25519(
        _ publicKey: [UInt8], _ signature: [UInt8], _ message: [UInt8]
    ) -> Bool {
        let key: C.Ed25519.VerifyingKey
        do {
            key = try C.Ed25519.verifyingKey(rawRepresentation: publicKey.span)
        } catch {
            return false
        }
        return C.Ed25519.isValid(
            signature: signature.span, for: message.span, with: key
        )
    }

    /// P-256 ECDSA verification over a DER-encoded signature (libp2p convention).
    /// The seam's `P256Signature` verifies DER signatures (QUIC path). Returns
    /// `false` on an unconstructable key.
    private static func verifyP256DER(
        _ publicKey: [UInt8], _ signature: [UInt8], _ message: [UInt8]
    ) -> Bool {
        let key: C.P256Signature.VerifyingKey
        do {
            key = try C.P256Signature.verifyingKey(rawRepresentation: publicKey.span)
        } catch {
            return false
        }
        return C.P256Signature.isValid(
            signature: signature.span, for: message.span, with: key
        )
    }
}
