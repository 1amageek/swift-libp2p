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
        if !identityKey.isEmpty {
            result.append(encodeProtobufField(fieldNumber: 1, data: identityKey))
        }
        if !identitySig.isEmpty {
            result.append(encodeProtobufField(fieldNumber: 2, data: identitySig))
        }
        if !data.isEmpty {
            result.append(encodeProtobufField(fieldNumber: 3, data: data))
        }
        return result
    }

    /// Decodes a payload from protobuf format.
    static func decode(from data: Data) throws -> NoisePayload {
        let fields: [ProtobufField]
        do {
            fields = try decodeProtobufFields(from: data)
        } catch {
            throw NoiseError.invalidPayload
        }

        var identityKey: Data?
        var identitySig: Data?
        var payloadData: Data?

        for field in fields {
            switch field.fieldNumber {
            case 1: identityKey = field.data
            case 2: identitySig = field.data
            case 3: payloadData = field.data
            default: break
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
    do {
        guard let result = try readLengthPrefixedFrame(from: data, maxMessageSize: noiseMaxMessageSize) else {
            return nil
        }
        return (result.message, result.consumed)
    } catch is FramingError {
        throw NoiseError.frameTooLarge(size: 0, max: noiseMaxMessageSize)
    }
}

/// Encodes a Noise message with length prefix.
///
/// - Parameter message: The message to encode
/// - Returns: Length-prefixed message
func encodeNoiseMessage(_ message: Data) throws -> Data {
    do {
        return try encodeLengthPrefixedFrame(message, maxMessageSize: noiseMaxMessageSize)
    } catch is FramingError {
        throw NoiseError.frameTooLarge(size: message.count, max: noiseMaxMessageSize)
    }
}
