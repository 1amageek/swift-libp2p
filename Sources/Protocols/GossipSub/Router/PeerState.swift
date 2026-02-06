/// PeerState - Per-peer state tracking for GossipSub
import Foundation
import P2PCore
import P2PMux
import Synchronization

/// Protocol version support level for a peer.
public enum GossipSubVersion: Sendable, Comparable {
    /// FloodSub only (no mesh management).
    case floodsub

    /// GossipSub v1.0 (basic mesh).
    case v10

    /// GossipSub v1.1 (peer exchange, backoff).
    case v11

    /// GossipSub v1.2 (IDONTWANT).
    case v12

    public static func < (lhs: GossipSubVersion, rhs: GossipSubVersion) -> Bool {
        switch (lhs, rhs) {
        case (.floodsub, .v10), (.floodsub, .v11), (.floodsub, .v12):
            return true
        case (.v10, .v11), (.v10, .v12):
            return true
        case (.v11, .v12):
            return true
        default:
            return false
        }
    }

    /// Returns the protocol ID string.
    public var protocolID: String {
        switch self {
        case .floodsub:
            return GossipSubProtocolID.floodsub
        case .v10:
            return GossipSubProtocolID.meshsub10
        case .v11:
            return GossipSubProtocolID.meshsub11
        case .v12:
            return GossipSubProtocolID.meshsub12
        }
    }

    /// Creates a version from a protocol ID string.
    public init?(protocolID: String) {
        switch protocolID {
        case GossipSubProtocolID.floodsub:
            self = .floodsub
        case GossipSubProtocolID.meshsub10:
            self = .v10
        case GossipSubProtocolID.meshsub11:
            self = .v11
        case GossipSubProtocolID.meshsub12:
            self = .v12
        default:
            return nil
        }
    }
}

/// Connection direction for a peer.
public enum PeerDirection: Sendable {
    /// We initiated the connection.
    case outbound
    /// The peer initiated the connection.
    case inbound
}

/// State information for a connected peer.
public struct PeerState: Sendable {
    /// The peer ID.
    public let peerID: PeerID

    /// Protocol version supported by this peer.
    public var version: GossipSubVersion

    /// Connection direction.
    public var direction: PeerDirection

    /// Topics the peer is subscribed to.
    public var subscriptions: Set<Topic>

    /// When we first connected.
    public let connectedAt: ContinuousClock.Instant

    /// When we last received a message from this peer.
    public var lastSeen: ContinuousClock.Instant

    /// Backoff timers for topics (after being pruned).
    public var backoffs: [Topic: ContinuousClock.Instant]

    /// Number of IWANT requests sent to this peer recently.
    public var iwantCount: Int

    /// Whether we've sent a graft to this peer recently.
    public var pendingGraft: Bool

    /// Messages the peer doesn't want to receive (IDONTWANT, v1.2).
    /// Maps message ID to expiration time.
    public var dontWantMessages: [MessageID: ContinuousClock.Instant]

    /// Creates a new peer state.
    public init(
        peerID: PeerID,
        version: GossipSubVersion,
        direction: PeerDirection
    ) {
        self.peerID = peerID
        self.version = version
        self.direction = direction
        self.subscriptions = []
        self.connectedAt = .now
        self.lastSeen = .now
        self.backoffs = [:]
        self.iwantCount = 0
        self.pendingGraft = false
        self.dontWantMessages = [:]
    }

    /// Checks if the peer doesn't want to receive a message.
    public func doesntWant(_ messageID: MessageID) -> Bool {
        guard let expiration = dontWantMessages[messageID] else {
            return false
        }
        return ContinuousClock.now < expiration
    }

    /// Maximum number of IDONTWANT entries per peer to prevent memory exhaustion.
    public static let maxDontWantEntries = 10_000

    /// Adds a message to the don't-want list.
    public mutating func addDontWant(_ messageID: MessageID, ttl: Duration) {
        // Prevent unbounded growth from malicious peers
        guard dontWantMessages.count < Self.maxDontWantEntries else { return }
        dontWantMessages[messageID] = .now + ttl
    }

