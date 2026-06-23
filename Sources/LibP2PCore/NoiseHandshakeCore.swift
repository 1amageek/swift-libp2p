/// Noise XX `HandshakeState` over the crypto seam (Embedded-clean, generic `<C>`).
///
/// Embedded-clean: no Foundation, no Crypto, no `any`, typed throws. Drives the
/// libp2p Noise XX pattern
///
/// ```
/// -> e
/// <- e, ee, s, es
/// -> s, se
/// ```
///
/// over `C`: X25519 DH via ``NoiseKeyAgreementCore``, ChaCha20-Poly1305 / HKDF /
/// SHA-256 via ``NoiseSymmetricStateCore``, payload framing via
/// ``NoisePayloadFields``. The identity-key signature that authenticates the
/// remote PeerID is built/verified by the `P2PSecurityNoise` adapter over the
/// decrypted payload this core returns (`P2PCore` identity keys are multi-scheme:
/// Ed25519 raw + ECDSA-P256 DER). The remote static key surfaced here is the value
/// the adapter binds that signature to — keeping verification fail-closed.
///
/// Value type: ownership is explicit; transitions are `mutating`. The adapter holds
/// the `Mutex`/async transport wiring and specialises at `C = NoiseFoundationProvider`.

import P2PCoreBytes
import P2PCoreCrypto

/// The XX handshake state machine over `C`.
public struct NoiseHandshakeCore<C: CryptoProvider>: Sendable {

    /// The local Noise static key pair (X25519).
    public let localStaticPrivateKey: C.X25519.PrivateKey

    /// The local static public key bytes (32 bytes, raw X25519).
    public let localStaticPublicKey: [UInt8]

    /// Whether we are the initiator (dialer) or responder (listener).
    public let isInitiator: Bool

    /// The local ephemeral key pair (generated during the handshake).
    private let localEphemeralPrivateKey: C.X25519.PrivateKey
    private let localEphemeralPublicKey: [UInt8]

    /// The remote's static public key bytes (learned during the handshake).
    public private(set) var remoteStaticPublicKey: [UInt8]?

    /// The remote's ephemeral public key bytes (learned during the handshake).
    public private(set) var remoteEphemeralPublicKey: [UInt8]?

    /// The symmetric state for the handshake.
    private var symmetricState: NoiseSymmetricStateCore<C>

    private static var publicKeySize: Int { 32 }
    private static var tagSize: Int { C.ChaChaPoly.tagLength }

    /// Creates a handshake state from raw key material.
    ///
    /// - Parameters:
    ///   - staticPrivateKeyRaw: The 32-byte raw X25519 static private key.
    ///   - ephemeralPrivateKeyRaw: The 32-byte raw X25519 ephemeral private key.
    ///   - isInitiator: True if we initiate the connection.
    ///   - protocolName: The Noise protocol-name bytes (e.g. `NoiseFraming.protocolName`).
    public init(
        staticPrivateKeyRaw: [UInt8],
        ephemeralPrivateKeyRaw: [UInt8],
        isInitiator: Bool,
        protocolName: [UInt8]
    ) throws(NoiseCryptoError) {
        let staticPriv: C.X25519.PrivateKey
        let ephemeralPriv: C.X25519.PrivateKey
        do {
            staticPriv = try C.X25519.privateKey(rawRepresentation: staticPrivateKeyRaw.span)
            ephemeralPriv = try C.X25519.privateKey(rawRepresentation: ephemeralPrivateKeyRaw.span)
        } catch {
            throw .invalidKey
        }

        self.localStaticPrivateKey = staticPriv
        self.localStaticPublicKey = C.X25519.rawRepresentation(of: C.X25519.publicKey(for: staticPriv))
        self.localEphemeralPrivateKey = ephemeralPriv
        self.localEphemeralPublicKey = C.X25519.rawRepresentation(of: C.X25519.publicKey(for: ephemeralPriv))
        self.isInitiator = isInitiator
        self.remoteStaticPublicKey = nil
        self.remoteEphemeralPublicKey = nil

        var state = NoiseSymmetricStateCore<C>(protocolName: protocolName)
        // libp2p uses an empty prologue.
        state.mixHash([])
        self.symmetricState = state
    }

