/// LibP2PCertificateHelper - Certificate generation and parsing for libp2p TLS
///
/// Handles the libp2p-specific X.509 certificate operations for the QUIC
/// transport:
/// - Generating self-signed certificates with the libp2p extension
///   (OID 1.3.6.1.4.1.53594.1.1)
/// - Encoding/parsing SignedKey structures in DER
/// - Extracting + verifying the libp2p public key from peer certificates and
///   deriving the authenticated PeerID
///
/// ## Codec: P2PCoreDER (Embedded-clean minimal-DER)
///
/// This mirrors the swift-certificates RPK path (`LibP2PCertificate`, M6b): the
/// libp2p self-signed leaf build/parse/verify goes through `P2PCoreDER` (the
/// Embedded-clean codec, proven byte-identical to swift-certificates by the
/// `P2PCoreDERInteropTests`), with the crypto injected as closures bound to
/// swift-crypto here. swift-quic's `ASN1Builder` / `X509Certificate` are NOT
/// used on this path.
///
/// The ephemeral TLS leaf key is still produced as swift-quic's `SigningKey`
/// (the type `TLSConfiguration.signingKey` consumes for the QUIC handshake);
/// only the DER codec moved to `P2PCoreDER`.

import Foundation
import Crypto
import P2PCore
import P2PCoreDER
import QUICCrypto

/// Helper for libp2p certificate operations on the QUIC transport.
public enum LibP2PCertificateHelper {

    /// The libp2p TLS signature prefix
    public static let signaturePrefix = "libp2p-tls-handshake:"

    /// The libp2p extension OID: 1.3.6.1.4.1.53594.1.1
    public static let extensionOID: [UInt] = [1, 3, 6, 1, 4, 1, 53594, 1, 1]

    // MARK: - Certificate Generation

    /// Generates a self-signed X.509 certificate with libp2p extension
    ///
    /// The generated certificate:
    /// - Uses P-256 for the TLS key (ephemeral)
    /// - Is self-signed
    /// - Contains the libp2p extension with the host's public key and signature
    /// - Is valid for 1 year (by default)
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Parameter validityDays: Certificate validity period in days (default: 365)
    /// - Returns: Tuple of (certificate DER, signing key)
    /// - Throws: `TLSCertificateError` if certificate generation fails
    public static func generateCertificate(
        keyPair: KeyPair,
        validityDays: Int = 365
    ) throws -> (certificateDER: Data, signingKey: SigningKey) {

        // 1. Generate the ephemeral P-256 TLS leaf key. swift-quic's TLS layer
        //    consumes this `SigningKey` directly via `TLSConfiguration.signingKey`.
        let tlsPrivateKey = P256.Signing.PrivateKey()
        let signingKey = SigningKey.p256(tlsPrivateKey)

        // 2. Encode the SPKI for the ephemeral TLS public key via P2PCoreDER.
        //    The uncompressed point (0x04 || X || Y) is the x963 representation.
        let spkiDER: [UInt8]
        do {
            spkiDER = try SubjectPublicKeyInfoDER.encodeP256(
                uncompressedPoint65: [UInt8](tlsPrivateKey.publicKey.x963Representation)
            )
        } catch {
            throw TLSCertificateError.asn1Error(reason: "SPKI encoding failed")
        }

        // 3. Sign "libp2p-tls-handshake:" || SPKI with the libp2p identity key.
        let message = LibP2PIdentity.signatureMessage(spkiDER: spkiDER)
        let signature: Data
        do {
            signature = try keyPair.sign(Data(message))
        } catch {
            throw TLSCertificateError.signatureCreationFailed(underlying: error)
        }

        // 4. Encode the SignedKey extension value via P2PCoreDER.
        let signedKeyExtension = LibP2PSignedKeyDER.encode(
            protobufPubKey: [UInt8](keyPair.publicKey.protobufEncoded),
            signature: [UInt8](signature)
        )

        // 5. Build + self-sign the leaf certificate via P2PCoreDER. The cert
        //    self-signature is P-256 ECDSA-SHA256 over the TBS -> DER ECDSA sig.
        var serial = [UInt8](repeating: 0, count: 16)
        for i in 0..<serial.count {
            serial[i] = UInt8.random(in: 0...255)
        }
        serial[0] &= 0x7F  // Ensure a positive INTEGER.

        let boundedValidityDays = max(1, validityDays)
        let now = Int64(Date().timeIntervalSince1970)
        let notBefore = now - 3600                                  // 1 hour ago
        let notAfter = now + Int64(boundedValidityDays) * 24 * 3600 // validity window

        let certificateBytes: [UInt8]
        do {
            certificateBytes = try LibP2PCertificateDER.buildSelfSignedCert(
                spkiDER: spkiDER,
                signedKeyExtension: signedKeyExtension,
                serial16: serial,
                notBefore: notBefore,
                notAfter: notAfter,
                signFn: { (tbs: [UInt8]) throws(CertSigningError) -> [UInt8] in
                    do {
                        return Array(try tlsPrivateKey.signature(for: Data(tbs)).derRepresentation)
                    } catch {
                        throw CertSigningError.signingFailed
                    }
                }
            )
        } catch {
            throw TLSCertificateError.signatureCreationFailed(underlying: error)
        }

        return (Data(certificateBytes), signingKey)
    }

