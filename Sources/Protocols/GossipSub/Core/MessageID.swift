/// MessageID - Unique identifier for GossipSub messages
import Foundation
import Crypto
import P2PCore

/// A unique identifier for a GossipSub message.
///
/// Message IDs are used for deduplication and gossip protocol operations (IHAVE/IWANT).
/// By default, the ID is computed from the message source and sequence number.
///
/// Hash value is pre-computed at initialization using FNV-1a for O(1) Dictionary/Set operations.
public struct MessageID: Sendable, Hashable, CustomStringConvertible {
    /// The raw bytes of the message ID.
    public let bytes: Data

    /// Pre-computed hash value (FNV-1a).
    private let _hashValue: Int

    /// Creates a message ID from raw bytes.
    ///
    /// - Parameter bytes: The raw message ID bytes
    public init(bytes: Data) {
        self.bytes = bytes
        // FNV-1a hash: compute once, use for every Dictionary/Set operation
        var h: UInt64 = 14695981039346656037  // FNV offset basis
        for byte in bytes {
            h ^= UInt64(byte)
            h &*= 1099511628211  // FNV prime
        }
        self._hashValue = Int(bitPattern: UInt(h))
    }

    /// Creates a message ID from a hex string.
    ///
    /// - Parameter hex: The hex-encoded message ID
    public init?(hex: String) {
        guard let data = Data(hexString: hex) else {
            return nil
        }
        self.init(bytes: data)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(_hashValue)
    }

    public static func == (lhs: MessageID, rhs: MessageID) -> Bool {
        lhs._hashValue == rhs._hashValue && lhs.bytes == rhs.bytes
    }

    public var description: String {
        bytes.hexEncodedString()
    }
}

// MARK: - Default Message ID Function

extension MessageID {
    /// Computes the default message ID from source and sequence number.
    ///
    /// The default ID is: source_peer_id || sequence_number
    ///
    /// - Parameters:
    ///   - source: The source peer ID (optional)
    ///   - sequenceNumber: The message sequence number
    /// - Returns: The computed message ID
    public static func compute(source: PeerID?, sequenceNumber: Data) -> MessageID {
        var bytes = Data()
        if let source = source {
            bytes.append(source.bytes)
        }
        bytes.append(sequenceNumber)
        return MessageID(bytes: bytes)
    }

    /// Computes a message ID by hashing the message data.
    ///
    /// This is an alternative ID function that uses the hash of the message content.
    /// Uses SHA-256 for deterministic, cryptographically secure hashing that
    /// produces consistent IDs across different nodes/processes.
    ///
    /// - Parameter data: The message data
    /// - Returns: The computed message ID (first 20 bytes of SHA-256 hash)
    public static func computeFromHash(_ data: Data) -> MessageID {
        // Use first 20 bytes of SHA-256 hash
        // This matches the default message ID length used by go-libp2p and rust-libp2p
        let digest = SHA256.hash(data: data)
        let hashBytes = Data(digest.prefix(20))
        return MessageID(bytes: hashBytes)
    }
}

// MARK: - Codable

extension MessageID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let data = try container.decode(Data.self)
        self.init(bytes: data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

// MARK: - Data Hex Extension

private extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