    // MARK: - Initiator

    /// Message A: `-> e`. Sends the ephemeral public key (unencrypted) and runs
    /// `encryptAndHash(empty)` per the Noise spec (mixes the empty ciphertext into
    /// `h`; required for go-libp2p/flynn-noise interop).
    public mutating func writeMessageA() throws(NoiseCryptoError) -> [UInt8] {
        symmetricState.mixHash(localEphemeralPublicKey)
        _ = try symmetricState.encryptAndHash([])
        return localEphemeralPublicKey
    }

    /// Message B: `<- e, ee, s, es`. Reads the remote ephemeral, performs `ee`,
    /// decrypts the remote static, performs `es`, then decrypts the payload.
    ///
    /// - Returns: The decrypted handshake payload fields. The remote static key is
    ///   available via ``remoteStaticPublicKey`` for identity binding.
    public mutating func readMessageB(
        _ message: [UInt8]
    ) throws(NoiseCryptoError) -> NoisePayloadFields {
        var offset = 0

        let remoteEphemeral = try readPublicKey(message, at: &offset)
        guard NoiseKeyAgreementCore<C>.isAcceptablePublicKey(remoteEphemeral) else {
            throw .invalidKey
        }
        remoteEphemeralPublicKey = remoteEphemeral
        symmetricState.mixHash(remoteEphemeral)

        // ee
        let ee = try NoiseKeyAgreementCore<C>.sharedSecret(
            privateKey: localEphemeralPrivateKey, peerPublicKey: remoteEphemeral)
        symmetricState.mixKey(ee)

        // Decrypt remote static (32 + tag)
        let encryptedStatic = try readEncryptedStatic(message, at: &offset)
        let remoteStatic = try symmetricState.decryptAndHash(encryptedStatic)
        guard NoiseKeyAgreementCore<C>.isAcceptablePublicKey(remoteStatic) else {
            throw .invalidKey
        }
        remoteStaticPublicKey = remoteStatic

        // es
        let es = try NoiseKeyAgreementCore<C>.sharedSecret(
            privateKey: localEphemeralPrivateKey, peerPublicKey: remoteStatic)
        symmetricState.mixKey(es)

        // Decrypt payload
        let encryptedPayload = Array(message[offset...])
        let payloadData = try symmetricState.decryptAndHash(encryptedPayload)
        return try Self.decodePayload(payloadData)
    }

    /// Message C: `-> s, se`. Encrypts the local static, performs `se`, then
    /// encrypts the supplied (already-signed) payload bytes.
    ///
    /// - Parameter payload: The encoded ``NoisePayloadFields`` bytes the adapter
    ///   built (identity key + signature over the static key).
    public mutating func writeMessageC(
        payload: [UInt8]
    ) throws(NoiseCryptoError) -> [UInt8] {
        guard let remoteEphemeral = remoteEphemeralPublicKey else {
            throw .messageOutOfOrder
        }

        var result = [UInt8]()

        let encryptedStatic = try symmetricState.encryptAndHash(localStaticPublicKey)
        result.append(contentsOf: encryptedStatic)

        // se
        let se = try NoiseKeyAgreementCore<C>.sharedSecret(
            privateKey: localStaticPrivateKey, peerPublicKey: remoteEphemeral)
        symmetricState.mixKey(se)

        let encryptedPayload = try symmetricState.encryptAndHash(payload)
        result.append(contentsOf: encryptedPayload)
        return result
    }

    // MARK: - Responder

    /// Message A: `-> e`. Reads the remote ephemeral and runs `decryptAndHash` on
    /// the remaining (empty) bytes per the Noise spec.
    public mutating func readMessageA(_ message: [UInt8]) throws(NoiseCryptoError) {
        var offset = 0
        let remoteEphemeral = try readPublicKey(message, at: &offset)
        guard NoiseKeyAgreementCore<C>.isAcceptablePublicKey(remoteEphemeral) else {
            throw .invalidKey
        }
        remoteEphemeralPublicKey = remoteEphemeral
        symmetricState.mixHash(remoteEphemeral)

        let remaining = Array(message[offset...])
        _ = try symmetricState.decryptAndHash(remaining)
    }