    // MARK: - Certificate Parsing

    /// Extracts the libp2p public key and signature from a certificate.
    ///
    /// Parses the leaf via P2PCoreDER and returns the raw SignedKey fields. The
    /// libp2p extension MUST be present and the SignedKey MUST be well-formed;
    /// otherwise this throws (fail closed). Signature verification is performed
    /// by ``validatePeerID(from:expectedPeerID:)`` / the caller.
    ///
    /// - Parameter certificateDER: The DER-encoded X.509 certificate
    /// - Returns: Tuple of (protobuf-encoded public key, signature)
    /// - Throws: `TLSCertificateError` if extraction fails
    public static func extractLibP2PPublicKey(
        from certificateDER: Data
    ) throws -> (publicKey: Data, signature: Data) {
        let leaf = try parseLeaf(from: certificateDER)
        guard let extensionValue = leaf.libp2pExtensionValue else {
            throw TLSCertificateError.missingLibp2pExtension
        }
        return try parseSignedKey(from: Data(extensionValue))
    }

    /// Validates a libp2p leaf certificate and returns the authenticated PeerID.
    ///
    /// This is the libp2p peer-authentication boundary for the QUIC transport
    /// and is fail-closed:
    /// 1. Parse the leaf (SPKI verbatim + libp2p extension value) via P2PCoreDER.
    /// 2. Require the libp2p extension to be present.
    /// 3. Parse the SignedKey { publicKey, signature }.
    /// 4. Verify the SignedKey signature over `"libp2p-tls-handshake:" || SPKI`.
    /// 5. Derive the PeerID multihash from the libp2p public key.
    /// 6. Optionally enforce the expected PeerID.
    ///
    /// A missing/structurally-invalid extension, a malformed SignedKey, a bad
    /// signature, an unsupported key type, or a PeerID mismatch all throw — the
    /// handshake is never accepted on a failure.
    ///
    /// - Parameters:
    ///   - certificateDER: The DER-encoded leaf certificate.
    ///   - expectedPeerID: If set, validation fails when the derived PeerID
    ///     does not match.
    /// - Returns: The verified PeerID.
    /// - Throws: `TLSCertificateError` on any validation failure.
    public static func validatePeerID(
        from certificateDER: Data,
        expectedPeerID: PeerID?
    ) throws -> PeerID {
        // 1. Parse the leaf: SPKI (verbatim) + the libp2p extension value.
        let leaf = try parseLeaf(from: certificateDER)

        // 2. The libp2p extension MUST be present (fail closed otherwise).
        guard let extensionValue = leaf.libp2pExtensionValue else {
            throw TLSCertificateError.missingLibp2pExtension
        }

        // 3. Parse the SignedKey { publicKey, signature }.
        let parsed: (protobufPubKey: [UInt8], signature: [UInt8])
        do {
            parsed = try LibP2PSignedKeyDER.parse(extensionValue)
        } catch {
            throw TLSCertificateError.asn1Error(reason: "Invalid SignedKey structure")
        }

        // 4. Verify the SignedKey signature over "libp2p-tls-handshake:" || SPKI.
        //    Crypto is injected as closures bound to swift-crypto. Both verify
        //    closures fail closed: an unconstructable key returns false (the
        //    signature is treated as invalid), and `verifySignedKey` rejects
        //    unsupported key types by throwing.
        let isValid: Bool
        do {
            isValid = try LibP2PIdentity.verifySignedKey(
                protobufPubKey: parsed.protobufPubKey,
                signature: parsed.signature,
                spkiDER: leaf.spkiDER,
                verifyEd25519: Self.verifyEd25519,
                verifyP256DER: Self.verifyP256DER
            )
        } catch {
            // Unknown/unsupported key type or malformed protobuf -> reject.
            throw TLSCertificateError.invalidExtensionSignature
        }
        guard isValid else {
            throw TLSCertificateError.invalidExtensionSignature
        }

        // 5. Derive the PeerID multihash from the libp2p public key. The SHA-256
        //    digest (Crypto seam) is injected; framing lives in P2PCoreDER.
        let multihashBytes: [UInt8]
        do {
            multihashBytes = try LibP2PIdentity.peerIDMultihash(
                protobufPubKey: parsed.protobufPubKey,
                sha256: Self.sha256
            )
        } catch {
            throw TLSCertificateError.invalidPublicKey(reason: "PeerID derivation failed")
        }

        let peerID: PeerID
        do {
            peerID = try PeerID(bytes: Data(multihashBytes))
        } catch {
            throw TLSCertificateError.invalidPublicKey(reason: "Invalid PeerID multihash")
        }

        // 6. Enforce the expected PeerID if provided (fail closed on mismatch).
        if let expected = expectedPeerID {
            guard expected == peerID else {
                throw TLSCertificateError.peerIDMismatch(expected: expected, actual: peerID)
            }
        }

        return peerID
    }

