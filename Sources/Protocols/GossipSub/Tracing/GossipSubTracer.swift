/// GossipSubTracer - Protocol for tracing GossipSub message flow.
///
/// Implementations receive callbacks for significant GossipSub events
/// such as peer management, mesh operations, and message delivery.
/// This enables observability, debugging, and metrics collection.
import Foundation
import P2PCore

/// Protocol for tracing GossipSub protocol operations.
///
/// Conforming types receive notifications about peer lifecycle,
/// mesh topology changes, and message flow events.
///
/// All methods are synchronous to minimize overhead in the
/// high-frequency message path. Implementations must not block.
public protocol GossipSubTracer: Sendable {

    /// Called when a new peer is added to the GossipSub router.
    ///
    /// - Parameters:
    ///   - peer: The peer that was added
    ///   - proto: The negotiated protocol string
    func addPeer(_ peer: PeerID, protocol proto: String)

    /// Called when a peer is removed from the GossipSub router.
    ///
    /// - Parameter peer: The peer that was removed
    func removePeer(_ peer: PeerID)

    /// Called when the local node joins a topic mesh.
    ///
    /// - Parameter topic: The topic being joined
    func join(topic: String)

    /// Called when the local node leaves a topic mesh.
    ///
    /// - Parameter topic: The topic being left
    func leave(topic: String)

    /// Called when a peer is grafted into a topic mesh.
    ///
    /// - Parameters:
    ///   - peer: The grafted peer
    ///   - topic: The topic of the mesh
    func graft(peer: PeerID, topic: String)

    /// Called when a peer is pruned from a topic mesh.
    ///
    /// - Parameters:
    ///   - peer: The pruned peer
    ///   - topic: The topic of the mesh
    func prune(peer: PeerID, topic: String)

    /// Called when a message is successfully delivered to the application.
    ///
    /// - Parameters:
    ///   - id: The message ID bytes
    ///   - topic: The topic the message was delivered on
    ///   - from: The peer the message was received from
    ///   - size: The size of the message payload in bytes
    func deliverMessage(id: Data, topic: String, from: PeerID, size: Int)

    /// Called when a message is rejected.
    ///
    /// - Parameters:
    ///   - id: The message ID bytes
    ///   - topic: The topic of the rejected message
    ///   - from: The peer that sent the rejected message
    ///   - reason: The reason for rejection
    func rejectMessage(id: Data, topic: String, from: PeerID, reason: RejectReason)

    /// Called when a duplicate message is received.
    ///
    /// - Parameters:
    ///   - id: The message ID bytes
    ///   - topic: The topic of the duplicate message
    ///   - from: The peer that sent the duplicate
    func duplicateMessage(id: Data, topic: String, from: PeerID)

    /// Called when a message is published by the local node.
    ///
    /// - Parameters:
    ///   - id: The message ID bytes
    ///   - topic: The topic the message was published to
    func publishMessage(id: Data, topic: String)
}

/// Reasons why a message may be rejected.
public enum RejectReason: String, Sendable {
    /// The message source peer is blacklisted.
    case blacklisted

    /// Application-level validation failed.
    case validationFailed

    /// Validation was throttled due to rate limiting.
    case validationThrottled

    /// The message signature is invalid.
    case invalidSignature

    /// The message originated from the local node (self-origin).
    case selfOrigin
}
