import Foundation
import Crypto

/// A signed envelope that wraps a record with cryptographic signature.
///
/// The envelope format is compatible with libp2p's signed envelope specification.
/// It contains a public key, payload type, payload, and signature.
public struct Envelope: Sendable, Equatable {
    /// The public key of the signer.
    public let publicKey: PublicKey

    /// The payload type (multicodec).
    public let payloadType: Data

    /// The raw payload data.
    public let payload: Data

    /// The signature over the unsigned data.
    public let signature: Data

    /// Creates an envelope by signing a record with the given key pair.
    public static func seal<R: SignedRecord>(
        record: R,
        with keyPair: KeyPair
    ) throws -> Envelope {
        let payload = try record.marshal()
        let unsignedData = makeSigningData(
            domain: R.domain,
            payloadType: R.codec,
            payload: payload
        )

        let signature = try keyPair.sign(unsignedData)

        return Envelope(
            publicKey: keyPair.publicKey,
            payloadType: R.codec,
            payload: payload,
            signature: signature
        )
    }

    /// Opens an envelope and verifies the signature with domain separation.
    ///
    /// - Parameter domain: The domain string for signature verification.
    /// - Returns: The public key and payload if verification succeeds.
    /// - Throws: `EnvelopeError.invalidSignature` if verification fails.
    public func open(domain: String) throws -> (publicKey: PublicKey, payload: Data) {
        guard try verify(domain: domain) else {
            throw EnvelopeError.invalidSignature
        }
        return (publicKey, payload)
    }

    /// Extracts and unmarshals the record from this envelope.
    ///
    /// This method verifies the signature using the domain from the record type,
    /// ensuring proper domain separation as required by the libp2p spec.
    public func record<R: SignedRecord>(as type: R.Type) throws -> R {
        guard payloadType == R.codec else {
            throw EnvelopeError.payloadTypeMismatch
        }
        guard try verify(domain: R.domain) else {
            throw EnvelopeError.invalidSignature
        }
        return try R.unmarshal(payload)
    }

    /// Verifies the envelope's signature with domain separation.
    ///
    /// - Parameter domain: The domain string for signature verification.
    ///   This must match the domain used when the envelope was sealed.
    /// - Returns: Whether the signature is valid.
    /// - Throws: If verification fails due to key issues.
    ///
    /// - Important: Always use this method for signature verification.
    ///   Domain separation prevents cross-protocol replay attacks.
    public func verify(domain: String) throws -> Bool {
        let unsignedData = Self.makeSigningData(
            domain: domain,
            payloadType: payloadType,
            payload: payload
        )
        return try publicKey.verify(signature: signature, for: unsignedData)
    }

    /// Verifies the envelope's signature for a specific record type.
    ///
    /// Convenience method that uses the domain from the record type.
    public func verify<R: SignedRecord>(as type: R.Type) throws -> Bool {
        guard payloadType == R.codec else {
            throw EnvelopeError.payloadTypeMismatch
        }
        return try verify(domain: R.domain)
    }

    /// The peer ID of the envelope's signer.
    public var peerID: PeerID {
        publicKey.peerID
    }

    /// Serializes the envelope to bytes.
    public func marshal() throws -> Data {
        let publicKeyBytes = publicKey.protobufEncoded
        // Estimate: 4 varint prefixes (max 10 bytes each) + field data
        let estimatedSize = 40 + publicKeyBytes.count + payloadType.count + payload.count + signature.count
        var result = Data(capacity: estimatedSize)

        // Public key (length-prefixed protobuf)
        result.append(contentsOf: Varint.encode(UInt64(publicKeyBytes.count)))
        result.append(publicKeyBytes)

        // Payload type (length-prefixed)
        result.append(contentsOf: Varint.encode(UInt64(payloadType.count)))
        result.append(payloadType)

        // Payload (length-prefixed)
        result.append(contentsOf: Varint.encode(UInt64(payload.count)))
        result.append(payload)

        // Signature (length-prefixed)
        result.append(contentsOf: Varint.encode(UInt64(signature.count)))
        result.append(signature)

        return result
    }

