/// NoiseUpgrader - SecurityUpgrader implementation for Noise protocol
import Foundation
import NIOCore
import P2PCore
import P2PSecurity
import Crypto

/// Upgrades raw connections to secured connections using the Noise protocol.
///
/// Implements the Noise XX pattern with X25519 key agreement and
/// ChaCha20-Poly1305 encryption.
public final class NoiseUpgrader: SecurityUpgrader, Sendable {

    public var protocolID: String { "/noise" }

    public init() {}

    /// Upgrades a raw connection to a secured connection using Noise protocol.
    ///
    /// This is the protocol-conforming method that starts with an empty buffer.
    /// If you have remainder data from multistream-select, use the overload with `initialBuffer`.
    ///
    /// - Parameters:
    ///   - connection: The raw connection to upgrade
    ///   - localKeyPair: The local key pair for authentication
    ///   - role: Whether we initiated or are responding
    ///   - expectedPeer: The expected remote peer ID (optional)
    /// - Returns: A secured connection
    public func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection {
        try await secure(connection, localKeyPair: localKeyPair, as: role, expectedPeer: expectedPeer, initialBuffer: Data())
    }

    /// Upgrades a raw connection to a secured connection using Noise protocol with initial buffer.
    ///
    /// Use this method when you have remainder data from multistream-select negotiation.
    /// This prevents data loss when go-libp2p sends protocol confirmation and Noise message
    /// in the same packet.
    ///
    /// - Parameters:
    ///   - connection: The raw connection to upgrade
    ///   - localKeyPair: The local key pair for authentication
    ///   - role: Whether we initiated or are responding
    ///   - expectedPeer: The expected remote peer ID (optional)
    ///   - initialBuffer: Initial data buffer (e.g., remainder from multistream-select negotiation)
    /// - Returns: A secured connection
    public func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?,
        initialBuffer: Data
    ) async throws -> any SecuredConnection {
        let isInitiator = role == .initiator
        var handshake = NoiseHandshake(localKeyPair: localKeyPair, isInitiator: isInitiator)

        var readBuffer = initialBuffer
        let remotePeer: PeerID

        if isInitiator {
            remotePeer = try await performInitiatorHandshake(
                handshake: &handshake,
                connection: connection,
                expectedPeer: expectedPeer,
                readBuffer: &readBuffer
            )
        } else {
            remotePeer = try await performResponderHandshake(
                handshake: &handshake,
                connection: connection,
                expectedPeer: expectedPeer,
                readBuffer: &readBuffer
            )
        }

        // Split cipher states for transport
        let (sendCipher, recvCipher) = handshake.split()

        return NoiseConnection(
            underlying: connection,
            localPeer: localKeyPair.peerID,
            remotePeer: remotePeer,
            sendCipher: sendCipher,
            recvCipher: recvCipher,
            initialBuffer: readBuffer
        )
    }

    // MARK: - Initiator Handshake

    private func performInitiatorHandshake(
        handshake: inout NoiseHandshake,
        connection: any RawConnection,
        expectedPeer: PeerID?,
        readBuffer: inout Data
    ) async throws -> PeerID {
        // Send Message A: -> e
        let messageA = handshake.writeMessageA()
        let framedA = try encodeNoiseMessage(messageA)
        try await connection.write(ByteBuffer(bytes: framedA))

        // Read Message B: <- e, ee, s, es
        let messageB = try await readNoiseFrame(from: connection, buffer: &readBuffer)
        let payloadB = try handshake.readMessageB(messageB)

        // Verify remote identity
        guard let remoteStaticKey = handshake.remoteStaticKey else {
            throw NoiseError.handshakeFailed("No remote static key after Message B")
        }
        let remoteStaticData = Data(remoteStaticKey.rawRepresentation)
        let remotePeer = try payloadB.verify(noiseStaticPublicKey: remoteStaticData)

        // Check expected peer if specified
        if let expected = expectedPeer, expected != remotePeer {
            throw SecurityError.peerMismatch(expected: expected, actual: remotePeer)
        }

        // Send Message C: -> s, se
        let messageC = try handshake.writeMessageC()
        let framedC = try encodeNoiseMessage(messageC)
        try await connection.write(ByteBuffer(bytes: framedC))

        return remotePeer
    }

    // MARK: - Responder Handshake

    private func performResponderHandshake(
        handshake: inout NoiseHandshake,
        connection: any RawConnection,
        expectedPeer: PeerID?,
        readBuffer: inout Data
    ) async throws -> PeerID {
        // Read Message A: -> e
        let messageA = try await readNoiseFrame(from: connection, buffer: &readBuffer)
        try handshake.readMessageA(messageA)

        // Send Message B: <- e, ee, s, es
        let messageB = try handshake.writeMessageB()
        let framedB = try encodeNoiseMessage(messageB)
        try await connection.write(ByteBuffer(bytes: framedB))

        // Read Message C: -> s, se
        let messageC = try await readNoiseFrame(from: connection, buffer: &readBuffer)
        let payloadC = try handshake.readMessageC(messageC)

        // Verify remote identity
        guard let remoteStaticKey = handshake.remoteStaticKey else {
            throw NoiseError.handshakeFailed("No remote static key after Message C")
        }
        let remoteStaticData = Data(remoteStaticKey.rawRepresentation)
        let remotePeer = try payloadC.verify(noiseStaticPublicKey: remoteStaticData)

        // Check expected peer if specified
        if let expected = expectedPeer, expected != remotePeer {
            throw SecurityError.peerMismatch(expected: expected, actual: remotePeer)
        }

        return remotePeer
    }

    // MARK: - Helpers

    /// Reads a complete Noise frame from the connection with buffering.
    private func readNoiseFrame(
        from connection: any RawConnection,
        buffer: inout Data
    ) async throws -> Data {
        while true {
            // Try to decode a complete frame
            if let (message, consumed) = try readNoiseMessage(from: buffer) {
                buffer = Data(buffer.dropFirst(consumed))
                return message
            }

            // Need more data
            let chunk = try await connection.read()
            if chunk.readableBytes == 0 {
                throw NoiseError.connectionClosed
            }
            buffer.append(Data(buffer: chunk))
        }
    }
}
