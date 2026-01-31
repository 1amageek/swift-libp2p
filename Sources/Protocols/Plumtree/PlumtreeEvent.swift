/// PlumtreeEvent - Event types emitted by the Plumtree protocol
import P2PCore

/// Events emitted by the Plumtree protocol for monitoring and debugging.
public enum PlumtreeEvent: Sendable {

    // MARK: - Message Events

    /// A new message was received and delivered to subscribers.
    case messageReceived(topic: String, messageID: PlumtreeMessageID, source: PeerID)

    /// A message was published locally.
    case messagePublished(topic: String, messageID: PlumtreeMessageID)

    /// A duplicate message was received.
    case messageDuplicate(messageID: PlumtreeMessageID, from: PeerID)

    // MARK: - Tree Events

    /// A peer was added to the eager set (tree link established).
    case peerAddedToEager(peer: PeerID, topic: String)

    /// A peer was moved to the lazy set (tree link removed).
    case peerMovedToLazy(peer: PeerID, topic: String)

    /// A GRAFT was sent to a peer (promoting to eager).
    case graftSent(peer: PeerID, topic: String, messageID: PlumtreeMessageID?)

    /// A GRAFT was received from a peer.
    case graftReceived(peer: PeerID, topic: String)

    /// A PRUNE was sent to a peer (demoting to lazy).
    case pruneSent(peer: PeerID, topic: String)

    /// A PRUNE was received from a peer.
    case pruneReceived(peer: PeerID, topic: String)

    // MARK: - IHave Events

    /// An IHave timeout fired, triggering a GRAFT.
    case ihaveTimeout(peer: PeerID, messageID: PlumtreeMessageID, topic: String)

    // MARK: - Peer Events

    /// A peer connected to the Plumtree overlay.
    case peerConnected(peer: PeerID)

    /// A peer disconnected from the Plumtree overlay.
    case peerDisconnected(peer: PeerID)
}
