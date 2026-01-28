/// P2PSecurityPlaintext - Plaintext security for testing
///
/// WARNING: This provides NO encryption. For testing only.
import Foundation
import P2PCore
import P2PSecurity

/// Plaintext security upgrader for testing.
///
/// This implements the plaintext 2.0.0 protocol which exchanges
/// peer IDs and public keys without encryption.
public final class PlaintextUpgrader: SecurityUpgrader, Sendable {

    public var protocolID: String { "/plaintext/2.0.0" }

    public init() {}

    public func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection {
        let localPeer = localKeyPair.peerID
        let localExchange = Exchange(
            peerID: localPeer,
            publicKey: localKeyPair.publicKey
        )

        // Send our exchange message
        let localMessage = localExchange.encode()
        try await connection.write(localMessage)

        // Read remote exchange message with proper buffering
        let (remoteData, remainder) = try await readLengthPrefixedMessage(from: connection)
        let remoteExchange = try Exchange.decode(from: remoteData)

        // Verify the remote peer's public key matches their claimed ID
        let derivedPeerID = PeerID(publicKey: remoteExchange.publicKey)
        guard derivedPeerID == remoteExchange.peerID else {
            throw SecurityError.handshakeFailed(
                underlying: PlaintextError.peerIDMismatch
            )
        }

        // Verify against expected peer if specified
        if let expected = expectedPeer {
            guard remoteExchange.peerID == expected else {
                throw SecurityError.peerMismatch(
                    expected: expected,
                    actual: remoteExchange.peerID
                )
            }
        }

        // Pass any remaining data to the connection as initial buffer
        return PlaintextConnection(
            underlying: connection,
            localPeer: localPeer,
            remotePeer: remoteExchange.peerID,
            initialBuffer: remainder
        )
    }
}

// MARK: - Exchange Message

/// The plaintext exchange message.
public struct Exchange: Sendable {
    public let peerID: PeerID
    public let publicKey: PublicKey

    public init(peerID: PeerID, publicKey: PublicKey) {
        self.peerID = peerID
        self.publicKey = publicKey
    }

    /// Encodes the exchange message with length prefix.
    public func encode() -> Data {
        var proto = Data()
        proto.append(encodeProtobufField(fieldNumber: 1, data: peerID.bytes))
        proto.append(encodeProtobufField(fieldNumber: 2, data: publicKey.protobufEncoded))

        // Prefix with varint length
        var result = Data()
        result.append(contentsOf: Varint.encode(UInt64(proto.count)))
        result.append(proto)
        return result
    }

    /// Decodes an exchange message from length-prefixed data.
    public static func decode(from data: Data) throws -> Exchange {
        let (length, lengthBytes) = try Varint.decode(data)
        let remaining = data.dropFirst(lengthBytes)

        guard remaining.count >= length else {
            throw PlaintextError.insufficientData
        }

        let protoData = Data(remaining.prefix(Int(length)))

        let fields: [ProtobufField]
        do {
            fields = try decodeProtobufFields(from: protoData)
        } catch {
            throw PlaintextError.invalidExchange
        }

        var peerIDBytes: Data?
        var pubkeyBytes: Data?

        for field in fields {
            switch field.fieldNumber {
            case 1: peerIDBytes = field.data
            case 2: pubkeyBytes = field.data
            default: break
            }
        }

        guard let idBytes = peerIDBytes,
              let keyBytes = pubkeyBytes else {
            throw PlaintextError.invalidExchange
        }

        return Exchange(
            peerID: try PeerID(bytes: idBytes),
            publicKey: try PublicKey(protobufEncoded: keyBytes)
        )
    }
}

// MARK: - PlaintextError

public enum PlaintextError: Error, Sendable {
    case insufficientData
    case invalidExchange
    case peerIDMismatch
    case messageTooLarge
}

// MARK: - Buffered Reading

/// Maximum size for a plaintext handshake message (64KB).
/// A plaintext exchange contains PeerID + PublicKey, which is well under 1KB.
/// This generous limit provides DoS protection against oversized messages.
private let maxPlaintextHandshakeSize = 64 * 1024

/// Reads a length-prefixed message from a connection.
///
/// This properly handles TCP stream semantics by buffering until the
/// complete message is received. Returns both the message and any
/// remaining data that was read but not part of the message.
///
/// - Returns: A tuple of (message data, remainder data)
private func readLengthPrefixedMessage(from connection: any RawConnection) async throws -> (message: Data, remainder: Data) {
    var buffer = Data()

    // Read until we have the complete message
    while true {
        // Try to decode varint length
        if !buffer.isEmpty {
            do {
                let (length, lengthBytes) = try Varint.decode(buffer)

                // Validate message size to prevent memory exhaustion
                guard length <= UInt64(maxPlaintextHandshakeSize) else {
                    throw PlaintextError.messageTooLarge
                }

                let totalNeeded = lengthBytes + Int(length)

                // Check if we have enough data
                if buffer.count >= totalNeeded {
                    let message = Data(buffer.prefix(totalNeeded))
                    let remainder = Data(buffer.dropFirst(totalNeeded))
                    return (message, remainder)
                }
            } catch VarintError.insufficientData {
                // Need more data for varint
            }
        }

        // Read more data
        let chunk = try await connection.read()
        if chunk.isEmpty {
            throw PlaintextError.insufficientData
        }
        buffer.append(chunk)
    }
}