    /// Maximum allowed length for individual fields to prevent DoS attacks.
    private static let maxFieldLength: UInt64 = 1024 * 1024  // 1MB for payload

    /// Deserializes an envelope from bytes.
    public static func unmarshal(_ data: Data) throws -> Envelope {
        var offset = 0

        // Public key (typically small, 4KB max)
        let (publicKeyLength, pkLenBytes) = try Varint.decode(data[offset...])
        guard publicKeyLength <= 4096 else {
            throw EnvelopeError.fieldTooLarge(publicKeyLength)
        }
        offset += pkLenBytes
        let pkLen = Int(publicKeyLength)
        let publicKeyEnd = offset + pkLen
        guard publicKeyEnd <= data.count else {
            throw EnvelopeError.invalidFormat
        }
        let publicKey = try PublicKey(protobufEncoded: Data(data[offset..<publicKeyEnd]))
        offset = publicKeyEnd

        // Payload type (typically a few bytes)
        let (payloadTypeLength, ptLenBytes) = try Varint.decode(data[offset...])
        guard payloadTypeLength <= 256 else {
            throw EnvelopeError.fieldTooLarge(payloadTypeLength)
        }
        offset += ptLenBytes
        let ptLen = Int(payloadTypeLength)
        let payloadTypeEnd = offset + ptLen
        guard payloadTypeEnd <= data.count else {
            throw EnvelopeError.invalidFormat
        }
        let payloadType = Data(data[offset..<payloadTypeEnd])
        offset = payloadTypeEnd

        // Payload
        let (payloadLength, pLenBytes) = try Varint.decode(data[offset...])
        guard payloadLength <= maxFieldLength else {
            throw EnvelopeError.fieldTooLarge(payloadLength)
        }
        offset += pLenBytes
        let pLen = Int(payloadLength)
        let payloadEnd = offset + pLen
        guard payloadEnd <= data.count else {
            throw EnvelopeError.invalidFormat
        }
        let payload = Data(data[offset..<payloadEnd])
        offset = payloadEnd

        // Signature (typically 64-512 bytes)
        let (signatureLength, sLenBytes) = try Varint.decode(data[offset...])
        guard signatureLength <= 1024 else {
            throw EnvelopeError.fieldTooLarge(signatureLength)
        }
        offset += sLenBytes
        let sigLen = Int(signatureLength)
        let signatureEnd = offset + sigLen
        guard signatureEnd <= data.count else {
            throw EnvelopeError.invalidFormat
        }
        let signature = Data(data[offset..<signatureEnd])

        return Envelope(
            publicKey: publicKey,
            payloadType: payloadType,
            payload: payload,
            signature: signature
        )
    }

    // MARK: - Private

    private init(
        publicKey: PublicKey,
        payloadType: Data,
        payload: Data,
        signature: Data
    ) {
        self.publicKey = publicKey
        self.payloadType = payloadType
        self.payload = payload
        self.signature = signature
    }

    /// Creates the data to be signed (with domain).
    private static func makeSigningData(
        domain: String,
        payloadType: Data,
        payload: Data
    ) -> Data {
        let domainBytes = Data(domain.utf8)
        // Estimate: 3 varint prefixes (max 10 bytes each) + field data
        var data = Data(capacity: 30 + domainBytes.count + payloadType.count + payload.count)

        // Domain length (varint) + domain
        data.append(contentsOf: Varint.encode(UInt64(domainBytes.count)))
        data.append(domainBytes)

        // Payload type length (varint) + payload type
        data.append(contentsOf: Varint.encode(UInt64(payloadType.count)))
        data.append(payloadType)

        // Payload length (varint) + payload
        data.append(contentsOf: Varint.encode(UInt64(payload.count)))
        data.append(payload)

        return data
    }

}

/// Errors that can occur when working with envelopes.
public enum EnvelopeError: Error, Sendable {
    case invalidSignature
    case invalidFormat
    case payloadTypeMismatch
    case fieldTooLarge(UInt64)
}
