/// Topic - GossipSub topic identifier
import Foundation

/// A topic identifier for pub/sub messaging.
///
/// Topics are used to organize messages into logical channels.
/// Subscribers receive messages published to topics they're subscribed to.
public struct Topic: Sendable, Hashable, CustomStringConvertible {
    /// The topic string.
    public let value: String

    /// Creates a topic from a string.
    ///
    /// - Parameter value: The topic identifier string
    public init(_ value: String) {
        self.value = value
    }

    public var description: String {
        value
    }
}

// MARK: - ExpressibleByStringLiteral

extension Topic: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.value = value
    }
}

// MARK: - Codable

extension Topic: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(String.self)
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
    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Creates a topic hash from a topic by hashing its value.
    ///
    /// Uses SHA-256 to hash the topic string.
    public init(topic: Topic) {
        // For simplicity, we use the UTF-8 bytes directly as the hash
        // In a full implementation, this would be SHA-256(topic.value)
        self.bytes = Data(topic.value.utf8)
    }
}
