/// MeshState - Mesh network state management for GossipSub
import Foundation
import P2PCore
import Synchronization

/// Manages the mesh network state for GossipSub topics.
final class MeshState: Sendable {

    // MARK: - Types

    /// State for a single topic's mesh.
    struct TopicMesh: Sendable {
        /// Peers in our mesh for this topic.
        var meshPeers: Set<PeerID>

        /// Peers in our fanout (for unsubscribed topics we publish to).
        var fanoutPeers: Set<PeerID>

        /// When we last published to this topic (for fanout TTL).
        var lastPublished: ContinuousClock.Instant?

        init() {
            self.meshPeers = []
            self.fanoutPeers = []
            self.lastPublished = nil
        }
    }

    // MARK: - State

    private struct State: Sendable {
        /// Topics we are subscribed to.
        var subscriptions: Set<Topic>

        /// Mesh state per topic.
        var meshes: [Topic: TopicMesh]

        init() {
            self.subscriptions = []
            self.meshes = [:]
        }
    }

    private let state: Mutex<State>

    // MARK: - Initialization

    init() {
        self.state = Mutex(State())
    }

    // MARK: - Subscription Management

    /// Result of a subscription attempt.
    enum SubscribeResult: Sendable {
        case success
        case alreadySubscribed
        case limitReached(Int)
    }

    /// Adds a topic subscription atomically with limit checking.
    ///
    /// - Parameters:
    ///   - topic: The topic to subscribe to
    ///   - maxSubscriptions: Maximum allowed subscriptions
    /// - Returns: Result indicating success or failure reason
    func trySubscribe(to topic: Topic, maxSubscriptions: Int) -> SubscribeResult {
        state.withLock { state in
            // Check if already subscribed
            if state.subscriptions.contains(topic) {
                return .alreadySubscribed
            }

            // Check limit
            if state.subscriptions.count >= maxSubscriptions {
                return .limitReached(maxSubscriptions)
            }

            // Subscribe
            state.subscriptions.insert(topic)
            if state.meshes[topic] == nil {
                state.meshes[topic] = TopicMesh()
            }
            return .success
        }
    }

    /// Adds a topic subscription (without checking limits).
    func subscribe(to topic: Topic) {
        state.withLock { state in
            state.subscriptions.insert(topic)
            if state.meshes[topic] == nil {
                state.meshes[topic] = TopicMesh()
            }
        }
    }

    /// Removes a topic subscription.
    ///
    /// - Returns: Mesh peers that were in the mesh for this topic (for PRUNE)
    @discardableResult
    func unsubscribe(from topic: Topic) -> Set<PeerID> {
        state.withLock { state in
            state.subscriptions.remove(topic)
            // Get and clear mesh peers (we're leaving the mesh)
            let meshPeers = state.meshes[topic]?.meshPeers ?? []
            state.meshes[topic]?.meshPeers.removeAll()
            // Keep fanout for potential future publishing
            return meshPeers
        }
    }

    /// Checks if we are subscribed to a topic.
    func isSubscribed(to topic: Topic) -> Bool {
        state.withLock { $0.subscriptions.contains(topic) }
    }

    /// Returns all subscribed topics.
    var subscribedTopics: [Topic] {
        state.withLock { Array($0.subscriptions) }
    }

    // MARK: - Mesh Management

    /// Adds a peer to the mesh for a topic.
    ///
    /// - Returns: True if the peer was added (not already in mesh)
    @discardableResult
    func addToMesh(_ peer: PeerID, for topic: Topic) -> Bool {
        state.withLock { state in
            if state.meshes[topic] == nil {
                state.meshes[topic] = TopicMesh()
            }
            let (inserted, _) = state.meshes[topic]!.meshPeers.insert(peer)
            // Remove from fanout if present
            state.meshes[topic]!.fanoutPeers.remove(peer)
            return inserted
        }
    }

    /// Removes a peer from the mesh for a topic.
    ///
    /// - Returns: True if the peer was removed (was in mesh)
    @discardableResult
    func removeFromMesh(_ peer: PeerID, for topic: Topic) -> Bool {
        state.withLock { state in
            guard var mesh = state.meshes[topic] else { return false }
            let removed = mesh.meshPeers.remove(peer) != nil
            state.meshes[topic] = mesh
            return removed
        }
    }

    /// Checks if a peer is in our mesh for a topic.
    func isInMesh(_ peer: PeerID, for topic: Topic) -> Bool {
        state.withLock { $0.meshes[topic]?.meshPeers.contains(peer) ?? false }
    }

    /// Returns peers in our mesh for a topic.
    func meshPeers(for topic: Topic) -> Set<PeerID> {
        state.withLock { $0.meshes[topic]?.meshPeers ?? [] }
    }

    /// Returns the number of peers in mesh for a topic.
    func meshPeerCount(for topic: Topic) -> Int {
        state.withLock { $0.meshes[topic]?.meshPeers.count ?? 0 }
    }

    /// Returns all mesh peers across all topics.
    var allMeshPeers: Set<PeerID> {
        state.withLock { state in
            var all = Set<PeerID>()
            for mesh in state.meshes.values {
                all.formUnion(mesh.meshPeers)
            }
            return all
        }
    }

    // MARK: - Fanout Management

    /// Adds a peer to the fanout for a topic.
    func addToFanout(_ peer: PeerID, for topic: Topic) {
        state.withLock { state in
            if state.meshes[topic] == nil {
                state.meshes[topic] = TopicMesh()
            }
            // Don't add to fanout if already in mesh
            guard !state.meshes[topic]!.meshPeers.contains(peer) else { return }
            state.meshes[topic]!.fanoutPeers.insert(peer)
        }
    }