    /// Clears expired don't-want entries.
    public mutating func clearExpiredDontWants() {
        let now = ContinuousClock.now
        dontWantMessages = dontWantMessages.filter { $0.value > now }
    }

    /// Updates the last seen time.
    public mutating func touch() {
        lastSeen = .now
    }

    /// Checks if the peer is in backoff for a topic.
    public func isBackedOff(for topic: Topic) -> Bool {
        guard let backoffUntil = backoffs[topic] else {
            return false
        }
        return ContinuousClock.now < backoffUntil
    }

    /// Sets a backoff for a topic.
    public mutating func setBackoff(for topic: Topic, duration: Duration) {
        backoffs[topic] = .now + duration
    }

    /// Clears expired backoffs.
    public mutating func clearExpiredBackoffs() {
        let now = ContinuousClock.now
        backoffs = backoffs.filter { $0.value > now }
    }
}

// MARK: - PeerStateManager

/// Manages peer states for GossipSub.
final class PeerStateManager: Sendable {

    private struct State: Sendable {
        var peers: [PeerID: PeerState]
        var streams: [PeerID: MuxedStream]
    }

    private let state: Mutex<State>

    init() {
        self.state = Mutex(State(peers: [:], streams: [:]))
    }

    // MARK: - Peer Management

    /// Adds or updates a peer.
    func addPeer(_ peerState: PeerState, stream: MuxedStream) {
        state.withLock { state in
            state.peers[peerState.peerID] = peerState
            state.streams[peerState.peerID] = stream
        }
    }

    /// Removes a peer.
    func removePeer(_ peerID: PeerID) {
        state.withLock { state in
            state.peers.removeValue(forKey: peerID)
            state.streams.removeValue(forKey: peerID)
        }
    }

    /// Gets a peer state.
    func getPeer(_ peerID: PeerID) -> PeerState? {
        state.withLock { $0.peers[peerID] }
    }

    /// Gets a peer's stream.
    func getStream(_ peerID: PeerID) -> MuxedStream? {
        state.withLock { $0.streams[peerID] }
    }

    /// Updates a peer state.
    func updatePeer(_ peerID: PeerID, update: (inout PeerState) -> Void) {
        state.withLock { state in
            if var peerState = state.peers[peerID] {
                update(&peerState)
                state.peers[peerID] = peerState
            }
        }
    }

    /// Returns all connected peers.
    var allPeers: [PeerID] {
        state.withLock { Array($0.peers.keys) }
    }

    /// Returns peers subscribed to a topic.
    func peersSubscribedTo(_ topic: Topic) -> [PeerID] {
        state.withLock { state in
            state.peers.values
                .filter { $0.subscriptions.contains(topic) }
                .map { $0.peerID }
        }
    }

    /// Returns peers not in backoff for a topic.
    func peersNotBackedOff(for topic: Topic) -> [PeerID] {
        state.withLock { state in
            state.peers.values
                .filter { $0.subscriptions.contains(topic) && !$0.isBackedOff(for: topic) }
                .map { $0.peerID }
        }
    }

    /// Returns outbound peers subscribed to a topic.
    func outboundPeersSubscribedTo(_ topic: Topic) -> [PeerID] {
        state.withLock { state in
            state.peers.values
                .filter { $0.subscriptions.contains(topic) && $0.direction == .outbound }
                .map { $0.peerID }
        }
    }

    /// Returns the number of connected peers.
    var peerCount: Int {
        state.withLock { $0.peers.count }
    }

    /// Checks if a peer is connected.
    func isConnected(_ peerID: PeerID) -> Bool {
        state.withLock { $0.peers[peerID] != nil }
    }

    /// Clears all peers.
    func clear() {
        state.withLock { state in
            state.peers.removeAll()
            state.streams.removeAll()
        }
    }

    /// Clears expired backoffs for all peers.
    func clearExpiredBackoffs() {
        state.withLock { state in
            for peerID in state.peers.keys {
                state.peers[peerID]?.clearExpiredBackoffs()
            }
        }
    }

    /// Clears expired IDONTWANT entries for all peers.
    func clearExpiredDontWants() {
        state.withLock { state in
            for peerID in state.peers.keys {
                state.peers[peerID]?.clearExpiredDontWants()
            }
        }
    }
}
