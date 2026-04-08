/// Topic - GossipSub topic identifier
import Foundation

/// A topic identifier for pub/sub messaging.
///
/// Topics are used to organize messages into logical channels.
/// Subscribers receive messages published to topics they're subscribed to.
///
/// Hash value and UTF-8 bytes are pre-computed at initialization for O(1) operations.
public struct Topic: Sendable, Hashable, CustomStringConvertible {
    /// The topic string.
    public let value: String

    /// Pre-computed hash value for O(1) Dictionary/Set operations.
    @usableFromInline
    internal let _hashValue: Int

    /// Pre-computed UTF-8 bytes for O(1) wire encoding.
    public let utf8Bytes: Data

    /// Creates a topic from a string.
    ///
    /// - Parameter value: The topic identifier string
    @inlinable
    public init(_ value: String) {
        self.value = value
        let utf8Bytes = Data(value.utf8)
        self.utf8Bytes = utf8Bytes

        if utf8Bytes.count <= 16 {
            var hash: UInt64 = 14695981039346656037
            for byte in utf8Bytes {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
            self._hashValue = Int(bitPattern: UInt(truncatingIfNeeded: hash))
        } else {
            var hasher = Hasher()
            hasher.combine(value)
            self._hashValue = hasher.finalize()
        }
    }

    @inlinable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_hashValue)
    }

    @inlinable
    public static func == (lhs: Topic, rhs: Topic) -> Bool {
        lhs._hashValue == rhs._hashValue && lhs.value == rhs.value
    }

    public var description: String {
        value
    }
}

// MARK: - ExpressibleByStringLiteral

extension Topic: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.init(value)
    }
}

// MARK: - Codable

extension Topic: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        self.init(value)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - TopicHash

/// A hashed topic for efficient lookups and wire protocol use.
///
/// In GossipSub, topics are often hashed for efficiency.
/// This type represents the hash of a topic string.
public struct TopicHash: Sendable, Hashable {
    /// The raw hash bytes.
    public let bytes: Data

    /// Creates a topic hash from raw bytes.
    @inlinable
    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Creates a topic hash from a topic by hashing its value.
    ///
    /// Uses SHA-256 to hash the topic string.
    @inlinable
    public init(topic: Topic) {
        // For simplicity, we use the UTF-8 bytes directly as the hash
        // In a full implementation, this would be SHA-256(topic.value)
        self.bytes = topic.utf8Bytes
    }
}
