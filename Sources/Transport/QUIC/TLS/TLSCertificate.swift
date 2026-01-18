/// libp2p TLS certificate generation and parsing.
///
/// Implements the libp2p TLS specification for QUIC:
/// https://github.com/libp2p/specs/blob/master/tls/tls.md

import Foundation
import Crypto
import SwiftASN1
import X509
import P2PCore

/// Handles libp2p-specific X.509 certificate operations.
///
/// This struct provides methods for:
/// - Generating self-signed certificates with the libp2p extension
/// - Parsing certificates to extract the libp2p public key
/// - Verifying the libp2p extension signature
///
/// ## Wire Protocol
///
/// The libp2p TLS specification requires:
/// 1. Generate an ephemeral TLS key pair (P-256 recommended)
/// 2. Create a self-signed X.509 certificate
/// 3. Add the libp2p extension (OID 1.3.6.1.4.1.53594.1.1) containing:
///    - The protobuf-encoded libp2p public key
///    - A signature binding the TLS key to the libp2p identity
///
/// ## Example
///
/// ```swift
/// // Generate a certificate
/// let keyPair = KeyPair.generateEd25519()
/// let cert = try TLSCertificate.generate(hostKeyPair: keyPair)
///
/// // Parse a received certificate
/// let parsed = try TLSCertificate.parse(derData)
/// let remotePeerID = parsed.peerID
/// ```
@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
public struct TLSCertificate: Sendable {

    /// The ALPN protocol identifier for libp2p.
    public static let alpnProtocol = "libp2p"

    /// The DER-encoded X.509 certificate.
    public let certificateDER: Data

    /// The swift-certificates Certificate object.
    public let certificate: Certificate

    /// The TLS private key (P-256) used for the certificate.
    ///
    /// This is only available for generated certificates, not parsed ones.
    public let tlsPrivateKey: P256.Signing.PrivateKey?

    /// The libp2p public key extracted from the certificate extension.
    public let libp2pPublicKey: P2PCore.PublicKey

    /// The PeerID derived from the libp2p public key.
    public var peerID: PeerID {
        libp2pPublicKey.peerID
    }

    // MARK: - Private Init

    private init(
        certificateDER: Data,
        certificate: Certificate,
        tlsPrivateKey: P256.Signing.PrivateKey?,
        libp2pPublicKey: P2PCore.PublicKey
    ) {
        self.certificateDER = certificateDER
        self.certificate = certificate
        self.tlsPrivateKey = tlsPrivateKey
        self.libp2pPublicKey = libp2pPublicKey
    }

    // MARK: - Certificate Generation

    /// Generates a self-signed X.509 certificate with the libp2p extension.
    ///
    /// The generated certificate:
    /// - Uses P-256 for the TLS key (ephemeral)
    /// - Is self-signed
    /// - Contains the libp2p extension with the host's public key and signature
    /// - Is valid for 1 year (with 1 hour clock skew tolerance)
    ///
    /// - Parameter hostKeyPair: The libp2p identity key pair
    /// - Returns: A certificate ready for TLS use
    /// - Throws: `TLSCertificateError` if generation fails
    public static func generate(hostKeyPair: KeyPair) throws -> TLSCertificate {
        // 1. Generate ephemeral P-256 key pair for TLS
        let tlsPrivateKey = P256.Signing.PrivateKey()
        let tlsPublicKey = tlsPrivateKey.publicKey

        // 2. Create the libp2p extension
        let signedKey = try createSignedKey(
            tlsPublicKey: tlsPublicKey,
            hostKeyPair: hostKeyPair
        )

        // 3. Serialize SignedKey to DER
        var signedKeySerializer = DER.Serializer()
        try signedKeySerializer.serialize(signedKey)
        let signedKeyDER = Data(signedKeySerializer.serializedBytes)

        // 4. Create the libp2p extension
        let libp2pExtension = Certificate.Extension(
            oid: libp2pExtensionOID,
            critical: true,
            value: ArraySlice(signedKeyDER)
        )

        // 5. Build the certificate
        let now = Date()
        let notValidBefore = now.addingTimeInterval(-3600)  // 1 hour ago (clock skew)
        let notValidAfter = now.addingTimeInterval(365 * 24 * 3600)  // 1 year

        // Use random serial number
        var serialBytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<serialBytes.count {
            serialBytes[i] = UInt8.random(in: 0...255)
        }
        // Ensure positive (clear high bit)
        serialBytes[0] &= 0x7F
        let serialNumber = Certificate.SerialNumber(bytes: ArraySlice(serialBytes))

        // Empty distinguished name (libp2p spec allows this)
        let emptyDN = DistinguishedName()

        // Build extensions
        let extensions = try Certificate.Extensions([libp2pExtension])

        // Create certificate
        let certificate = try Certificate(
            version: .v3,
            serialNumber: serialNumber,
            publicKey: Certificate.PublicKey(tlsPublicKey),
            notValidBefore: notValidBefore,
            notValidAfter: notValidAfter,
            issuer: emptyDN,
            subject: emptyDN,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(tlsPrivateKey)
        )

        // 6. Serialize certificate to DER
        var certSerializer = DER.Serializer()
        try certSerializer.serialize(certificate)
        let certificateDER = Data(certSerializer.serializedBytes)

        return TLSCertificate(
            certificateDER: certificateDER,
            certificate: certificate,
            tlsPrivateKey: tlsPrivateKey,
            libp2pPublicKey: hostKeyPair.publicKey
        )
    }

