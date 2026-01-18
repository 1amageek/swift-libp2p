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
        // Simple protobuf encoding:
        // Field 1 (id): bytes
        // Field 2 (pubkey): bytes
        var proto = Data()

        // Field 1: PeerID bytes
        let idBytes = peerID.bytes
        proto.append(0x0A) // (1 << 3) | 2 = length-delimited
        proto.append(contentsOf: Varint.encode(UInt64(idBytes.count)))
        proto.append(idBytes)

        // Field 2: PublicKey protobuf
        let pubkeyBytes = publicKey.protobufEncoded
        proto.append(0x12) // (2 << 3) | 2 = length-delimited
        proto.append(contentsOf: Varint.encode(UInt64(pubkeyBytes.count)))
        proto.append(pubkeyBytes)

        // Prefix with length
        var result = Data()
        result.append(contentsOf: Varint.encode(UInt64(proto.count)))
        result.append(proto)

        return result
    }

    /// Decodes an exchange message from length-prefixed data.
    public static func decode(from data: Data) throws -> Exchange {
        // Read length prefix
        let (length, lengthBytes) = try Varint.decode(data)
        let remaining = data.dropFirst(lengthBytes)

        guard remaining.count >= length else {
            throw PlaintextError.insufficientData
        }

        // Parse protobuf fields
        var peerIDBytes: Data?
        var pubkeyBytes: Data?

        let protoEnd = remaining.startIndex.advanced(by: Int(length))
        var protoData = remaining[remaining.startIndex..<protoEnd]

        while !protoData.isEmpty {
            let (fieldTag, tagBytes) = try Varint.decode(Data(protoData))
            protoData = protoData.dropFirst(tagBytes)

            let fieldNumber = fieldTag >> 3

            // All fields are length-delimited bytes
            let (fieldLength, fieldLengthBytes) = try Varint.decode(Data(protoData))
            protoData = protoData.dropFirst(fieldLengthBytes)

            guard protoData.count >= fieldLength else {
                throw PlaintextError.insufficientData
            }

            let fieldData = Data(protoData.prefix(Int(fieldLength)))
            protoData = protoData.dropFirst(Int(fieldLength))

            switch fieldNumber {
            case 1:
                peerIDBytes = fieldData
            case 2:
                pubkeyBytes = fieldData
            default:
                // Skip unknown fields
                break
            }
        }

        guard let idBytes = peerIDBytes,
              let keyBytes = pubkeyBytes else {
            throw PlaintextError.invalidExchange
        }

        let peerID = try PeerID(bytes: idBytes)
        let publicKey = try PublicKey(protobufEncoded: keyBytes)

        return Exchange(peerID: peerID, publicKey: publicKey)
    }
}

// MARK: - PlaintextError

public enum PlaintextError: Error, Sendable {
    case insufficientData
    case invalidExchange
    case peerIDMismatch
}

// MARK: - Buffered Reading

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
