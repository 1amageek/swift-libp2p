/// TLSCertificate - Certificate generation and parsing for libp2p TLS
///
/// Generates self-signed X.509 certificates with libp2p extension.
/// Uses Apple's Security framework for cryptographic operations.
import Foundation
import Crypto
import P2PCore

/// Helper for libp2p TLS certificate operations.
public enum TLSCertificate {

    /// The libp2p TLS signature prefix.
    public static let signaturePrefix = "libp2p-tls-handshake:"

    /// The libp2p extension OID: 1.3.6.1.4.1.53594.1.1
    public static let extensionOID: [UInt] = [1, 3, 6, 1, 4, 1, 53594, 1, 1]

    // MARK: - Certificate Generation

    /// Generated certificate and key.
    public struct CertificateResult: Sendable {
        /// The DER-encoded X.509 certificate.
        public let certificateDER: Data
        /// The ephemeral P-256 private key.
        public let privateKey: P256.Signing.PrivateKey
    }

    /// Generates a self-signed X.509 certificate with libp2p extension.
    ///
    /// The certificate:
    /// - Uses P-256 for the TLS key (ephemeral)
    /// - Is self-signed
    /// - Contains the libp2p extension with the host's public key and signature
    /// - Is valid for 1 year
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Returns: Certificate result with DER and signing key
    public static func generate(keyPair: KeyPair) throws -> CertificateResult {
        // 1. Generate ephemeral P-256 key pair for TLS
        let tlsPrivateKey = P256.Signing.PrivateKey()

        // 2. Get the SPKI (SubjectPublicKeyInfo) for the TLS public key
        let spkiDER = encodeSPKI(publicKey: tlsPrivateKey.publicKey)

        // 3. Create the signature message
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
            privateKey: tlsPrivateKey,
            spkiDER: spkiDER,
            libp2pExtension: signedKeyDER
        )

