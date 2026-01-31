/// PlumtreeRouter - Core state machine for Plumtree protocol
///
/// Manages eager/lazy peer sets, message deduplication, and the
/// epidemic broadcast tree structure. Uses class + Mutex pattern
/// for high-frequency message routing operations.

import Foundation
import P2PCore
import Synchronization

// MARK: - Result Types

/// Result of handling an incoming gossip message.
public struct HandleGossipResult: Sendable {
    /// Events to emit.
    public var events: [PlumtreeEvent]
    /// The gossip to deliver to local subscribers (nil if duplicate).
    public var deliverToSubscribers: PlumtreeGossip?
    /// Eager peers to forward the full gossip to.
    public var forwardTo: [PeerID]
    /// Lazy peers to send IHave notifications to.
    public var lazyNotify: [PeerID]
    /// Whether to send a PRUNE back to the sender (duplicate case).
    public var pruneSender: Bool
}

/// Result of handling IHave notifications.
public struct HandleIHaveResult: Sendable {
    /// Events to emit.
    public var events: [PlumtreeEvent]
    /// IHave entries that need timeout timers started.
    public var startTimers: [(messageID: PlumtreeMessageID, peer: PeerID, topic: String)]
}

/// Result of handling a GRAFT request.
public struct HandleGraftResult: Sendable {
    /// Events to emit.
    public var events: [PlumtreeEvent]
    /// Messages to re-send to the grafting peer.
    public var reSendMessages: [PlumtreeGossip]
}

/// Result of handling a PRUNE request.
public struct HandlePruneResult: Sendable {
    /// Events to emit.
    public var events: [PlumtreeEvent]
}

/// Result of handling an IHave timeout.
public struct IHaveTimeoutResult: Sendable {
    /// Events to emit.
    public var events: [PlumtreeEvent]
    /// The peer to GRAFT.
    public var graftPeer: PeerID
    /// The topic to GRAFT for.
    public var graftTopic: String
    /// The message to request via GRAFT.
    public var graftMessageID: PlumtreeMessageID
}

// MARK: - Router

/// The core Plumtree router managing the epidemic broadcast tree.
///
/// This is a pure state machine: methods take inputs and return results
/// describing what actions the service layer should perform. No I/O or
/// event emission happens inside the router — all side effects are
/// returned as result values.
public final class PlumtreeRouter: Sendable {

    private let state: Mutex<RouterState>
    private let configuration: PlumtreeConfiguration
    private let localPeerID: PeerID

    struct RouterState: Sendable {
        /// Per-topic eager peer sets (receive and forward full messages).
        var eagerPeers: [String: Set<PeerID>] = [:]
        /// Per-topic lazy peer sets (receive only IHave notifications).
        var lazyPeers: [String: Set<PeerID>] = [:]
        /// Subscribed topics.
        var subscribedTopics: Set<String> = []
        /// All connected peers.
        var connectedPeers: Set<PeerID> = []
        /// Seen message IDs for deduplication.
        var seenMessages: [PlumtreeMessageID: ContinuousClock.Instant] = [:]
        /// Message store for GRAFT re-sends.
        var messageStore: [PlumtreeMessageID: PlumtreeGossip] = [:]
        /// Pending IHave entries awaiting timeout.
        var pendingIHaves: [PlumtreeMessageID: PendingIHave] = [:]
    }

    struct PendingIHave: Sendable {
        let peer: PeerID
        let topic: String
        let receivedAt: ContinuousClock.Instant
    }

    /// Creates a new Plumtree router.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer ID
    ///   - configuration: Configuration parameters
    public init(localPeerID: PeerID, configuration: PlumtreeConfiguration) {
        self.localPeerID = localPeerID
        self.configuration = configuration
        self.state = Mutex(RouterState())
    }

    // MARK: - Subscription Management

    /// Subscribes to a topic.
    ///
    /// All connected peers are added to the eager set for this topic.
    public func subscribe(to topic: String) -> [PlumtreeEvent] {
        state.withLock { s -> [PlumtreeEvent] in
            guard s.subscribedTopics.insert(topic).inserted else { return [] }

            var events: [PlumtreeEvent] = []
            // Add all connected peers as eager for this topic
            for peer in s.connectedPeers {
                s.eagerPeers[topic, default: []].insert(peer)
                events.append(.peerAddedToEager(peer: peer, topic: topic))
            }
            return events
        }
    }