    // MARK: - Certificate Parsing

    /// Parses a certificate and extracts the libp2p public key.
    ///
    /// - Parameter derData: DER-encoded X.509 certificate
    /// - Returns: The parsed certificate with extracted libp2p info
    /// - Throws: `TLSCertificateError` if parsing or verification fails
    public static func parse(_ derData: Data) throws -> TLSCertificate {
        // 1. Parse the certificate
        let certificate: Certificate
        do {
            certificate = try Certificate(derEncoded: Array(derData))
        } catch {
            throw TLSCertificateError.certificateParsingFailed(reason: "Invalid DER encoding: \(error)")
        }

        // 2. Verify validity period
        let now = Date()
        if now < certificate.notValidBefore {
            throw TLSCertificateError.certificateNotYetValid
        }
        if now > certificate.notValidAfter {
            throw TLSCertificateError.certificateExpired
        }

        // 3. Find the libp2p extension
        guard let libp2pExt = certificate.extensions.first(where: { $0.oid == libp2pExtensionOID }) else {
            throw TLSCertificateError.missingLibp2pExtension
        }

        // 4. Parse SignedKey from extension value
        let signedKey: SignedKey
        do {
            signedKey = try SignedKey(derEncoded: Array(libp2pExt.value))
        } catch {
            throw TLSCertificateError.asn1Error(reason: "Failed to parse SignedKey: \(error)")
        }

        // 5. Decode the libp2p public key from protobuf
        let libp2pPublicKey: P2PCore.PublicKey
        do {
            libp2pPublicKey = try P2PCore.PublicKey(protobufEncoded: signedKey.publicKeyData)
        } catch {
            throw TLSCertificateError.invalidPublicKey(reason: "Failed to decode protobuf: \(error)")
        }

        // 6. Verify the signature
        let isValid = try verifySignedKey(
            signedKey: signedKey,
            certificatePublicKey: certificate.publicKey,
            libp2pPublicKey: libp2pPublicKey
        )
        guard isValid else {
            throw TLSCertificateError.invalidExtensionSignature
        }

        return TLSCertificate(
            certificateDER: derData,
            certificate: certificate,
            tlsPrivateKey: nil,
            libp2pPublicKey: libp2pPublicKey
        )
    }

    /// Verifies the libp2p extension signature.
    ///
    /// - Returns: `true` if the signature is valid
    public func verify() throws -> Bool {
        // Find the libp2p extension
        guard let libp2pExt = certificate.extensions.first(where: { $0.oid == libp2pExtensionOID }) else {
            return false
        }

        // Parse SignedKey
        let signedKey = try SignedKey(derEncoded: Array(libp2pExt.value))

        return try Self.verifySignedKey(
            signedKey: signedKey,
            certificatePublicKey: certificate.publicKey,
            libp2pPublicKey: libp2pPublicKey
        )
    }

    // MARK: - Private Helpers

    /// Creates the SignedKey structure for the libp2p extension.
    private static func createSignedKey(
        tlsPublicKey: P256.Signing.PublicKey,
        hostKeyPair: KeyPair
    ) throws -> SignedKey {
        // 1. Get the DER-encoded SubjectPublicKeyInfo
        let certPublicKey = Certificate.PublicKey(tlsPublicKey)
        var spkiSerializer = DER.Serializer()
        try spkiSerializer.serialize(certPublicKey)
        let spkiDER = Data(spkiSerializer.serializedBytes)

        // 2. Create the message to sign
        // "libp2p-tls-handshake:" + DER(SubjectPublicKeyInfo)
        var message = Data(libp2pTLSSignaturePrefix.utf8)
        message.append(spkiDER)

        // 3. Sign with the libp2p private key
        let signature = try hostKeyPair.privateKey.sign(message)

        // 4. Create SignedKey
        return SignedKey(
            publicKey: hostKeyPair.publicKey.protobufEncoded,
            signature: signature
        )
    }

    /// Verifies the SignedKey signature.
    private static func verifySignedKey(
        signedKey: SignedKey,
        certificatePublicKey: Certificate.PublicKey,
        libp2pPublicKey: P2PCore.PublicKey
    ) throws -> Bool {
        // 1. Re-serialize the certificate public key to DER
        var spkiSerializer = DER.Serializer()
        try spkiSerializer.serialize(certificatePublicKey)
        let spkiDER = Data(spkiSerializer.serializedBytes)

        // 2. Reconstruct the message
        var message = Data(libp2pTLSSignaturePrefix.utf8)
        message.append(spkiDER)

        // 3. Verify with the libp2p public key
        return try libp2pPublicKey.verify(signature: signedKey.signatureData, for: message)
    }
}

// MARK: - Convenience Extensions

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
extension TLSCertificate: CustomStringConvertible {
    public var description: String {
        """
        TLSCertificate(
            peerID: \(peerID),
            validFrom: \(certificate.notValidBefore),
            validUntil: \(certificate.notValidAfter),
            keyType: \(libp2pPublicKey.keyType)
        )
        """
    }
}

@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
extension TLSCertificate {
    /// Returns the certificate in PEM format.
    public var pemEncoded: String {
        let base64 = certificateDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return """
        -----BEGIN CERTIFICATE-----
        \(base64)
        -----END CERTIFICATE-----
        """
    }
}
