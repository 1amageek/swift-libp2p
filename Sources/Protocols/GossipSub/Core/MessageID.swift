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
    @usableFromInline
    internal static let fnvOffsetBasis: UInt64 = 14695981039346656037
    @usableFromInline
    internal static let fnvPrime: UInt64 = 1099511628211

    /// The raw bytes of the message ID.
    public let bytes: Data

    /// Pre-computed hash value (FNV-1a).
    @usableFromInline
    internal let _hashValue: Int

    /// Creates a message ID from raw bytes.
    ///
    /// - Parameter bytes: The raw message ID bytes
    @inlinable
    public init(bytes: Data) {
        self.bytes = bytes
        var hash = Self.fnvOffsetBasis
        bytes.withUnsafeBytes { rawBuffer in
            Self.updateHash(&hash, with: rawBuffer)
        }
        self._hashValue = Self.finalizeHash(hash)
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

    @inlinable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_hashValue)
    }

    @inlinable
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
    @inlinable
    public static func compute(source: PeerID?, sequenceNumber: Data) -> MessageID {
        let sourceBytes = source?.bytes
        var bytes = Data()
        bytes.reserveCapacity((sourceBytes?.count ?? 0) + sequenceNumber.count)

        var hash = Self.fnvOffsetBasis
        if let sourceBytes {
            bytes.append(sourceBytes)
            Self.updateHash(&hash, with: sourceBytes)
        }
        bytes.append(sequenceNumber)
        Self.updateHash(&hash, with: sequenceNumber)

        return MessageID(bytes: bytes, precomputedHash: hash)
    }

    /// Computes a message ID by hashing the message data.
    ///
    /// This is an alternative ID function that uses the hash of the message content.
    /// Uses SHA-256 for deterministic, cryptographically secure hashing that
    /// produces consistent IDs across different nodes/processes.
    ///
    /// - Parameter data: The message data
    /// - Returns: The computed message ID (first 20 bytes of SHA-256 hash)
    @inlinable
    public static func computeFromHash(_ data: Data) -> MessageID {
        let digest = SHA256.hash(data: data)
        return digest.withUnsafeBytes { rawBuffer in
            let prefix = UnsafeRawBufferPointer(rebasing: rawBuffer[..<20])
            var hash = Self.fnvOffsetBasis
            Self.updateHash(&hash, with: prefix)
            let hashBytes = Data(prefix)
            return MessageID(bytes: hashBytes, precomputedHash: hash)
        }
    }
}

// MARK: - Internal Helpers

internal extension MessageID {
    @inlinable
    init(bytes: Data, precomputedHash: UInt64) {
        self.bytes = bytes
        self._hashValue = Self.finalizeHash(precomputedHash)
    }

    @inlinable
    static func updateHash(_ hash: inout UInt64, with bytes: Data) {
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= Self.fnvPrime
        }
    }

    @inlinable
    static func updateHash(_ hash: inout UInt64, with bytes: UnsafeRawBufferPointer) {
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= Self.fnvPrime
        }
    }

    @inlinable
    static func finalizeHash(_ hash: UInt64) -> Int {
        Int(bitPattern: UInt(truncatingIfNeeded: hash))
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
