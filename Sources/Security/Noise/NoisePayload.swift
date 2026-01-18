/// NoisePayload - Handshake payload encoding/decoding for Noise protocol
import Foundation
import P2PCore
import Crypto

/// The handshake payload exchanged during Noise XX handshake.
///
/// Contains the libp2p identity key and a signature proving ownership
/// of the Noise static key.
struct NoisePayload: Sendable {
    /// The libp2p public key (protobuf encoded).
    let identityKey: Data

    /// Signature of "noise-libp2p-static-key:" + noise_static_public_key.
    let identitySig: Data

    /// Optional additional data (usually empty).
    let data: Data

    /// Creates a payload for the handshake.
    ///
    /// - Parameters:
    ///   - keyPair: The libp2p key pair for signing
    ///   - noiseStaticPublicKey: The Noise static public key to sign
    init(keyPair: KeyPair, noiseStaticPublicKey: Data) throws {
        self.identityKey = keyPair.publicKey.protobufEncoded

        // Create signature: sign("noise-libp2p-static-key:" + static_key)
        var signatureData = Data(noiseStaticKeySignaturePrefix.utf8)
        signatureData.append(noiseStaticPublicKey)

        self.identitySig = try keyPair.privateKey.sign(signatureData)
        self.data = Data()
    }

    /// Creates a payload from raw components.
    init(identityKey: Data, identitySig: Data, data: Data = Data()) {
        self.identityKey = identityKey
        self.identitySig = identitySig
        self.data = data
    }

    /// Verifies the payload and extracts the remote peer ID.
    ///
    /// - Parameter noiseStaticPublicKey: The remote's Noise static public key
    /// - Returns: The verified remote PeerID
    func verify(noiseStaticPublicKey: Data) throws -> PeerID {
        // Decode the identity public key
        let publicKey = try PublicKey(protobufEncoded: identityKey)

        // Verify signature: "noise-libp2p-static-key:" + static_key
        var signatureData = Data(noiseStaticKeySignaturePrefix.utf8)
        signatureData.append(noiseStaticPublicKey)

        guard try publicKey.verify(signature: identitySig, for: signatureData) else {
            throw NoiseError.invalidSignature
        }

        // Derive and return PeerID
        return PeerID(publicKey: publicKey)
    }

    // MARK: - Protobuf Encoding

    /// Encodes the payload to protobuf format.
    ///
    /// ```protobuf
    /// message NoiseHandshakePayload {
    ///   bytes identity_key = 1;
    ///   bytes identity_sig = 2;
    ///   bytes data = 3;
    /// }
    /// ```
    func encode() -> Data {
        var result = Data()

        // Field 1: identity_key (bytes)
        if !identityKey.isEmpty {
            result.append(0x0A) // (1 << 3) | 2 = length-delimited
            result.append(contentsOf: Varint.encode(UInt64(identityKey.count)))
            result.append(identityKey)
        }

        // Field 2: identity_sig (bytes)
        if !identitySig.isEmpty {
            result.append(0x12) // (2 << 3) | 2 = length-delimited
            result.append(contentsOf: Varint.encode(UInt64(identitySig.count)))
            result.append(identitySig)
        }

        // Field 3: data (bytes)
        if !data.isEmpty {
            result.append(0x1A) // (3 << 3) | 2 = length-delimited
            result.append(contentsOf: Varint.encode(UInt64(data.count)))
            result.append(data)
        }

        return result
    }

    /// Decodes a payload from protobuf format.
    static func decode(from data: Data) throws -> NoisePayload {
        var identityKey: Data?
        var identitySig: Data?
        var payloadData: Data?

        var remaining = data[data.startIndex...]

        while !remaining.isEmpty {
            // Read field tag
            let (fieldTag, tagBytes) = try Varint.decode(Data(remaining))
            remaining = remaining.dropFirst(tagBytes)

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            // All our fields are length-delimited (wire type 2)
            guard wireType == 2 else {
                throw NoiseError.invalidPayload
            }

            // Read field length
            let (fieldLength, lengthBytes) = try Varint.decode(Data(remaining))
            remaining = remaining.dropFirst(lengthBytes)

            guard remaining.count >= fieldLength else {
                throw NoiseError.invalidPayload
            }

            let fieldData = Data(remaining.prefix(Int(fieldLength)))
            remaining = remaining.dropFirst(Int(fieldLength))

            switch fieldNumber {
            case 1:
                identityKey = fieldData
            case 2:
                identitySig = fieldData
            case 3:
                payloadData = fieldData
            default:
                // Skip unknown fields
                break
            }
        }

        guard let key = identityKey, let sig = identitySig else {
            throw NoiseError.invalidPayload
        }

        return NoisePayload(
            identityKey: key,
            identitySig: sig,
            data: payloadData ?? Data()
        )
    }
}

// MARK: - Framing Helpers

/// Reads a length-prefixed Noise message from data.
///
/// - Parameter data: Buffer containing messages
/// - Returns: (message, bytesConsumed) or nil if incomplete
/// - Throws: `NoiseError.frameTooLarge` if the frame exceeds max size
func readNoiseMessage(from data: Data) throws -> (message: Data, bytesConsumed: Int)? {
    guard data.count >= 2 else {
        return nil
    }

    // Read 2-byte big-endian length
    let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])

    // Check max size to detect protocol violations
    guard length <= noiseMaxMessageSize else {
        throw NoiseError.frameTooLarge(size: length, max: noiseMaxMessageSize)
    }

    guard data.count >= 2 + length else {
        return nil
    }

    let message = Data(data[data.startIndex + 2 ..< data.startIndex + 2 + length])
    return (message, 2 + length)
}

/// Encodes a Noise message with length prefix.
///
/// - Parameter message: The message to encode
/// - Returns: Length-prefixed message
func encodeNoiseMessage(_ message: Data) throws -> Data {
    guard message.count <= noiseMaxMessageSize else {
        throw NoiseError.frameTooLarge(size: message.count, max: noiseMaxMessageSize)
    }

    var result = Data(capacity: 2 + message.count)
    result.append(UInt8((message.count >> 8) & 0xFF))
    result.append(UInt8(message.count & 0xFF))
    result.append(message)
    return result
}
