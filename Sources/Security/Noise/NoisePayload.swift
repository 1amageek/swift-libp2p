/// NoisePayload - Handshake payload encoding/decoding for Noise protocol
///
/// The payload protobuf *framing* now lives in the Embedded-clean ``LibP2PCore``
/// (`NoisePayloadFields`). This adapter keeps the crypto (key sign/verify,
/// PeerID derivation) and the `Data`/NIO framing surface, delegating the byte
/// framing to the core.
import Foundation
import P2PCore
import LibP2PCore
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

    /// Creates a payload from the Embedded-clean core's decoded fields.
    init(fields: NoisePayloadFields) {
        self.identityKey = Data(fields.identityKey)
        self.identitySig = Data(fields.identitySig)
        self.data = Data(fields.data)
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
        let fields = NoisePayloadFields(
            identityKey: [UInt8](identityKey),
            identitySig: [UInt8](identitySig),
            data: [UInt8](data)
        )
        return Data(fields.encode())
    }

    /// Decodes a payload from protobuf format.
    static func decode(from data: Data) throws -> NoisePayload {
        let fields: NoisePayloadFields
        do {
            fields = try NoisePayloadFields.decode(from: [UInt8](data))
        } catch {
            throw NoiseError.invalidPayload
        }

        return NoisePayload(
            identityKey: Data(fields.identityKey),
            identitySig: Data(fields.identitySig),
            data: Data(fields.data)
        )
    }
}

// MARK: - Framing Helpers

/// Reads a length-prefixed Noise message from data.
///
/// Delegates the `[UInt8]` framing to the Embedded-clean core (`NoiseFraming`);
/// the `Data` surface stays adapter-side.
///
/// - Parameter data: Buffer containing messages
/// - Returns: (message, bytesConsumed) or nil if incomplete
/// - Throws: `NoiseError.frameTooLarge` if the frame exceeds max size
func readNoiseMessage(from data: Data) throws -> (message: Data, bytesConsumed: Int)? {
    do {
        guard let result = try NoiseFraming.read(from: [UInt8](data)) else {
            return nil
        }
        return (Data(result.message), result.consumed)
    } catch let error as NoiseFramingError {
        switch error {
        case .frameTooLarge(let size, let max):
            throw NoiseError.frameTooLarge(size: size, max: max)
        }
    }
}

/// Reads a length-prefixed Noise message from a ByteBuffer.
///
/// - Parameter buffer: Buffer containing messages. Advances the reader index on success.
/// - Returns: The message slice, or nil if incomplete
/// - Throws: `NoiseError.frameTooLarge` if the frame exceeds max size
func readNoiseMessage(from buffer: inout ByteBuffer) throws -> ByteBuffer? {
    do {
        return try readLengthPrefixedFrame(from: &buffer, maxMessageSize: noiseMaxMessageSize)
    } catch is FramingError {
        throw NoiseError.frameTooLarge(size: 0, max: noiseMaxMessageSize)
    }
}

/// Encodes a Noise message with length prefix.
///
/// Delegates the `[UInt8]` framing to the Embedded-clean core (`NoiseFraming`);
/// the `Data` surface stays adapter-side.
///
/// - Parameter message: The message to encode
/// - Returns: Length-prefixed message
func encodeNoiseMessage(_ message: Data) throws -> Data {
    do {
        return Data(try NoiseFraming.encode([UInt8](message)))
    } catch let error as NoiseFramingError {
        switch error {
        case .frameTooLarge(let size, let max):
            throw NoiseError.frameTooLarge(size: size, max: max)
        }
    }
}

/// Encodes a Noise message with length prefix into a ByteBuffer.
///
/// - Parameters:
///   - message: The message to encode
///   - buffer: Destination buffer
func encodeNoiseMessage(_ message: ByteBuffer, into buffer: inout ByteBuffer) throws {
    do {
        try encodeLengthPrefixedFrame(message, maxMessageSize: noiseMaxMessageSize, into: &buffer)
    } catch is FramingError {
        throw NoiseError.frameTooLarge(size: message.readableBytes, max: noiseMaxMessageSize)
    }
}

/// Encodes a Noise message with length prefix into a ByteBuffer.
///
/// - Parameters:
///   - message: The message to encode
///   - buffer: Destination buffer
func encodeNoiseMessage<Message: DataProtocol>(_ message: Message, into buffer: inout ByteBuffer) throws {
    do {
        try encodeLengthPrefixedFrame(message, maxMessageSize: noiseMaxMessageSize, into: &buffer)
    } catch is FramingError {
        throw NoiseError.frameTooLarge(size: message.count, max: noiseMaxMessageSize)
    }
}