    /// Removes a peer from the fanout for a topic.
    func removeFromFanout(_ peer: PeerID, for topic: Topic) {
        _ = state.withLock { state in
            state.meshes[topic]?.fanoutPeers.remove(peer)
        }
    }

    /// Returns fanout peers for a topic.
    func fanoutPeers(for topic: Topic) -> Set<PeerID> {
        state.withLock { $0.meshes[topic]?.fanoutPeers ?? [] }
    }

    /// Updates the last published time for a topic.
    func touchFanout(for topic: Topic) {
        state.withLock { state in
            if state.meshes[topic] == nil {
                state.meshes[topic] = TopicMesh()
            }
            state.meshes[topic]!.lastPublished = .now
        }
    }

    /// Clears expired fanout entries.
    ///
    /// - Parameter ttl: Maximum time since last publish
    func cleanupFanout(ttl: Duration) {
        state.withLock { state in
            let now = ContinuousClock.now
            for (topic, mesh) in state.meshes {
                // Only clean fanout for unsubscribed topics
                guard !state.subscriptions.contains(topic) else { continue }

                if let lastPublished = mesh.lastPublished {
                    if now - lastPublished > ttl {
                        // Expired - remove fanout
                        state.meshes[topic]?.fanoutPeers.removeAll()
                        state.meshes[topic]?.lastPublished = nil
                    }
                }
            }

            // Remove empty meshes for unsubscribed topics
            state.meshes = state.meshes.filter { topic, mesh in
                state.subscriptions.contains(topic) ||
                !mesh.meshPeers.isEmpty ||
                !mesh.fanoutPeers.isEmpty
            }
        }
    }

    // MARK: - Peer Removal

    /// Removes a peer from all meshes and fanouts.
    func removePeerFromAll(_ peer: PeerID) {
        state.withLock { state in
            for topic in state.meshes.keys {
                state.meshes[topic]?.meshPeers.remove(peer)
                state.meshes[topic]?.fanoutPeers.remove(peer)
            }
        }
    }

    /// Returns topics where the peer is in our mesh.
    func topicsInMesh(for peer: PeerID) -> [Topic] {
        state.withLock { state in
            state.meshes.compactMap { topic, mesh in
                mesh.meshPeers.contains(peer) ? topic : nil
            }
        }
    }

    // MARK: - Mesh Selection

    /// Selects peers for grafting to reach target mesh size.
    ///
    /// - Parameters:
    ///   - topic: The topic
    ///   - count: Number of peers to select
    ///   - candidates: Available candidate peers
    ///   - preferOutbound: Whether to prefer outbound peers
    /// - Returns: Selected peers
    func selectPeersForGraft(
        topic: Topic,
        count: Int,
        candidates: [PeerID],
        preferOutbound: Bool = false
    ) -> [PeerID] {
        let currentMesh = meshPeers(for: topic)
        let available = candidates.filter { !currentMesh.contains($0) }

        if available.count <= count {
            return available
        }

        // Random selection (in production, consider outbound preference)
        return Array(available.shuffled().prefix(count))
    }

    /// Selects peers for pruning to reach target mesh size.
    ///
    /// - Parameters:
    ///   - topic: The topic
    ///   - count: Number of peers to select
    ///   - protectOutbound: Minimum outbound peers to keep
    ///   - outboundPeers: Set of outbound peers
    /// - Returns: Selected peers to prune
    func selectPeersForPrune(
        topic: Topic,
        count: Int,
        protectOutbound: Int,
        outboundPeers: Set<PeerID>
    ) -> [PeerID] {
        let currentMesh = Array(meshPeers(for: topic))

        if currentMesh.count <= count {
            return []
        }

        let toPrune = currentMesh.count - count

        // Separate inbound and outbound
        let inbound = currentMesh.filter { !outboundPeers.contains($0) }
        let outbound = currentMesh.filter { outboundPeers.contains($0) }

        var selected: [PeerID] = []

        // First, try to prune inbound peers
        let inboundToPrune = min(inbound.count, toPrune)
        selected.append(contentsOf: inbound.shuffled().prefix(inboundToPrune))

        // If we need more, prune outbound (but keep minimum)
        let remaining = toPrune - selected.count
        if remaining > 0 {
            let outboundCanPrune = max(0, outbound.count - protectOutbound)
            let outboundToPrune = min(outboundCanPrune, remaining)
            selected.append(contentsOf: outbound.shuffled().prefix(outboundToPrune))
        }

        return selected
    }

    // MARK: - Statistics

    /// Returns mesh statistics.
    var stats: MeshStats {
        state.withLock { state in
            var totalMeshPeers = 0
            var totalFanoutPeers = 0
            var topicStats: [Topic: (mesh: Int, fanout: Int)] = [:]

            for (topic, mesh) in state.meshes {
                totalMeshPeers += mesh.meshPeers.count
                totalFanoutPeers += mesh.fanoutPeers.count
                topicStats[topic] = (mesh.meshPeers.count, mesh.fanoutPeers.count)
            }

            return MeshStats(
                subscriptionCount: state.subscriptions.count,
                totalMeshPeers: totalMeshPeers,
                totalFanoutPeers: totalFanoutPeers,
                topicStats: topicStats
            )
        }
    }

    /// Clears all state.
    func clear() {
        state.withLock { state in
            state.subscriptions.removeAll()
            state.meshes.removeAll()
        }
    }
}

// MARK: - MeshStats

/// Statistics about mesh state.
public struct MeshStats: Sendable {
    /// Number of subscribed topics.
    public let subscriptionCount: Int

    /// Total mesh peers across all topics.
    public let totalMeshPeers: Int

    /// Total fanout peers across all topics.
    public let totalFanoutPeers: Int

    /// Per-topic statistics.
    public let topicStats: [Topic: (mesh: Int, fanout: Int)]
}
