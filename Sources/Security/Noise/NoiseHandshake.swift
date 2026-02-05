/// NoiseHandshake - XX pattern handshake state machine
import Foundation
import P2PCore
import Crypto

/// Manages the Noise XX handshake state.
///
/// XX pattern:
/// ```
/// -> e
/// <- e, ee, s, es
/// -> s, se
/// ```
///
/// Value type: ownership is explicit at the type level. The handshake progresses
/// through mutating methods within a single task, then `split()` extracts
/// transport cipher keys.
struct NoiseHandshake: Sendable {
    /// The local Noise static key pair (X25519).
    let localStaticKey: Curve25519.KeyAgreement.PrivateKey

    /// The local libp2p key pair for identity.
    let localKeyPair: KeyPair

    /// Whether we are the initiator (dialer) or responder (listener).
    let isInitiator: Bool

    /// The local ephemeral key pair (generated during handshake).
    private let localEphemeralKey: Curve25519.KeyAgreement.PrivateKey

    /// The remote's static public key (learned during handshake).
    private var _remoteStaticKey: Curve25519.KeyAgreement.PublicKey?
    var remoteStaticKey: Curve25519.KeyAgreement.PublicKey? { _remoteStaticKey }

    /// The remote's ephemeral public key (learned during handshake).
    private var _remoteEphemeralKey: Curve25519.KeyAgreement.PublicKey?
    var remoteEphemeralKey: Curve25519.KeyAgreement.PublicKey? { _remoteEphemeralKey }

    /// The symmetric state for the handshake.
    private var symmetricState: NoiseSymmetricState

    /// Creates a new handshake state.
    ///
    /// - Parameters:
    ///   - localKeyPair: The libp2p identity key pair
    ///   - isInitiator: True if we are initiating the connection
    init(localKeyPair: KeyPair, isInitiator: Bool) {
        self.localKeyPair = localKeyPair
        self.isInitiator = isInitiator

        // Generate Noise static key (X25519)
        self.localStaticKey = Curve25519.KeyAgreement.PrivateKey()

        // Generate ephemeral key
        self.localEphemeralKey = Curve25519.KeyAgreement.PrivateKey()

        // Initialize symmetric state with protocol name
        self.symmetricState = NoiseSymmetricState(protocolName: noiseProtocolName)

        // Mix in empty prologue (libp2p uses empty prologue)
        self.symmetricState.mixHash(Data())
    }

    // MARK: - Initiator Methods

    /// Writes Message A (initiator's first message).
    ///
    /// Pattern: `-> e`
    /// - Sends ephemeral public key
    /// - Per Noise spec, calls encryptAndHash on empty payload
    mutating func writeMessageA() -> Data {
        let ephemeralPub = Data(localEphemeralKey.publicKey.rawRepresentation)

        // Mix ephemeral into hash
        symmetricState.mixHash(ephemeralPub)

        // Per Noise spec, WriteMessage always calls EncryptAndHash on the payload.
        // For message A, there's no payload (empty), but we still need to call
        // encryptAndHash(empty) which does mixHash(empty ciphertext).
        // Since no key is set yet, encryptAndHash returns empty but still does mixHash(empty).
        // This is required for compatibility with go-libp2p/flynn-noise.
        _ = try? symmetricState.encryptAndHash(Data())

        return ephemeralPub
    }

    /// Reads Message B (responder's response).
    ///
    /// Pattern: `<- e, ee, s, es`
    /// - Receives responder's ephemeral
    /// - Performs ee DH
    /// - Decrypts responder's static
    /// - Performs es DH
    /// - Decrypts and verifies payload
    mutating func readMessageB(_ message: Data) throws -> NoisePayload {
        var offset = 0

        // Read remote ephemeral (32 bytes, unencrypted)
        guard message.count >= noisePublicKeySize else {
            throw NoiseError.handshakeFailed("Message B too short for ephemeral key")
        }
        let remoteEphemeralData = Data(message[offset..<offset + noisePublicKeySize])
        offset += noisePublicKeySize

        // Validate that the ephemeral key is not a small-order point
        guard validateX25519PublicKey(remoteEphemeralData) else {
            throw NoiseError.invalidKey
        }

        let remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralData)
        _remoteEphemeralKey = remoteEphemeral