    /// Unsubscribes from a topic.
    public func unsubscribe(from topic: String) {
        state.withLock { s in
            s.subscribedTopics.remove(topic)
            s.eagerPeers.removeValue(forKey: topic)
            s.lazyPeers.removeValue(forKey: topic)
        }
    }

    /// Returns all subscribed topics.
    public var subscribedTopics: Set<String> {
        state.withLock { $0.subscribedTopics }
    }

    /// Whether the router is subscribed to a topic.
    public func isSubscribed(to topic: String) -> Bool {
        state.withLock { $0.subscribedTopics.contains(topic) }
    }

    // MARK: - Peer Management

    /// Handles a new peer connection.
    ///
    /// The peer is added to the eager set for all subscribed topics.
    public func handlePeerConnected(_ peerID: PeerID) -> [PlumtreeEvent] {
        state.withLock { s -> [PlumtreeEvent] in
            s.connectedPeers.insert(peerID)

            var events: [PlumtreeEvent] = []
            events.append(.peerConnected(peer: peerID))

            // Add to eager set for all subscribed topics
            for topic in s.subscribedTopics {
                s.eagerPeers[topic, default: []].insert(peerID)
                events.append(.peerAddedToEager(peer: peerID, topic: topic))
            }
            return events
        }
    }

    /// Handles a peer disconnection.
    ///
    /// The peer is removed from all eager and lazy sets.
    public func handlePeerDisconnected(_ peerID: PeerID) -> [PlumtreeEvent] {
        state.withLock { s -> [PlumtreeEvent] in
            s.connectedPeers.remove(peerID)

            // Remove from all topic sets
            for topic in s.subscribedTopics {
                s.eagerPeers[topic]?.remove(peerID)
                s.lazyPeers[topic]?.remove(peerID)
            }

            // Remove pending IHaves from this peer
            s.pendingIHaves = s.pendingIHaves.filter { $0.value.peer != peerID }

            return [.peerDisconnected(peer: peerID)]
        }
    }

    /// Returns all connected peers.
    public var connectedPeers: Set<PeerID> {
        state.withLock { $0.connectedPeers }
    }

    /// Returns the eager peers for a topic.
    public func eagerPeers(for topic: String) -> Set<PeerID> {
        state.withLock { $0.eagerPeers[topic] ?? [] }
    }

    /// Returns the lazy peers for a topic.
    public func lazyPeers(for topic: String) -> Set<PeerID> {
        state.withLock { $0.lazyPeers[topic] ?? [] }
    }

    // MARK: - Message Handling

    /// Handles an incoming gossip message.
    ///
    /// If the message is new:
    /// - Marks as seen
    /// - Returns eager peers for forwarding
    /// - Returns lazy peers for IHave notification
    ///
    /// If the message is a duplicate:
    /// - Moves sender to lazy set
    /// - Returns PRUNE indication
    public func handleGossip(_ gossip: PlumtreeGossip, from peer: PeerID) -> HandleGossipResult {
        state.withLock { s -> HandleGossipResult in
            var events: [PlumtreeEvent] = []

            // Check if we've seen this message
            if s.seenMessages[gossip.messageID] != nil {
                // Duplicate — move sender to lazy, indicate PRUNE
                if s.eagerPeers[gossip.topic]?.remove(peer) != nil {
                    s.lazyPeers[gossip.topic, default: []].insert(peer)
                    events.append(.peerMovedToLazy(peer: peer, topic: gossip.topic))
                }
                events.append(.messageDuplicate(messageID: gossip.messageID, from: peer))
                return HandleGossipResult(
                    events: events,
                    deliverToSubscribers: nil,
                    forwardTo: [],
                    lazyNotify: [],
                    pruneSender: true
                )
            }

            // New message — mark as seen
            s.seenMessages[gossip.messageID] = .now

            // Store for potential GRAFT re-sends
            s.messageStore[gossip.messageID] = gossip

            // Cancel any pending IHave for this message
            s.pendingIHaves.removeValue(forKey: gossip.messageID)

            // Only deliver/forward if subscribed
            guard s.subscribedTopics.contains(gossip.topic) else {
                return HandleGossipResult(
                    events: events,
                    deliverToSubscribers: nil,
                    forwardTo: [],
                    lazyNotify: [],
                    pruneSender: false
                )
            }

            events.append(.messageReceived(
                topic: gossip.topic,
                messageID: gossip.messageID,
                source: gossip.source
            ))

            // Forward to eager peers (excluding sender)
            var forwardTo: [PeerID] = []
            if let eagerSet = s.eagerPeers[gossip.topic] {
                forwardTo.reserveCapacity(eagerSet.count)
                for p in eagerSet where p != peer {
                    forwardTo.append(p)
                }
            }

            // Notify lazy peers (excluding sender)
            var lazyNotify: [PeerID] = []
            if let lazySet = s.lazyPeers[gossip.topic] {
                lazyNotify.reserveCapacity(lazySet.count)
                for p in lazySet where p != peer {
                    lazyNotify.append(p)
                }
            }

            return HandleGossipResult(
                events: events,
                deliverToSubscribers: gossip,
                forwardTo: forwardTo,
                lazyNotify: lazyNotify,
                pruneSender: false
            )
        }
    }

