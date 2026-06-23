/// NoiseHandshake - XX pattern handshake state machine (adapter).
///
/// The XX state machine + crypto now live in the Embedded-clean ``LibP2PCore``
/// (`NoiseHandshakeCore<C>`); this adapter is a `Data`/CryptoKit/`KeyPair` bridge
/// that specialises the core at `C = NoiseFoundationProvider`. It owns the libp2p
/// identity binding: it builds the signed ``NoisePayload`` for the messages it
/// writes, and the caller verifies the ``NoisePayload`` this returns (fail-closed
/// signature check authenticating the remote PeerID).
import Foundation
import P2PCore
import LibP2PCore
import Crypto

private typealias HandshakeCore = NoiseHandshakeCore<NoiseFoundationProvider>

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

    /// The Embedded-clean XX state machine, specialised at the host provider.
    private var core: HandshakeCore

    /// The remote's static public key (learned during the handshake).
    ///
    /// The raw bytes were already imported through the seam by the core, so
    /// re-parsing here cannot fail; the `do/catch` exists only to avoid `try?`.
    var remoteStaticKey: Curve25519.KeyAgreement.PublicKey? {
        guard let raw = core.remoteStaticPublicKey else { return nil }
        return Self.curve25519PublicKey(from: raw)
    }

    /// The remote's ephemeral public key (learned during the handshake).
    var remoteEphemeralKey: Curve25519.KeyAgreement.PublicKey? {
        guard let raw = core.remoteEphemeralPublicKey else { return nil }
        return Self.curve25519PublicKey(from: raw)
    }

    /// Re-imports a raw X25519 public key the core already validated.
    private static func curve25519PublicKey(from raw: [UInt8]) -> Curve25519.KeyAgreement.PublicKey? {
        do {
            return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(raw))
        } catch {
            return nil
        }
    }

    /// Creates a new handshake state.
    ///
    /// - Parameters:
    ///   - localKeyPair: The libp2p identity key pair.
    ///   - isInitiator: True if we are initiating the connection.
    init(localKeyPair: KeyPair, isInitiator: Bool) {
        self.localKeyPair = localKeyPair
        self.isInitiator = isInitiator

        // Generate the Noise static + ephemeral X25519 keys (CryptoKit), then hand
        // their raw bytes to the core, which re-imports them through the seam.
        let staticKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        self.localStaticKey = staticKey

        // Core construction only fails on malformed raw keys; freshly generated
        // CryptoKit keys are always valid, so this cannot throw in practice.
        do {
            self.core = try HandshakeCore(
                staticPrivateKeyRaw: [UInt8](staticKey.rawRepresentation),
                ephemeralPrivateKeyRaw: [UInt8](ephemeralKey.rawRepresentation),
                isInitiator: isInitiator,
                protocolName: [UInt8](NoiseFraming.protocolName.utf8)
            )
        } catch {
            preconditionFailure("NoiseHandshakeCore rejected a freshly generated X25519 key pair")
        }
    }

    // MARK: - Initiator Methods

    /// Writes Message A (initiator's first message). Pattern: `-> e`.
    mutating func writeMessageA() throws -> Data {
        do {
            return Data(try core.writeMessageA())
        } catch {
            throw mapHandshakeCoreError(error)
        }
    }

    /// Reads Message B (responder's response). Pattern: `<- e, ee, s, es`.
    mutating func readMessageB<Message: RandomAccessCollection & DataProtocol>(
        _ message: Message
    ) throws -> NoisePayload where Message.Element == UInt8, Message.SubSequence: DataProtocol {
        do {
            let fields = try core.readMessageB([UInt8](message))
            return NoisePayload(fields: fields)
        } catch {
            throw mapHandshakeCoreError(error)
        }
    }

    mutating func readMessageB(_ message: ByteBuffer) throws -> NoisePayload {
        try readMessageB(message.readableBytesView)
    }

    /// Writes Message C (initiator's final message). Pattern: `-> s, se`.
    mutating func writeMessageC() throws -> Data {
        let payloadBytes = try makeSignedPayloadBytes()
        do {
            return Data(try core.writeMessageC(payload: payloadBytes))
        } catch {
            throw mapHandshakeCoreError(error)
        }
    }

    // MARK: - Responder Methods

    /// Reads Message A (initiator's first message). Pattern: `-> e`.
    mutating func readMessageA<Message: RandomAccessCollection & DataProtocol>(
        _ message: Message
    ) throws where Message.Element == UInt8, Message.SubSequence: DataProtocol {
        do {
            try core.readMessageA([UInt8](message))
        } catch {
            throw mapHandshakeCoreError(error)
        }
    }

    mutating func readMessageA(_ message: ByteBuffer) throws {
        try readMessageA(message.readableBytesView)
    }

    /// Writes Message B (responder's response). Pattern: `<- e, ee, s, es`.
    mutating func writeMessageB() throws -> Data {
        let payloadBytes = try makeSignedPayloadBytes()
        do {
            return Data(try core.writeMessageB(payload: payloadBytes))
        } catch {
            throw mapHandshakeCoreError(error)
        }
    }

    /// Reads Message C (initiator's final message). Pattern: `-> s, se`.
    mutating func readMessageC<Message: RandomAccessCollection & DataProtocol>(
        _ message: Message
    ) throws -> NoisePayload where Message.Element == UInt8, Message.SubSequence: DataProtocol {
        do {
            let fields = try core.readMessageC([UInt8](message))
            return NoisePayload(fields: fields)
        } catch {
            throw mapHandshakeCoreError(error)
        }
    }

    mutating func readMessageC(_ message: ByteBuffer) throws -> NoisePayload {
        try readMessageC(message.readableBytesView)
    }

    // MARK: - Finalization

    /// Splits the handshake state into transport cipher states `(send, recv)`.
    mutating func split() -> (send: NoiseCipherState, recv: NoiseCipherState) {
        let (send, recv) = core.split()
        return (NoiseCipherState(core: send), NoiseCipherState(core: recv))
    }

    // MARK: - Identity payload (adapter-owned)

    /// Builds the encoded ``NoisePayload`` bytes for an outbound message: the
    /// libp2p identity key + a signature over the Noise static public key. The
    /// signature is produced by the multi-scheme `P2PCore` identity key.
    private func makeSignedPayloadBytes() throws -> [UInt8] {
        let staticPub = Data(localStaticKey.publicKey.rawRepresentation)
        let payload = try NoisePayload(keyPair: localKeyPair, noiseStaticPublicKey: staticPub)
        return [UInt8](payload.encode())
    }
}

/// Maps the core handshake error onto the adapter's public ``NoiseError``,
/// preserving the out-of-order / too-short / decryption semantics callers expect.
private func mapHandshakeCoreError(_ error: NoiseCryptoError) -> NoiseError {
    switch error {
    case .decryptionFailed:   return .decryptionFailed
    case .invalidPayload:     return .invalidPayload
    case .invalidSignature:   return .invalidSignature
    case .invalidKey:         return .invalidKey
    case .messageOutOfOrder:  return .messageOutOfOrder
    case .messageTooShort:    return .handshakeFailed("Noise message too short")
    case .nonceOverflow:      return .nonceOverflow
    case .cryptoFailure:      return .decryptionFailed
    }
}
