/// LibP2PCertificate - Certificate generation and parsing for libp2p TLS
///
/// Generates self-signed X.509 certificates with libp2p extension using
/// swift-certificates and SwiftASN1. Provides a CertificateValidator callback
/// for swift-tls to extract PeerID during TLS 1.3 handshake.

import Foundation
import Crypto
import P2PCore
import SwiftASN1
@preconcurrency import X509
import TLSCore

/// Helper for libp2p TLS certificate operations.
public enum LibP2PCertificate {

    /// The libp2p TLS signature prefix.
    public static let signaturePrefix = "libp2p-tls-handshake:"

    /// The libp2p extension OID: 1.3.6.1.4.1.53594.1.1
    public static let extensionOID = try! ASN1ObjectIdentifier(elements: [1, 3, 6, 1, 4, 1, 53594, 1, 1])

    // MARK: - Certificate Generation

    /// Generates a self-signed X.509 certificate with libp2p extension.
    ///
    /// The certificate:
    /// - Uses P-256 for the TLS key (ephemeral)
    /// - Is self-signed
    /// - Contains the libp2p extension with the host's public key and signature
    /// - Is valid for 1 year
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Returns: Certificate chain (DER) and signing key for TLS
    public static func generate(keyPair: KeyPair) throws -> (certificateChain: [Data], signingKey: TLSCore.SigningKey) {
        // 1. Generate ephemeral P-256 key pair for TLS
        let tlsPrivateKey = P256.Signing.PrivateKey()

        // 2. Get the SPKI DER for the TLS public key
        let spkiDER = try serializeSPKI(publicKey: tlsPrivateKey.publicKey)

        // 3. Create and sign the libp2p extension
        let message = Data(signaturePrefix.utf8) + spkiDER
        let signature = try keyPair.sign(message)

        // 4. Encode the SignedKey structure as ASN.1
        let signedKeyDER = try encodeSignedKey(
            publicKey: keyPair.publicKey.protobufEncoded,
            signature: signature
        )

        // 5. Create the X.509 certificate extension
        let libp2pExtension = Certificate.Extension(
            oid: extensionOID,
            critical: true,
            value: ArraySlice(signedKeyDER)
        )

        // 6. Build the certificate using swift-certificates
        let now = Date()
        var extensions = Certificate.Extensions()
        try extensions.append(libp2pExtension)

        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(tlsPrivateKey.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(365 * 24 * 3600),
            issuer: DistinguishedName {},
            subject: DistinguishedName {},
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(tlsPrivateKey)
        )

        // 7. Serialize to DER
        var serializer = DER.Serializer()
        try certificate.serialize(into: &serializer)
        let certificateDER = Data(serializer.serializedBytes)

        return (
            certificateChain: [certificateDER],
            signingKey: .p256(tlsPrivateKey)
        )
    }

    // MARK: - Certificate Validation

    /// Creates a `CertificateValidator` callback for swift-tls configuration.
    ///
    /// The returned callback validates the libp2p extension in the peer's certificate
    /// and extracts the PeerID. The PeerID is returned as the `Sendable` value,
    /// accessible via `TLSConnection.validatedPeerInfo`.
    ///
    /// - Parameter expectedPeer: Optional expected PeerID to verify against
    /// - Returns: A CertificateValidator closure
    public static func makeCertificateValidator(expectedPeer: PeerID?) -> CertificateValidator {
        return { (certChain: [Data]) throws -> (any Sendable)? in
            guard let leafDER = certChain.first else {
                throw TLSError.missingLibP2PExtension
            }

            let peerID = try extractPeerID(from: leafDER)

            if let expected = expectedPeer, expected != peerID {
                throw TLSError.peerIDMismatch(
                    expected: expected.description,
                    actual: peerID.description
                )
            }

            return peerID
        }
    }

    /// Extracts the PeerID from a DER-encoded certificate.
    ///
    /// Parses the libp2p extension, verifies the signature over the certificate's
    /// SPKI, and derives the PeerID from the libp2p public key.
    ///
    /// - Parameter certificateDER: The DER-encoded X.509 certificate
    /// - Returns: The verified PeerID
    public static func extractPeerID(from certificateDER: Data) throws -> PeerID {
        // Parse the certificate
        let cert = try Certificate(derEncoded: Array(certificateDER))

        // Find the libp2p extension
        guard let ext = cert.extensions[oid: extensionOID] else {
            throw TLSError.missingLibP2PExtension
        }

        // Parse the SignedKey structure from the extension value
        let (publicKeyData, signatureData) = try parseSignedKey(from: Data(ext.value))

        // Get the certificate's SPKI DER
        var spkiSerializer = DER.Serializer()
        try cert.publicKey.serialize(into: &spkiSerializer, withIdentifier: .sequence)
        let spkiDER = Data(spkiSerializer.serializedBytes)

        // Verify the signature
        let message = Data(signaturePrefix.utf8) + spkiDER
        let libp2pPublicKey = try PublicKey(protobufEncoded: publicKeyData)

        guard try libp2pPublicKey.verify(signature: signatureData, for: message) else {
            throw TLSError.invalidCertificateSignature
        }

        return libp2pPublicKey.peerID
    }

    // MARK: - ASN.1 Encoding

    /// Encodes a SignedKey structure to ASN.1 DER.
    ///
    /// ```
    /// SignedKey ::= SEQUENCE {
    ///     publicKey  OCTET STRING,  -- protobuf-encoded libp2p public key
    ///     signature  OCTET STRING   -- signature over "libp2p-tls-handshake:" + SPKI
    /// }
    /// ```
    private static func encodeSignedKey(publicKey: Data, signature: Data) throws -> [UInt8] {
        var serializer = DER.Serializer()
        try serializer.appendConstructedNode(identifier: .sequence) { coder in
            let pkOctetString = ASN1OctetString(contentBytes: ArraySlice(publicKey))
            try coder.serialize(pkOctetString)
            let sigOctetString = ASN1OctetString(contentBytes: ArraySlice(signature))
            try coder.serialize(sigOctetString)
        }
        return serializer.serializedBytes
    }

    /// Parses a SignedKey structure from ASN.1 DER.
    private static func parseSignedKey(from data: Data) throws -> (publicKey: Data, signature: Data) {
        let parsed = try DER.parse(Array(data))

        return try DER.sequence(parsed, identifier: .sequence) { iterator in
            let pkOctetString = try ASN1OctetString(derEncoded: &iterator)
            let sigOctetString = try ASN1OctetString(derEncoded: &iterator)
            return (Data(pkOctetString.bytes), Data(sigOctetString.bytes))
        }
    }

    /// Serializes the SubjectPublicKeyInfo for a P-256 public key.
    private static func serializeSPKI(publicKey: P256.Signing.PublicKey) throws -> Data {
        let certPublicKey = Certificate.PublicKey(publicKey)
        var serializer = DER.Serializer()
        try certPublicKey.serialize(into: &serializer, withIdentifier: .sequence)
        return Data(serializer.serializedBytes)
    }
}