    /// Handles incoming IHave notifications.
    ///
    /// For each IHave referencing an unseen message, registers a pending
    /// timer. The service layer starts the actual timeout and calls
    /// `handleIHaveTimeout` when it fires.
    public func handleIHave(_ entries: [PlumtreeIHaveEntry], from peer: PeerID) -> HandleIHaveResult {
        state.withLock { s -> HandleIHaveResult in
            var startTimers: [(messageID: PlumtreeMessageID, peer: PeerID, topic: String)] = []

            for entry in entries {
                // Skip if already seen or already pending
                guard s.seenMessages[entry.messageID] == nil else { continue }
                guard s.pendingIHaves[entry.messageID] == nil else { continue }
                guard s.subscribedTopics.contains(entry.topic) else { continue }

                s.pendingIHaves[entry.messageID] = PendingIHave(
                    peer: peer,
                    topic: entry.topic,
                    receivedAt: .now
                )
                startTimers.append((entry.messageID, peer, entry.topic))
            }

            return HandleIHaveResult(events: [], startTimers: startTimers)
        }
    }

    /// Handles an IHave timeout.
    ///
    /// If the message referenced by the IHave is still unseen, moves
    /// the IHave sender to the eager set and returns a GRAFT indication.
    ///
    /// - Parameter messageID: The message ID that timed out
    /// - Returns: Result with GRAFT info, or nil if the message was already received
    public func handleIHaveTimeout(_ messageID: PlumtreeMessageID) -> IHaveTimeoutResult? {
        state.withLock { s -> IHaveTimeoutResult? in
            guard let pending = s.pendingIHaves.removeValue(forKey: messageID) else {
                return nil
            }

            // If the message was already received, no need to graft
            if s.seenMessages[messageID] != nil {
                return nil
            }

            // Move peer from lazy to eager
            let topic = pending.topic
            if s.lazyPeers[topic]?.remove(pending.peer) != nil {
                s.eagerPeers[topic, default: []].insert(pending.peer)
            } else {
                // Even if not in lazy set, add to eager
                s.eagerPeers[topic, default: []].insert(pending.peer)
            }

            return IHaveTimeoutResult(
                events: [
                    .ihaveTimeout(peer: pending.peer, messageID: messageID, topic: topic),
                    .peerAddedToEager(peer: pending.peer, topic: topic),
                ],
                graftPeer: pending.peer,
                graftTopic: topic,
                graftMessageID: messageID
            )
        }
    }

    /// Handles an incoming GRAFT request.
    ///
    /// Moves the requesting peer to the eager set and returns any
    /// requested messages for re-sending.
    public func handleGraft(_ graft: PlumtreeGraftRequest, from peer: PeerID) -> HandleGraftResult {
        state.withLock { s -> HandleGraftResult in
            var events: [PlumtreeEvent] = []
            let topic = graft.topic

            // Move peer from lazy to eager
            s.lazyPeers[topic]?.remove(peer)
            s.eagerPeers[topic, default: []].insert(peer)
            events.append(.graftReceived(peer: peer, topic: topic))
            events.append(.peerAddedToEager(peer: peer, topic: topic))

            // Re-send requested message if available
            var reSend: [PlumtreeGossip] = []
            if let msgID = graft.messageID, let stored = s.messageStore[msgID] {
                reSend.append(stored)
            }

            return HandleGraftResult(events: events, reSendMessages: reSend)
        }
    }