    /// Message B: `<- e, ee, s, es`. Sends the ephemeral, performs `ee`, encrypts
    /// the static, performs `es`, then encrypts the supplied payload bytes.
    ///
    /// - Parameter payload: The encoded ``NoisePayloadFields`` bytes the adapter
    ///   built (identity key + signature over the static key).
    public mutating func writeMessageB(
        payload: [UInt8]
    ) throws(NoiseCryptoError) -> [UInt8] {
        guard let remoteEphemeral = remoteEphemeralPublicKey else {
            throw .messageOutOfOrder
        }

        var result = [UInt8]()
        result.append(contentsOf: localEphemeralPublicKey)
        symmetricState.mixHash(localEphemeralPublicKey)

        // ee
        let ee = try NoiseKeyAgreementCore<C>.sharedSecret(
            privateKey: localEphemeralPrivateKey, peerPublicKey: remoteEphemeral)
        symmetricState.mixKey(ee)

        let encryptedStatic = try symmetricState.encryptAndHash(localStaticPublicKey)
        result.append(contentsOf: encryptedStatic)

        // es
        let es = try NoiseKeyAgreementCore<C>.sharedSecret(
            privateKey: localStaticPrivateKey, peerPublicKey: remoteEphemeral)
        symmetricState.mixKey(es)

        let encryptedPayload = try symmetricState.encryptAndHash(payload)
        result.append(contentsOf: encryptedPayload)
        return result
    }

    /// Message C: `-> s, se`. Decrypts the remote static, performs `se`, then
    /// decrypts the payload.
    ///
    /// - Returns: The decrypted handshake payload fields. The remote static key is
    ///   available via ``remoteStaticPublicKey`` for identity binding.
    public mutating func readMessageC(
        _ message: [UInt8]
    ) throws(NoiseCryptoError) -> NoisePayloadFields {
        var offset = 0

        let encryptedStatic = try readEncryptedStatic(message, at: &offset)
        let remoteStatic = try symmetricState.decryptAndHash(encryptedStatic)
        guard NoiseKeyAgreementCore<C>.isAcceptablePublicKey(remoteStatic) else {
            throw .invalidKey
        }
        remoteStaticPublicKey = remoteStatic

        // se (responder side: DH(responder ephemeral, initiator static))
        let se = try NoiseKeyAgreementCore<C>.sharedSecret(
            privateKey: localEphemeralPrivateKey, peerPublicKey: remoteStatic)
        symmetricState.mixKey(se)

        let encryptedPayload = Array(message[offset...])
        let payloadData = try symmetricState.decryptAndHash(encryptedPayload)
        return try Self.decodePayload(payloadData)
    }

    // MARK: - Finalization

    /// Splits the handshake into transport cipher states `(send, recv)` for this
    /// peer (initiator: `c1`/`c2`; responder: swapped).
    public func split() -> (send: NoiseCipherStateCore<C>, recv: NoiseCipherStateCore<C>) {
        let (c1, c2) = symmetricState.split()
        if isInitiator {
            return (c1, c2)
        } else {
            return (c2, c1)
        }
    }

    /// The current handshake hash `h`, exposed for transcript-binding assertions.
    public var handshakeHash: [UInt8] { symmetricState.handshakeHash }

    // MARK: - Wire helpers

    private func readPublicKey(_ message: [UInt8], at offset: inout Int) throws(NoiseCryptoError) -> [UInt8] {
        let end = offset + Self.publicKeySize
        guard end <= message.count else {
            throw .messageTooShort
        }
        let key = Array(message[offset..<end])
        offset = end
        return key
    }

    private func readEncryptedStatic(_ message: [UInt8], at offset: inout Int) throws(NoiseCryptoError) -> [UInt8] {
        let end = offset + Self.publicKeySize + Self.tagSize
        guard end <= message.count else {
            throw .messageTooShort
        }
        let block = Array(message[offset..<end])
        offset = end
        return block
    }

    private static func decodePayload(_ bytes: [UInt8]) throws(NoiseCryptoError) -> NoisePayloadFields {
        do {
            return try NoisePayloadFields.decode(from: bytes)
        } catch {
            throw .invalidPayload
        }
    }
}
