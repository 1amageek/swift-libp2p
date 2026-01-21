/// LibP2PCertificateHelper - Certificate generation and parsing for libp2p TLS
///
/// Handles the libp2p-specific X.509 certificate operations:
/// - Generating self-signed certificates with libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
/// - Encoding SignedKey structures in ASN.1 DER format
/// - Extracting libp2p public keys from peer certificates

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
    /// - Returns: Tuple of (certificate DER, signing key)
    /// - Throws: Error if certificate generation fails
    public static func generateCertificate(
        keyPair: KeyPair
    ) throws -> (certificateDER: Data, signingKey: SigningKey) {

        // 1. Generate ephemeral P-256 key pair for TLS
        let signingKey = SigningKey.generateP256()

        // 2. Get the SPKI (SubjectPublicKeyInfo) for the TLS public key
        let spkiDER = try encodeSPKI(publicKey: signingKey.publicKeyBytes, algorithm: .p256)

        // 3. Create the signature message
        // "libp2p-tls-handshake:" + DER(SubjectPublicKeyInfo)
        let message = Data(signaturePrefix.utf8) + spkiDER

        // 4. Sign with the libp2p private key
        let signature = try keyPair.privateKey.sign(message)

        // 5. Create SignedKey structure
        let signedKeyDER = try encodeSignedKey(
            publicKey: keyPair.publicKey.protobufEncoded,
            signature: signature
        )

        // 6. Build the certificate
        let certificateDER = try buildCertificate(
            signingKey: signingKey,
            libp2pExtension: signedKeyDER
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

    // MARK: - ASN.1 Encoding

    /// Encodes a SignedKey structure to ASN.1 DER format
    ///
    /// SignedKey ::= SEQUENCE {
    ///     publicKey OCTET STRING,
    ///     signature OCTET STRING
    /// }
    public static func encodeSignedKey(
        publicKey: Data,
        signature: Data
    ) throws -> Data {
        let publicKeyOctetString = encodeOctetString(publicKey)
        let signatureOctetString = encodeOctetString(signature)

        var contents = Data()
        contents.append(publicKeyOctetString)
        contents.append(signatureOctetString)

        return encodeSequence(contents)
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

    // MARK: - Private Helpers

    /// Encodes SubjectPublicKeyInfo for P-256 public key
    private static func encodeSPKI(publicKey: Data, algorithm: KeyAlgorithm) throws -> Data {
        // SubjectPublicKeyInfo ::= SEQUENCE {
        //     algorithm AlgorithmIdentifier,
        //     subjectPublicKey BIT STRING
        // }
        //
        // AlgorithmIdentifier ::= SEQUENCE {
        //     algorithm OBJECT IDENTIFIER,
        //     parameters ANY DEFINED BY algorithm OPTIONAL
        // }

        let algorithmIdentifier: Data
        switch algorithm {
        case .p256:
            // ecPublicKey OID: 1.2.840.10045.2.1
            // secp256r1 OID: 1.2.840.10045.3.1.7
            let ecPublicKeyOID = encodeOID([1, 2, 840, 10045, 2, 1])
            let secp256r1OID = encodeOID([1, 2, 840, 10045, 3, 1, 7])
            algorithmIdentifier = encodeSequence(ecPublicKeyOID + secp256r1OID)
        }

        // BIT STRING encoding (0 unused bits + public key bytes)
        var bitString = Data([0x03])  // BIT STRING tag
        let bitStringContent = Data([0x00]) + publicKey  // 0 unused bits
        bitString.append(contentsOf: encodeLength(bitStringContent.count))
        bitString.append(bitStringContent)

        return encodeSequence(algorithmIdentifier + bitString)
    }

    /// Builds a self-signed X.509 certificate
    private static func buildCertificate(
        signingKey: SigningKey,
        libp2pExtension: Data
    ) throws -> Data {
        // This is a minimal X.509 v3 certificate structure
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

        var tbsCertificate = Data()

        // Version: v3 (2)
        let version = encodeExplicitTag(0, content: encodeInteger(2))
        tbsCertificate.append(version)

        // SerialNumber: random
        var serialBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<serialBytes.count {
            serialBytes[i] = UInt8.random(in: 0...255)
        }
        serialBytes[0] &= 0x7F  // Ensure positive
        tbsCertificate.append(encodeInteger(Data(serialBytes)))

        // Signature algorithm: ecdsa-with-SHA256 (1.2.840.10045.4.3.2)
        let signatureAlgorithm = encodeSequence(
            encodeOID([1, 2, 840, 10045, 4, 3, 2])
        )
        tbsCertificate.append(signatureAlgorithm)

        // Issuer: empty (libp2p allows this)
        let emptyName = encodeSequence(Data())
        tbsCertificate.append(emptyName)

        // Validity
        let now = Date()
        let notBefore = now.addingTimeInterval(-3600)  // 1 hour ago
        let notAfter = now.addingTimeInterval(365 * 24 * 3600)  // 1 year
        let validity = encodeSequence(
            encodeUTCTime(notBefore) + encodeUTCTime(notAfter)
        )
        tbsCertificate.append(validity)

        // Subject: empty
        tbsCertificate.append(emptyName)

        // SubjectPublicKeyInfo
        let spki = try encodeSPKI(publicKey: signingKey.publicKeyBytes, algorithm: .p256)
        tbsCertificate.append(spki)

        // Extensions [3]
        let libp2pExtensionFull = encodeExtension(
            oid: extensionOID,
            critical: true,
            value: libp2pExtension
        )
        let extensions = encodeExplicitTag(3, content: encodeSequence(libp2pExtensionFull))
        tbsCertificate.append(extensions)

        // Wrap TBSCertificate in SEQUENCE
        let tbsCertificateSeq = encodeSequence(tbsCertificate)

        // Sign the TBSCertificate
        let signature = try signingKey.sign(tbsCertificateSeq)

        // Certificate ::= SEQUENCE {
        //     tbsCertificate TBSCertificate,
        //     signatureAlgorithm AlgorithmIdentifier,
        //     signatureValue BIT STRING
        // }
        var certificate = tbsCertificateSeq
        certificate.append(signatureAlgorithm)

        // Signature as BIT STRING
        var signatureBitString = Data([0x03])
        let signatureContent = Data([0x00]) + signature
        signatureBitString.append(contentsOf: encodeLength(signatureContent.count))
        signatureBitString.append(signatureContent)
        certificate.append(signatureBitString)

        return encodeSequence(certificate)
    }

    // MARK: - ASN.1 Encoding Primitives

    private enum KeyAlgorithm {
        case p256
    }

    private static func encodeOctetString(_ data: Data) -> Data {
        var result = Data([0x04])  // OCTET STRING tag
        result.append(contentsOf: encodeLength(data.count))
        result.append(data)
        return result
    }

    private static func encodeSequence(_ contents: Data) -> Data {
        var result = Data([0x30])  // SEQUENCE tag
        result.append(contentsOf: encodeLength(contents.count))
        result.append(contents)
        return result
    }

    private static func encodeInteger(_ value: Int) -> Data {
        var result = Data([0x02])  // INTEGER tag
        var bytes = Data()

        if value == 0 {
            bytes.append(0x00)
        } else {
            var v = value
            while v > 0 {
                bytes.insert(UInt8(v & 0xFF), at: 0)
                v >>= 8
            }
            // Ensure positive (add leading zero if high bit set)
            if bytes[0] & 0x80 != 0 {
                bytes.insert(0x00, at: 0)
            }
        }

        result.append(contentsOf: encodeLength(bytes.count))
        result.append(bytes)
        return result
    }

    private static func encodeInteger(_ data: Data) -> Data {
        var result = Data([0x02])  // INTEGER tag
        var bytes = data

        // Ensure positive
        if !bytes.isEmpty && bytes[0] & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }

        result.append(contentsOf: encodeLength(bytes.count))
        result.append(bytes)
        return result
    }

    private static func encodeOID(_ components: [UInt]) -> Data {
        guard components.count >= 2 else {
            return Data([0x06, 0x00])
        }

        var result = Data([0x06])  // OBJECT IDENTIFIER tag
        var content = Data()

        // First byte: first * 40 + second
        content.append(UInt8(components[0] * 40 + components[1]))

        // Remaining components use variable-length encoding
        for i in 2..<components.count {
            let comp = components[i]
            if comp < 128 {
                content.append(UInt8(comp))
            } else {
                var bytes: [UInt8] = []
                var val = comp
                bytes.append(UInt8(val & 0x7F))
                val >>= 7
                while val > 0 {
                    bytes.append(UInt8((val & 0x7F) | 0x80))
                    val >>= 7
                }
                content.append(contentsOf: bytes.reversed())
            }
        }

        result.append(contentsOf: encodeLength(content.count))
        result.append(content)
        return result
    }

    private static func encodeUTCTime(_ date: Date) -> Data {
        var result = Data([0x17])  // UTCTime tag

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"

        let timeString = formatter.string(from: date)
        let content = Data(timeString.utf8)

        result.append(contentsOf: encodeLength(content.count))
        result.append(content)
        return result
    }

    private static func encodeExplicitTag(_ tag: UInt8, content: Data) -> Data {
        var result = Data([0xA0 | tag])  // Context-specific constructed
        result.append(contentsOf: encodeLength(content.count))
        result.append(content)
        return result
    }

    private static func encodeExtension(oid: [UInt], critical: Bool, value: Data) -> Data {
        // Extension ::= SEQUENCE {
        //     extnID OBJECT IDENTIFIER,
        //     critical BOOLEAN DEFAULT FALSE,
        //     extnValue OCTET STRING
        // }
        var content = encodeOID(oid)

        if critical {
            content.append(Data([0x01, 0x01, 0xFF]))  // BOOLEAN TRUE
        }

        content.append(encodeOctetString(value))

        return encodeSequence(content)
    }

    private static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else if length < 65536 {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }
}