    /// Handles an incoming PRUNE request.
    ///
    /// Moves the requesting peer to the lazy set.
    public func handlePrune(_ prune: PlumtreePruneRequest, from peer: PeerID) -> HandlePruneResult {
        state.withLock { s -> HandlePruneResult in
            let topic = prune.topic
            s.eagerPeers[topic]?.remove(peer)
            s.lazyPeers[topic, default: []].insert(peer)

            return HandlePruneResult(events: [
                .pruneReceived(peer: peer, topic: topic),
                .peerMovedToLazy(peer: peer, topic: topic),
            ])
        }
    }

    // MARK: - Publishing

    /// Registers a locally published message.
    ///
    /// Marks the message as seen and stores it. Returns the eager
    /// and lazy peer lists for sending.
    public func registerPublished(
        _ gossip: PlumtreeGossip
    ) -> (eagerPeers: [PeerID], lazyPeers: [PeerID]) {
        state.withLock { s in
            s.seenMessages[gossip.messageID] = .now
            s.messageStore[gossip.messageID] = gossip

            let eager = Array(s.eagerPeers[gossip.topic] ?? [])
            let lazy = Array(s.lazyPeers[gossip.topic] ?? [])
            return (eager, lazy)
        }
    }

    // MARK: - Maintenance

    /// Cleans up expired seen messages and stored messages.
    ///
    /// Call periodically (e.g., every 30 seconds) to prevent unbounded growth.
    public func cleanup() {
        state.withLock { s in
            let now = ContinuousClock.Instant.now

            // Clean up seen messages
            let seenExpiry = configuration.seenTTL
            s.seenMessages = s.seenMessages.filter { _, instant in
                now - instant < seenExpiry
            }

            // Enforce seen cache size limit
            if s.seenMessages.count > configuration.maxSeenEntries {
                let sorted = s.seenMessages.sorted { $0.value < $1.value }
                let toRemove = s.seenMessages.count - configuration.maxSeenEntries
                for (key, _) in sorted.prefix(toRemove) {
                    s.seenMessages.removeValue(forKey: key)
                }
            }

            // Clean up message store
            let storeExpiry = configuration.messageStoreTTL
            s.messageStore = s.messageStore.filter { _, gossip in
                guard let seenAt = s.seenMessages[gossip.messageID] else { return false }
                return now - seenAt < storeExpiry
            }

            // Enforce message store size limit
            if s.messageStore.count > configuration.maxStoredMessages {
                let sorted = s.messageStore.sorted { a, b in
                    let aTime = s.seenMessages[a.key] ?? .now
                    let bTime = s.seenMessages[b.key] ?? .now
                    return aTime < bTime
                }
                let toRemove = s.messageStore.count - configuration.maxStoredMessages
                for (key, _) in sorted.prefix(toRemove) {
                    s.messageStore.removeValue(forKey: key)
                }
            }
        }
    }

    /// Shuts down the router, clearing all state.
    public func shutdown() {
        state.withLock { s in
            s.eagerPeers.removeAll()
            s.lazyPeers.removeAll()
            s.subscribedTopics.removeAll()
            s.connectedPeers.removeAll()
            s.seenMessages.removeAll()
            s.messageStore.removeAll()
            s.pendingIHaves.removeAll()
        }
    }

    // MARK: - Inspection (for testing)

    /// Returns the number of seen messages.
    var seenMessageCount: Int {
        state.withLock { $0.seenMessages.count }
    }

    /// Returns whether a message has been seen.
    func hasSeen(_ messageID: PlumtreeMessageID) -> Bool {
        state.withLock { $0.seenMessages[messageID] != nil }
    }

    /// Returns the number of stored messages.
    var storedMessageCount: Int {
        state.withLock { $0.messageStore.count }
    }

    /// Returns the number of pending IHave entries.
    var pendingIHaveCount: Int {
        state.withLock { $0.pendingIHaves.count }
    }
}
