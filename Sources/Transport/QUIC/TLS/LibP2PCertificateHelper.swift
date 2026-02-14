/// LibP2PCertificateHelper - Certificate generation and parsing for libp2p TLS
///
/// Handles the libp2p-specific X.509 certificate operations:
/// - Generating self-signed certificates with libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
/// - Encoding SignedKey structures in ASN.1 DER format
/// - Extracting libp2p public keys from peer certificates
///
/// Uses swift-quic's ASN1Builder for DER encoding.

import Foundation
import Crypto
import P2PCore
import QUICCore
import QUICCrypto

/// Helper for libp2p certificate operations using swift-quic's crypto primitives
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
    /// - Is valid for 1 year
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Parameter validityDays: Certificate validity period in days (default: 365)
    /// - Returns: Tuple of (certificate DER, signing key)
    /// - Throws: Error if certificate generation fails
    public static func generateCertificate(
        keyPair: KeyPair,
        validityDays: Int = 365
    ) throws -> (certificateDER: Data, signingKey: SigningKey) {

        // 1. Generate ephemeral P-256 key pair for TLS
        let signingKey = SigningKey.generateP256()

        // 2. Get the SPKI (SubjectPublicKeyInfo) for the TLS public key
        let spkiDER = encodeSPKI(publicKey: signingKey.publicKeyBytes)

        // 3. Create the signature message
        // "libp2p-tls-handshake:" + DER(SubjectPublicKeyInfo)
        let message = Data(signaturePrefix.utf8) + spkiDER

        // 4. Sign with the libp2p private key
        let signature = try keyPair.privateKey.sign(message)

        // 5. Create SignedKey structure
        let signedKeyDER = encodeSignedKey(
            publicKey: keyPair.publicKey.protobufEncoded,
            signature: signature
        )

        // 6. Build the certificate
        let certificateDER = try buildCertificate(
            signingKey: signingKey,
            spkiDER: spkiDER,
            libp2pExtension: signedKeyDER,
            validityDays: validityDays
        )

        return (certificateDER, signingKey)
    }

    // MARK: - Certificate Parsing

    /// Extracts the libp2p public key and signature from a certificate
    ///
    /// - Parameter certificateDER: The DER-encoded X.509 certificate
    /// - Returns: Tuple of (protobuf-encoded public key, signature)
    /// - Throws: Error if extraction fails
    public static func extractLibP2PPublicKey(
        from certificateDER: Data
    ) throws -> (publicKey: Data, signature: Data) {
        // Parse the certificate
        let cert = try X509Certificate.parse(from: certificateDER)

        // Get the libp2p extension value using swift-quic's helper
        guard let extensionValue = cert.libp2pExtensionValue else {
            throw TLSCertificateError.missingLibp2pExtension
        }

        // Parse the SignedKey from the extension value
        return try parseSignedKey(from: extensionValue)
    }

    // MARK: - SignedKey Encoding/Parsing

    /// Encodes a SignedKey structure to ASN.1 DER format
    ///
    /// SignedKey ::= SEQUENCE {
    ///     publicKey OCTET STRING,
    ///     signature OCTET STRING
    /// }
    public static func encodeSignedKey(
        publicKey: Data,
        signature: Data
    ) -> Data {
        ASN1Builder.sequence([
            ASN1Builder.octetString(publicKey),
            ASN1Builder.octetString(signature)
        ])
    }

    /// Parses a SignedKey structure from ASN.1 DER format
    public static func parseSignedKey(from data: Data) throws -> (publicKey: Data, signature: Data) {
        // Parse as ASN.1
        let signedKey = try ASN1Parser.parseOne(from: data)

        guard signedKey.tag.isSequence,
              signedKey.children.count >= 2 else {
            throw TLSCertificateError.asn1Error(reason: "Invalid SignedKey structure")
        }

        let publicKey = try signedKey.children[0].asOctetString()
        let signature = try signedKey.children[1].asOctetString()

        return (publicKey, signature)
    }

    // MARK: - SPKI Encoding

    /// Encodes SubjectPublicKeyInfo for P-256 public key
    private static func encodeSPKI(publicKey: Data) -> Data {
        // SubjectPublicKeyInfo ::= SEQUENCE {
        //     algorithm AlgorithmIdentifier,
        //     subjectPublicKey BIT STRING
        // }
        //
        // AlgorithmIdentifier ::= SEQUENCE {
        //     algorithm OBJECT IDENTIFIER,
        //     parameters ANY DEFINED BY algorithm OPTIONAL
        // }

        // ecPublicKey OID: 1.2.840.10045.2.1
        // secp256r1 OID: 1.2.840.10045.3.1.7
        let algorithmIdentifier = ASN1Builder.sequence([
            ASN1Builder.oid([1, 2, 840, 10045, 2, 1]),
            ASN1Builder.oid([1, 2, 840, 10045, 3, 1, 7])
        ])

        return ASN1Builder.sequence([
            algorithmIdentifier,
            ASN1Builder.bitString(publicKey)
        ])
    }

    // MARK: - Certificate Building

    /// Builds a self-signed X.509 certificate
    ///
    /// - Parameters:
    ///   - signingKey: The key used to sign the certificate
    ///   - spkiDER: The DER-encoded SubjectPublicKeyInfo
    ///   - libp2pExtension: The libp2p extension value
    /// - Returns: The DER-encoded certificate
    /// - Throws: `TLSCertificateError.signatureCreationFailed` if signing fails
    private static func buildCertificate(
        signingKey: SigningKey,
        spkiDER: Data,
        libp2pExtension: Data,
        validityDays: Int
    ) throws -> Data {
        // TBSCertificate ::= SEQUENCE {
        //     version [0] EXPLICIT INTEGER DEFAULT v1,
        //     serialNumber INTEGER,
        //     signature AlgorithmIdentifier,
        //     issuer Name,
        //     validity Validity,
        //     subject Name,
        //     subjectPublicKeyInfo SubjectPublicKeyInfo,
        //     extensions [3] EXPLICIT Extensions OPTIONAL
        // }

        // Version: v3 (2)
        let version = ASN1Builder.contextSpecific(0, content: ASN1Builder.integer(2))

        // SerialNumber: random 16 bytes
        var serialBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<serialBytes.count {
            serialBytes[i] = UInt8.random(in: 0...255)
        }
        serialBytes[0] &= 0x7F  // Ensure positive
        let serialNumber = ASN1Builder.integer(Data(serialBytes))

        // Signature algorithm: ecdsa-with-SHA256 (1.2.840.10045.4.3.2)
        let signatureAlgorithm = ASN1Builder.sequence([
            ASN1Builder.oid([1, 2, 840, 10045, 4, 3, 2])
        ])

        // Issuer: empty (libp2p allows this)
        let emptyName = ASN1Builder.sequence([])

        // Validity
        let now = Date()
        let boundedValidityDays = max(1, validityDays)
        let notBefore = now.addingTimeInterval(-3600)  // 1 hour ago
        let notAfter = now.addingTimeInterval(TimeInterval(boundedValidityDays * 24 * 3600))
        let validity = ASN1Builder.sequence([
            ASN1Builder.utcTime(notBefore),
            ASN1Builder.utcTime(notAfter)
        ])

        // Subject: empty
        let subject = emptyName

        // Extensions [3]
        let libp2pExtensionFull = ASN1Builder.x509Extension(
            oid: extensionOID,
            critical: true,
            value: libp2pExtension
        )
        let extensions = ASN1Builder.contextSpecific(
            3,
            content: ASN1Builder.sequence([libp2pExtensionFull])
        )

        // Build TBSCertificate
        let tbsCertificate = ASN1Builder.sequence([
            version,
            serialNumber,
            signatureAlgorithm,
            emptyName,  // issuer
            validity,
            subject,
            spkiDER,
            extensions
        ])

        // Sign the TBSCertificate
        let signature: Data
        do {
            signature = try signingKey.sign(tbsCertificate)
        } catch {
            throw TLSCertificateError.signatureCreationFailed(underlying: error)
        }

        // Certificate ::= SEQUENCE {
        //     tbsCertificate TBSCertificate,
        //     signatureAlgorithm AlgorithmIdentifier,
        //     signatureValue BIT STRING
        // }
        return ASN1Builder.sequence([
            tbsCertificate,
            signatureAlgorithm,
            ASN1Builder.bitString(signature)
        ])
    }

}