    /// Parses the leaf SPKI + libp2p extension value via P2PCoreDER, mapping any
    /// DER error to a `TLSCertificateError` (fail closed).
    private static func parseLeaf(
        from certificateDER: Data
    ) throws -> LibP2PCertificateDER.LeafView {
        do {
            return try LibP2PCertificateDER.parseLeaf([UInt8](certificateDER))
        } catch {
            throw TLSCertificateError.certificateParsingFailed(reason: "Invalid certificate structure")
        }
    }

    // MARK: - SignedKey Encoding/Parsing

    /// Encodes a SignedKey structure to DER.
    ///
    /// SignedKey ::= SEQUENCE {
    ///     publicKey OCTET STRING,
    ///     signature OCTET STRING
    /// }
    public static func encodeSignedKey(
        publicKey: Data,
        signature: Data
    ) -> Data {
        Data(LibP2PSignedKeyDER.encode(
            protobufPubKey: [UInt8](publicKey),
            signature: [UInt8](signature)
        ))
    }

    /// Parses a SignedKey structure from DER.
    public static func parseSignedKey(from data: Data) throws -> (publicKey: Data, signature: Data) {
        let parsed: (protobufPubKey: [UInt8], signature: [UInt8])
        do {
            parsed = try LibP2PSignedKeyDER.parse([UInt8](data))
        } catch {
            throw TLSCertificateError.asn1Error(reason: "Invalid SignedKey structure")
        }
        return (Data(parsed.protobufPubKey), Data(parsed.signature))
    }

    // MARK: - Injected Crypto (Crypto seam)

    /// Ed25519 raw-signature verification. Returns false on an unconstructable
    /// key (fail closed) rather than throwing into the non-throwing seam.
    private static func verifyEd25519(
        publicKey: [UInt8], signature: [UInt8], message: [UInt8]
    ) -> Bool {
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(publicKey))
        } catch {
            return false
        }
        return key.isValidSignature(Data(signature), for: Data(message))
    }

    /// P-256 ECDSA verification over a DER-encoded signature (libp2p convention).
    /// Returns false on an unconstructable key or undecodable signature.
    private static func verifyP256DER(
        publicKey: [UInt8], signature: [UInt8], message: [UInt8]
    ) -> Bool {
        let key: P256.Signing.PublicKey
        do {
            key = try Self.makeP256PublicKey(from: publicKey)
        } catch {
            return false
        }
        let der: P256.Signing.ECDSASignature
        do {
            der = try P256.Signing.ECDSASignature(derRepresentation: Data(signature))
        } catch {
            return false
        }
        return key.isValidSignature(der, for: Data(message))
    }

    /// Constructs a P-256 public key from the raw bytes carried in the libp2p
    /// protobuf (65-byte uncompressed or 33-byte compressed point).
    private static func makeP256PublicKey(from raw: [UInt8]) throws -> P256.Signing.PublicKey {
        if raw.count == 65 {
            return try P256.Signing.PublicKey(x963Representation: Data(raw))
        }
        return try P256.Signing.PublicKey(compressedRepresentation: Data(raw))
    }

    /// SHA-256 digest (Crypto seam) used by PeerID multihash derivation.
    private static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }
}

/// The typed error thrown by the certificate self-signature closure, keeping
/// `buildSelfSignedCert`'s typed-throws contract (no untyped `throws`).
private enum CertSigningError: Error {
    case signingFailed
}
