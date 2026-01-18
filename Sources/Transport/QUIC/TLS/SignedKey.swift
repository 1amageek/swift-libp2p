/// ASN.1 representation of the libp2p SignedKey structure.
///
/// This structure is embedded in the X.509 certificate extension
/// at OID 1.3.6.1.4.1.53594.1.1.
///
/// The ASN.1 schema is:
/// ```asn1
/// SignedKey ::= SEQUENCE {
///   publicKey OCTET STRING,   -- protobuf-encoded libp2p public key
///   signature OCTET STRING    -- signature over "libp2p-tls-handshake:" + cert public key
/// }
/// ```

import Foundation
import SwiftASN1

/// The libp2p extension OID: 1.3.6.1.4.1.53594.1.1
///
/// This OID was allocated by IANA to the libp2p project (Protocol Labs).
public let libp2pExtensionOID = try! ASN1ObjectIdentifier(elements: [1, 3, 6, 1, 4, 1, 53594, 1, 1])

/// Prefix used for signing in the libp2p TLS handshake.
public let libp2pTLSSignaturePrefix = "libp2p-tls-handshake:"

/// ASN.1 representation of the libp2p SignedKey structure.
///
/// This structure proves that the holder of the TLS certificate also
/// controls the libp2p identity key pair. It contains:
/// - `publicKey`: The protobuf-encoded libp2p public key
/// - `signature`: Signature over "libp2p-tls-handshake:" + DER(certificate public key)
///
/// ## Wire Format
///
/// The libp2p TLS specification requires:
/// 1. Generate an ephemeral TLS key pair (e.g., P-256)
/// 2. Create a self-signed X.509 certificate
/// 3. Add this extension with the libp2p public key and signature
/// 4. The signature binds the TLS certificate to the libp2p identity
public struct SignedKey: DERImplicitlyTaggable, Hashable, Sendable {

    public static var defaultIdentifier: ASN1Identifier {
        .sequence
    }

    /// The protobuf-encoded libp2p public key.
    ///
    /// This is encoded using the libp2p protobuf format:
    /// ```protobuf
    /// message PublicKey {
    ///   required KeyType Type = 1;
    ///   required bytes Data = 2;
    /// }
    /// ```
    public var publicKey: ArraySlice<UInt8>

    /// The signature proving ownership of the libp2p private key.
    ///
    /// This is created by signing:
    /// `"libp2p-tls-handshake:" + DER(SubjectPublicKeyInfo)`
    ///
    /// where SubjectPublicKeyInfo is the certificate's public key.
    public var signature: ArraySlice<UInt8>

    /// Creates a new SignedKey structure.
    ///
    /// - Parameters:
    ///   - publicKey: Protobuf-encoded libp2p public key
    ///   - signature: Signature over the binding message
    public init(publicKey: ArraySlice<UInt8>, signature: ArraySlice<UInt8>) {
        self.publicKey = publicKey
        self.signature = signature
    }

    /// Creates a new SignedKey from Data.
    ///
    /// - Parameters:
    ///   - publicKey: Protobuf-encoded libp2p public key
    ///   - signature: Signature over the binding message
    public init(publicKey: Data, signature: Data) {
        self.publicKey = ArraySlice(publicKey)
        self.signature = ArraySlice(signature)
    }

    // MARK: - DERImplicitlyTaggable

    public init(derEncoded rootNode: ASN1Node, withIdentifier identifier: ASN1Identifier) throws {
        self = try DER.sequence(rootNode, identifier: identifier) { nodes in
            let publicKeyOctetString = try ASN1OctetString(derEncoded: &nodes)
            let signatureOctetString = try ASN1OctetString(derEncoded: &nodes)

            return SignedKey(
                publicKey: publicKeyOctetString.bytes,
                signature: signatureOctetString.bytes
            )
        }
    }

    public func serialize(into coder: inout DER.Serializer, withIdentifier identifier: ASN1Identifier) throws {
        try coder.appendConstructedNode(identifier: identifier) { coder in
            try coder.serialize(ASN1OctetString(contentBytes: publicKey))
            try coder.serialize(ASN1OctetString(contentBytes: signature))
        }
    }
}

// MARK: - Convenience Extensions

extension SignedKey {
    /// The public key as Data.
    public var publicKeyData: Data {
        Data(publicKey)
    }

    /// The signature as Data.
    public var signatureData: Data {
        Data(signature)
    }

    /// Parses a SignedKey from DER-encoded bytes.
    ///
    /// - Parameter derBytes: DER-encoded SignedKey
    /// - Returns: The parsed SignedKey
    /// - Throws: `TLSCertificateError.asn1Error` if parsing fails
    public static func parse(_ derBytes: Data) throws -> SignedKey {
        do {
            return try SignedKey(derEncoded: Array(derBytes))
        } catch {
            throw TLSCertificateError.asn1Error(reason: "Failed to parse SignedKey: \(error)")
        }
    }

    /// Serializes this SignedKey to DER-encoded bytes.
    ///
    /// - Returns: DER-encoded bytes
    /// - Throws: `TLSCertificateError.asn1Error` if serialization fails
    public func serialize() throws -> Data {
        do {
            var serializer = DER.Serializer()
            try serializer.serialize(self)
            return Data(serializer.serializedBytes)
        } catch {
            throw TLSCertificateError.asn1Error(reason: "Failed to serialize SignedKey: \(error)")
        }
    }
}

// MARK: - CustomStringConvertible

extension SignedKey: CustomStringConvertible {
    public var description: String {
        "SignedKey(publicKey: \(publicKey.count) bytes, signature: \(signature.count) bytes)"
    }
}