        return CertificateResult(
            certificateDER: certificateDER,
            privateKey: tlsPrivateKey
        )
    }

    // MARK: - Certificate Parsing

    /// Extracted libp2p identity from certificate.
    public struct ExtractedIdentity: Sendable {
        /// The libp2p public key (protobuf encoded).
        public let publicKey: Data
        /// The signature.
        public let signature: Data
    }

    /// Extracts the libp2p public key and signature from a certificate.
    ///
    /// - Parameter certificateDER: The DER-encoded X.509 certificate
    /// - Returns: Extracted identity
    public static func extractIdentity(from certificateDER: Data) throws -> ExtractedIdentity {
        // Parse the certificate and find libp2p extension
        guard let (publicKey, signature) = parseLibP2PExtension(from: certificateDER) else {
            throw TLSError.missingLibP2PExtension
        }

        return ExtractedIdentity(publicKey: publicKey, signature: signature)
    }

    /// Verifies the certificate signature and returns the PeerID.
    ///
    /// - Parameters:
    ///   - certificateDER: The DER-encoded certificate
    ///   - spkiDER: The SPKI from the TLS handshake
    /// - Returns: The verified PeerID
    public static func verifyAndExtractPeerID(
        from certificateDER: Data,
        spkiDER: Data
    ) throws -> PeerID {
        let identity = try extractIdentity(from: certificateDER)

        // Reconstruct the signature message
        let message = Data(signaturePrefix.utf8) + spkiDER

        // Decode the libp2p public key
        let publicKey = try PublicKey(protobufEncoded: identity.publicKey)

        // Verify the signature
        guard try publicKey.verify(signature: identity.signature, for: message) else {
            throw TLSError.invalidCertificateSignature
        }

        return publicKey.peerID
    }

    // MARK: - ASN.1 Encoding Helpers

    /// Encodes SubjectPublicKeyInfo for P-256 public key.
    private static func encodeSPKI(publicKey: P256.Signing.PublicKey) -> Data {
        // AlgorithmIdentifier for ecPublicKey with secp256r1
        let algorithmIdentifier = encodeSequence([
            encodeOID([1, 2, 840, 10045, 2, 1]),  // ecPublicKey
            encodeOID([1, 2, 840, 10045, 3, 1, 7])  // secp256r1
        ])

        // Get raw public key bytes (65 bytes for uncompressed P-256)
        let publicKeyBytes = publicKey.x963Representation

        return encodeSequence([
            algorithmIdentifier,
            encodeBitString(publicKeyBytes)
        ])
    }

    /// Encodes a SignedKey structure.
    private static func encodeSignedKey(publicKey: Data, signature: Data) -> Data {
        encodeSequence([
            encodeOctetString(publicKey),
            encodeOctetString(signature)
        ])
    }

    /// Builds a self-signed X.509 certificate.
    private static func buildCertificate(
        privateKey: P256.Signing.PrivateKey,
        spkiDER: Data,
        libp2pExtension: Data
    ) throws -> Data {
        // Version: v3 (2)
        let version = encodeContextSpecific(0, content: encodeInteger(Data([2])))

        // SerialNumber: random 16 bytes
        var serialBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<serialBytes.count {
            serialBytes[i] = UInt8.random(in: 0...255)
        }
        serialBytes[0] &= 0x7F  // Ensure positive
        let serialNumber = encodeInteger(Data(serialBytes))

        // Signature algorithm: ecdsa-with-SHA256
        let signatureAlgorithm = encodeSequence([
            encodeOID([1, 2, 840, 10045, 4, 3, 2])
        ])

        // Issuer: empty
        let issuer = encodeSequence([])

        // Validity
        let now = Date()
        let notBefore = now.addingTimeInterval(-3600)
        let notAfter = now.addingTimeInterval(365 * 24 * 3600)
        let validity = encodeSequence([
            encodeUTCTime(notBefore),
            encodeUTCTime(notAfter)
        ])

        // Subject: empty
        let subject = encodeSequence([])

        // Extension
        let libp2pExt = encodeSequence([
            encodeOID(extensionOID),
            encodeBoolean(true),  // critical
            encodeOctetString(libp2pExtension)
        ])
        let extensions = encodeContextSpecific(3, content: encodeSequence([libp2pExt]))

        // TBSCertificate
        let tbsCertificate = encodeSequence([
            version,
            serialNumber,
            signatureAlgorithm,
            issuer,
            validity,
            subject,
            spkiDER,
            extensions
        ])

        // Sign the TBSCertificate
        let signature = try privateKey.signature(for: SHA256.hash(data: tbsCertificate))
        let signatureBytes = signature.derRepresentation

        // Certificate
        return encodeSequence([
            tbsCertificate,
            signatureAlgorithm,
            encodeBitString(signatureBytes)
        ])
    }

    // MARK: - ASN.1 Primitive Encoding

    private static func encodeLength(_ length: Int) -> Data {
        if length < 128 {
            return Data([UInt8(length)])
        } else if length < 256 {
            return Data([0x81, UInt8(length)])
        } else if length < 65536 {
            return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        } else {
            return Data([0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])
        }
    }

    private static func encodeSequence(_ contents: [Data]) -> Data {
        let content = contents.reduce(Data(), +)
        return Data([0x30]) + encodeLength(content.count) + content
    }

    private static func encodeOID(_ oid: [UInt]) -> Data {
        guard oid.count >= 2 else { return Data() }
        var bytes = [UInt8(oid[0] * 40 + oid[1])]
        for i in 2..<oid.count {
            var value = oid[i]
            if value < 128 {
                bytes.append(UInt8(value))
            } else {
                var temp: [UInt8] = []
                temp.append(UInt8(value & 0x7F))
                value >>= 7
                while value > 0 {
                    temp.append(UInt8((value & 0x7F) | 0x80))
                    value >>= 7
                }
                bytes.append(contentsOf: temp.reversed())
            }
        }
        return Data([0x06]) + encodeLength(bytes.count) + Data(bytes)
    }

    private static func encodeInteger(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        // Add leading zero if high bit is set
        if !bytes.isEmpty && bytes[0] >= 0x80 {
            bytes.insert(0, at: 0)
        }
        return Data([0x02]) + encodeLength(bytes.count) + Data(bytes)
    }

    private static func encodeOctetString(_ data: Data) -> Data {
        Data([0x04]) + encodeLength(data.count) + data
    }

    private static func encodeBitString(_ data: Data) -> Data {
        // Add leading 0 for unused bits
        Data([0x03]) + encodeLength(data.count + 1) + Data([0x00]) + data
    }

    private static func encodeBoolean(_ value: Bool) -> Data {
        Data([0x01, 0x01, value ? 0xFF : 0x00])
    }

    private static func encodeUTCTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let str = formatter.string(from: date)
        let bytes = [UInt8](str.utf8)
        return Data([0x17]) + encodeLength(bytes.count) + Data(bytes)
    }

    private static func encodeContextSpecific(_ tag: UInt8, content: Data) -> Data {
        Data([0xA0 | tag]) + encodeLength(content.count) + content
    }

    // MARK: - ASN.1 Parsing

    private static func parseLibP2PExtension(from certificateDER: Data) -> (publicKey: Data, signature: Data)? {
        // Simple ASN.1 parsing to find libp2p extension
        // This is a minimal parser - in production, use a full ASN.1 library

        // Encode the OID we're searching for
        let oidContent = encodeOID(extensionOID)

        // Search for the OID (skip the tag and length, just look for content)
        // The content after the OID tag (0x06) and length byte
        let oidContentBytes = Array(oidContent.dropFirst(2))  // Skip tag + length
        let oidData = Data(oidContentBytes)

        guard let oidRange = certificateDER.range(of: oidData) else {
            return nil
        }

        // Find the extension value after the OID
        var offset = oidRange.upperBound

        // Skip boolean (critical flag) if present
        if offset < certificateDER.count && certificateDER[offset] == 0x01 {
            offset += 3  // boolean is always 3 bytes
        }

        // Next should be OCTET STRING containing SignedKey
        guard offset < certificateDER.count && certificateDER[offset] == 0x04 else {
            return nil
        }
        offset += 1

        // Parse length
        guard let (_, outerLengthSize) = parseASN1Length(from: certificateDER, at: offset) else {
            return nil
        }
        offset += outerLengthSize

        // Parse SignedKey SEQUENCE
        guard offset < certificateDER.count && certificateDER[offset] == 0x30 else {
            return nil
        }
        offset += 1

        guard let (_, seqLengthSize) = parseASN1Length(from: certificateDER, at: offset) else {
            return nil
        }
        offset += seqLengthSize

        // First OCTET STRING: publicKey
        guard offset < certificateDER.count && certificateDER[offset] == 0x04 else {
            return nil
        }
        offset += 1

        guard let (pkLength, pkLengthSize) = parseASN1Length(from: certificateDER, at: offset) else {
            return nil
        }
        offset += pkLengthSize

        let publicKey = Data(certificateDER[offset..<offset + pkLength])
        offset += pkLength

        // Second OCTET STRING: signature
        guard offset < certificateDER.count && certificateDER[offset] == 0x04 else {
            return nil
        }
        offset += 1

        guard let (sigLength, sigLengthSize) = parseASN1Length(from: certificateDER, at: offset) else {
            return nil
        }
        offset += sigLengthSize

        let signature = Data(certificateDER[offset..<offset + sigLength])

        return (publicKey, signature)
    }

    private static func parseASN1Length(from data: Data, at offset: Int) -> (length: Int, size: Int)? {
        guard offset < data.count else { return nil }

        let firstByte = data[offset]
        if firstByte < 128 {
            return (Int(firstByte), 1)
        }

        let numBytes = Int(firstByte & 0x7F)
        guard offset + numBytes < data.count else { return nil }

        var length = 0
        for i in 0..<numBytes {
            length = (length << 8) | Int(data[offset + 1 + i])
        }
        return (length, numBytes + 1)
    }
}
