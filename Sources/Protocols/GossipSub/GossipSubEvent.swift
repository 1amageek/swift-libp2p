/// GossipSubEvent - Event types for GossipSub protocol
import Foundation
import P2PCore

/// Events emitted by the GossipSub protocol.
public enum GossipSubEvent: Sendable {
    // MARK: - Subscription Events

    /// Successfully subscribed to a topic.
    case subscribed(topic: Topic)

    /// Successfully unsubscribed from a topic.
    case unsubscribed(topic: Topic)

    // MARK: - Message Events

    /// Received a message on a topic.
    case messageReceived(topic: Topic, message: GossipSubMessage)

    /// Successfully published a message.
    case messagePublished(topic: Topic, messageID: MessageID)

    /// Message validation completed.
    case messageValidated(messageID: MessageID, result: GossipSubMessage.ValidationResult)

    /// Message forwarded to a mesh peer.
    case messageForwarded(peer: PeerID, topic: Topic, messageID: MessageID)

    // MARK: - Mesh Events

    /// A peer joined our mesh for a topic.
    case peerJoinedMesh(peer: PeerID, topic: Topic)

    /// A peer left our mesh for a topic.
    case peerLeftMesh(peer: PeerID, topic: Topic)

    /// We grafted into a peer's mesh.
    case grafted(peer: PeerID, topic: Topic)

    /// We were pruned from a peer's mesh.
    case pruned(peer: PeerID, topic: Topic, backoff: Duration?)

    // MARK: - Gossip Events

    /// Received IHAVE announcement from peer.
    case ihaveReceived(peer: PeerID, topic: Topic, messageCount: Int)

    /// Sent IWANT request to peer.
    case iwantSent(peer: PeerID, messageCount: Int)

    /// Message received via IWANT response.
    case messageReceivedViaGossip(messageID: MessageID, from: PeerID)

    // MARK: - Peer Events

    /// A peer subscribed to a topic.
    case peerSubscribed(peer: PeerID, topic: Topic)

    /// A peer unsubscribed from a topic.
    case peerUnsubscribed(peer: PeerID, topic: Topic)

    /// Peer score updated.
    case peerScoreUpdated(peer: PeerID, score: Double)

    /// Peer was penalized.
    case peerPenalized(peer: PeerID, reason: PenaltyReason, score: Double)

    // MARK: - Connection Events

    /// A new peer connected.
    case peerConnected(peer: PeerID)

    /// A peer disconnected.
    case peerDisconnected(peer: PeerID)

    // MARK: - Heartbeat Events

    /// Heartbeat completed.
    case heartbeat(
        meshPeers: Int,
        grafts: Int,
        prunes: Int,
        gossipSent: Int
    )

    // MARK: - Error Events

    /// An error occurred.
    case error(GossipSubError)
}

// MARK: - PenaltyReason

extension GossipSubEvent {
    /// Reasons for peer penalties.
    public enum PenaltyReason: Sendable {
        /// Sent an invalid message.
        case invalidMessage
        /// Sent a duplicate message.
        case duplicateMessage
        /// Sent too many IWANT requests.
        case excessiveIWant
        /// Broke promise (IHAVE but no message).
        case brokenPromise
        /// Spamming subscriptions.
        case subscriptionSpam
        /// Sent message to wrong topic.
        case topicMismatch
        /// Generic protocol violation.
        case protocolViolation(String)
    }
}