        // Mix remote ephemeral into hash
        symmetricState.mixHash(remoteEphemeralData)

        // ee: DH(local ephemeral, remote ephemeral)
        let ee = try noiseKeyAgreement(privateKey: localEphemeralKey, publicKey: remoteEphemeral)
        symmetricState.mixKey(ee)

        // Decrypt remote static (32 bytes + 16 tag)
        let encryptedStaticSize = noisePublicKeySize + noiseAuthTagSize
        guard message.count >= offset + encryptedStaticSize else {
            throw NoiseError.handshakeFailed("Message B too short for static key")
        }
        let encryptedStatic = Data(message[offset..<offset + encryptedStaticSize])
        offset += encryptedStaticSize

        let remoteStaticData = try symmetricState.decryptAndHash(encryptedStatic)

        // Validate that the static key is not a small-order point
        guard validateX25519PublicKey(remoteStaticData) else {
            throw NoiseError.invalidKey
        }

        let remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticData)
        _remoteStaticKey = remoteStatic

        // es: DH(local ephemeral, remote static)
        let es = try noiseKeyAgreement(privateKey: localEphemeralKey, publicKey: remoteStatic)
        symmetricState.mixKey(es)

        // Decrypt payload
        let encryptedPayload = Data(message[offset...])
        let payloadData = try symmetricState.decryptAndHash(encryptedPayload)

        // Decode and verify payload
        let payload = try NoisePayload.decode(from: payloadData)
        return payload
    }

    /// Writes Message C (initiator's final message).
    ///
    /// Pattern: `-> s, se`
    /// - Encrypts our static public key
    /// - Performs se DH
    /// - Encrypts our payload
    mutating func writeMessageC() throws -> Data {
        guard let remoteEphemeral = _remoteEphemeralKey else {
            throw NoiseError.messageOutOfOrder
        }

        var result = Data()

        // Encrypt local static public key
        let localStaticPub = Data(localStaticKey.publicKey.rawRepresentation)
        let encryptedStatic = try symmetricState.encryptAndHash(localStaticPub)
        result.append(encryptedStatic)

        // se: DH(local static, remote ephemeral)
        let se = try noiseKeyAgreement(privateKey: localStaticKey, publicKey: remoteEphemeral)
        symmetricState.mixKey(se)

        // Create and encrypt payload
        let payload = try NoisePayload(keyPair: localKeyPair, noiseStaticPublicKey: localStaticPub)
        let encryptedPayload = try symmetricState.encryptAndHash(payload.encode())
        result.append(encryptedPayload)

        return result
    }

    // MARK: - Responder Methods

    /// Reads Message A (initiator's first message).
    ///
    /// Pattern: `-> e`
    /// - Receives initiator's ephemeral public key
    /// - Per Noise spec, calls decryptAndHash on remaining bytes (empty payload)
    mutating func readMessageA(_ message: Data) throws {
        guard message.count >= noisePublicKeySize else {
            throw NoiseError.handshakeFailed("Message A too short")
        }

        let remoteEphemeralData = Data(message.prefix(noisePublicKeySize))

        // Validate that the ephemeral key is not a small-order point
        guard validateX25519PublicKey(remoteEphemeralData) else {
            throw NoiseError.invalidKey
        }

        let remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralData)
        _remoteEphemeralKey = remoteEphemeral

        // Mix remote ephemeral into hash
        symmetricState.mixHash(remoteEphemeralData)

        // Per Noise spec, ReadMessage always calls DecryptAndHash on remaining bytes.
        // For message A, the remaining bytes are empty (no payload), but we still need
        // to call decryptAndHash(empty) which does mixHash(empty ciphertext).
        // Since no key is set yet, decryptAndHash returns empty but still does mixHash(empty).
        // This is required for compatibility with go-libp2p/flynn-noise.
        let remainingBytes = Data(message.dropFirst(noisePublicKeySize))
        _ = try symmetricState.decryptAndHash(remainingBytes)
    }

    /// Writes Message B (responder's response).
    ///
    /// Pattern: `<- e, ee, s, es`
    /// - Sends our ephemeral
    /// - Performs ee DH
    /// - Encrypts and sends our static
    /// - Performs es DH
    /// - Encrypts and sends payload
    mutating func writeMessageB() throws -> Data {
        guard let remoteEphemeral = _remoteEphemeralKey else {
            throw NoiseError.messageOutOfOrder
        }

        var result = Data()

        // Send our ephemeral (unencrypted)
        let localEphemeralPub = Data(localEphemeralKey.publicKey.rawRepresentation)
        result.append(localEphemeralPub)
        symmetricState.mixHash(localEphemeralPub)

        // ee: DH(local ephemeral, remote ephemeral)
        let ee = try noiseKeyAgreement(privateKey: localEphemeralKey, publicKey: remoteEphemeral)
        symmetricState.mixKey(ee)

        // Encrypt and send our static public key
        let localStaticPub = Data(localStaticKey.publicKey.rawRepresentation)
        let encryptedStatic = try symmetricState.encryptAndHash(localStaticPub)
        result.append(encryptedStatic)

        // es: DH(local static, remote ephemeral)
        // Note: For responder, "es" means DH(responder_static, initiator_ephemeral)
        let es = try noiseKeyAgreement(privateKey: localStaticKey, publicKey: remoteEphemeral)
        symmetricState.mixKey(es)

        // Create and encrypt payload
        let payload = try NoisePayload(keyPair: localKeyPair, noiseStaticPublicKey: localStaticPub)
        let encryptedPayload = try symmetricState.encryptAndHash(payload.encode())
        result.append(encryptedPayload)

        return result
    }

    /// Reads Message C (initiator's final message).
    ///
    /// Pattern: `-> s, se`
    /// - Decrypts initiator's static public key
    /// - Performs se DH
    /// - Decrypts and verifies payload
    mutating func readMessageC(_ message: Data) throws -> NoisePayload {
        var offset = 0

        // Decrypt remote static (32 bytes + 16 tag)
        let encryptedStaticSize = noisePublicKeySize + noiseAuthTagSize
        guard message.count >= encryptedStaticSize else {
            throw NoiseError.handshakeFailed("Message C too short for static key")
        }
        let encryptedStatic = Data(message[offset..<offset + encryptedStaticSize])
        offset += encryptedStaticSize

        let remoteStaticData = try symmetricState.decryptAndHash(encryptedStatic)

        // Validate that the static key is not a small-order point
        guard validateX25519PublicKey(remoteStaticData) else {
            throw NoiseError.invalidKey
        }

        let remoteStatic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticData)
        _remoteStaticKey = remoteStatic

        // se: DH(local ephemeral, remote static)
        // Note: For responder reading, "se" means DH(responder_ephemeral, initiator_static)
        let se = try noiseKeyAgreement(privateKey: localEphemeralKey, publicKey: remoteStatic)
        symmetricState.mixKey(se)

        // Decrypt payload
        let encryptedPayload = Data(message[offset...])
        let payloadData = try symmetricState.decryptAndHash(encryptedPayload)

        // Decode and verify payload
        let payload = try NoisePayload.decode(from: payloadData)
        return payload
    }

    // MARK: - Finalization

    /// Splits the handshake state into transport cipher states.
    ///
    /// Returns (send cipher, receive cipher) for this peer.
    mutating func split() -> (send: NoiseCipherState, recv: NoiseCipherState) {
        let (c1, c2) = symmetricState.split()

        if isInitiator {
            // Initiator: c1 is send, c2 is recv
            return (c1, c2)
        } else {
            // Responder: c2 is send, c1 is recv
            return (c2, c1)
        }
    }
}
