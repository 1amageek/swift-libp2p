/// LibP2PCertificate - Transport-agnostic certificate operations for libp2p
///
/// Generates self-signed certificates with the libp2p extension
/// (OID 1.3.6.1.4.1.53594.1.1) and extracts PeerID from certificates.
///
/// Used by both TLS (P2PSecurityTLS) and WebRTC (P2PTransportWebRTC) transports.
///
/// ## Codec: P2PCoreDER (Embedded-clean minimal-DER)
///
/// The libp2p Raw-Public-Key (RPK) certificate is the minimal self-signed leaf
/// libp2p emits: it carries an ephemeral P-256 key plus a single critical
/// extension binding the host identity key to that leaf. The build/parse/verify
/// of this exact shape goes through `P2PCoreDER` (the Embedded-clean codec,
/// proven byte-identical to swift-certificates by the
/// `P2PCoreDERInteropTests`), with the crypto injected as closures bound to
/// swift-crypto here. swift-certificates is NOT used on this path; it remains
/// available for any full-X.509 path that needs it.

import Foundation
import Crypto
import P2PCore
import P2PCoreDER

/// Transport-agnostic libp2p certificate operations.
///
/// ## Certificate Structure
///
/// The generated certificate contains a critical extension with OID
/// `1.3.6.1.4.1.53594.1.1`. The extension value is a DER-encoded structure:
///
/// ```
/// SignedKey ::= SEQUENCE {
///     publicKey  OCTET STRING,  -- protobuf-encoded libp2p public key
///     signature  OCTET STRING   -- signature over "libp2p-tls-handshake:" + SPKI DER
/// }
/// ```
public enum LibP2PCertificate {

    /// A generated certificate with its DER encoding and private key.
    public struct GeneratedCertificate: Sendable {
        /// DER-encoded certificate containing the libp2p extension.
        public let certificateDER: Data

        /// The ephemeral P-256 private key used to sign the certificate.
        public let privateKey: P256.Signing.PrivateKey
    }

    /// The libp2p TLS signature prefix.
    public static let signaturePrefix = "libp2p-tls-handshake:"

    /// The libp2p extension OID: 1.3.6.1.4.1.53594.1.1
    public static let extensionOID: [UInt64] = [1, 3, 6, 1, 4, 1, 53594, 1, 1]

    // MARK: - Certificate Generation

    /// Generates a self-signed certificate with the libp2p extension.
    ///
    /// The certificate:
    /// - Uses P-256 for the TLS/DTLS key (ephemeral)
    /// - Is self-signed
    /// - Contains the libp2p extension with the host's public key and signature
    /// - Is valid for 1 year
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Returns: Generated certificate with DER encoding and private key
    public static func generate(keyPair: KeyPair) throws -> GeneratedCertificate {
        // 1. Generate ephemeral P-256 key pair for TLS/DTLS.
        let tlsPrivateKey = P256.Signing.PrivateKey()

        // 2. Encode the SPKI for the ephemeral TLS public key via P2PCoreDER.
        //    The uncompressed point (0x04 || X || Y) is the x963 representation.
        let spkiDER: [UInt8]
        do {
            spkiDER = try SubjectPublicKeyInfoDER.encodeP256(
                uncompressedPoint65: [UInt8](tlsPrivateKey.publicKey.x963Representation)
            )
        } catch {
            throw LibP2PCertificateError.encodingFailed
        }

        // 3. Sign "libp2p-tls-handshake:" || SPKI with the libp2p identity key.
        let message = LibP2PIdentity.signatureMessage(spkiDER: spkiDER)
        let signature = try keyPair.sign(Data(message))

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

        let now = Int64(Date().timeIntervalSince1970)
        let notBefore = now - 3600                 // 1 hour ago
        let notAfter = now + 365 * 24 * 3600       // 1 year

        let certificateBytes = try LibP2PCertificateDER.buildSelfSignedCert(
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

        return GeneratedCertificate(
            certificateDER: Data(certificateBytes),
            privateKey: tlsPrivateKey
        )
    }

    // MARK: - PeerID Extraction

    /// Extracts the PeerID from a DER-encoded certificate.
    ///
    /// Parses the libp2p extension, verifies the SignedKey signature over the
    /// certificate's SPKI, and derives the PeerID from the libp2p public key.
    ///
    /// This is the libp2p peer-authentication boundary and is fail-closed: a
    /// missing/structurally-invalid extension, a malformed SignedKey, or a bad
    /// signature throws — the handshake is never accepted on a failure.
    ///
    /// - Parameter certificateDER: The DER-encoded certificate
    /// - Returns: The verified PeerID
    /// - Throws: `LibP2PCertificateError` if the certificate is invalid or
    ///   verification fails
    public static func extractPeerID(from certificateDER: Data) throws -> PeerID {
        // 1. Parse the leaf: SPKI (verbatim) + the libp2p extension value.
        let leaf: LibP2PCertificateDER.LeafView
        do {
            leaf = try LibP2PCertificateDER.parseLeaf([UInt8](certificateDER))
        } catch {
            throw LibP2PCertificateError.invalidStructure
        }

        // 2. The libp2p extension MUST be present (fail closed otherwise).
        guard let extensionValue = leaf.libp2pExtensionValue else {
            throw LibP2PCertificateError.missingExtension
        }

        // 3. Parse the SignedKey { publicKey, signature }.
        let parsed: (protobufPubKey: [UInt8], signature: [UInt8])
        do {
            parsed = try LibP2PSignedKeyDER.parse(extensionValue)
        } catch {
            throw LibP2PCertificateError.invalidStructure
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
            throw LibP2PCertificateError.invalidSignature
        }
        guard isValid else {
            throw LibP2PCertificateError.invalidSignature
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
            throw LibP2PCertificateError.invalidStructure
        }

        do {
            return try PeerID(bytes: Data(multihashBytes))
        } catch {
            throw LibP2PCertificateError.invalidStructure
        }
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
