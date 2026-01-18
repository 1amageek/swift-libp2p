/// GossipSubError - Error types for GossipSub protocol
import Foundation
import P2PCore

/// Errors that can occur in the GossipSub protocol.
public enum GossipSubError: Error, Sendable {
    /// Invalid protobuf encoding/decoding.
    case invalidProtobuf(String)

    /// Peer is not connected.
    case peerNotConnected(PeerID)

    /// Peer is not subscribed to the topic.
    case peerNotSubscribed(peer: PeerID, topic: Topic)

    /// Topic is not subscribed locally.
    case notSubscribed(Topic)

    /// Already subscribed to the topic.
    case alreadySubscribed(Topic)

    /// Message validation failed.
    case messageValidationFailed(GossipSubMessage.ValidationResult)

    /// Message is a duplicate.
    case duplicateMessage(MessageID)

    /// Message cache full.
    case cacheFull

    /// Stream error.
    case streamError(String)

    /// Timeout error.
    case timeout

    /// Peer score below threshold.
    case peerScoreBelowThreshold(peer: PeerID, score: Double)

    /// Backoff period not elapsed.
    case backoffNotElapsed(peer: PeerID, topic: Topic, remaining: Duration)

    /// Max subscriptions reached.
    case maxSubscriptionsReached(limit: Int)

    /// Max peers in mesh reached.
    case meshFull(topic: Topic, limit: Int)

    /// Unknown topic.
    case unknownTopic(Topic)

    /// Message too large.
    case messageTooLarge(size: Int, maxSize: Int)

    /// Malformed message.
    case malformedMessage(String)

    /// Internal error.
    case internalError(String)
}

// MARK: - LocalizedError

extension GossipSubError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidProtobuf(let message):
            return "Invalid protobuf: \(message)"
        case .peerNotConnected(let peer):
            return "Peer not connected: \(peer)"
        case .peerNotSubscribed(let peer, let topic):
            return "Peer \(peer) not subscribed to topic \(topic)"
        case .notSubscribed(let topic):
            return "Not subscribed to topic: \(topic)"
        case .alreadySubscribed(let topic):
            return "Already subscribed to topic: \(topic)"
        case .messageValidationFailed(let result):
            return "Message validation failed: \(result)"
        case .duplicateMessage(let id):
            return "Duplicate message: \(id)"
        case .cacheFull:
            return "Message cache full"
        case .streamError(let message):
            return "Stream error: \(message)"
        case .timeout:
            return "Operation timed out"
        case .peerScoreBelowThreshold(let peer, let score):
            return "Peer \(peer) score \(score) below threshold"
        case .backoffNotElapsed(let peer, let topic, let remaining):
            return "Backoff not elapsed for peer \(peer) on topic \(topic), \(remaining) remaining"
        case .maxSubscriptionsReached(let limit):
            return "Maximum subscriptions reached: \(limit)"
        case .meshFull(let topic, let limit):
            return "Mesh full for topic \(topic): \(limit) peers"
        case .unknownTopic(let topic):
            return "Unknown topic: \(topic)"
        case .messageTooLarge(let size, let maxSize):
            return "Message too large: \(size) bytes (max: \(maxSize))"
        case .malformedMessage(let message):
            return "Malformed message: \(message)"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
