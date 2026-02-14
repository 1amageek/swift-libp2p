/// P2PDiscovery - Discovery layer for swift-libp2p
///
/// Implements peer discovery mechanisms:
/// - Observation-based discovery
/// - Gossip protocols (Plumtree)
/// - Membership protocols (SWIM, HyParView)
/// - Peer sampling (CYCLON)

import P2PCore

/// An observation about a peer's reachability.
public struct Observation: Sendable, Hashable {

    /// The type of observation.
    public enum Kind: Sendable, Hashable {
        /// Self-announcement of reachability.
        case announcement
        /// Third-party witness that peer is reachable.
        case reachable
        /// Third-party witness that peer is unreachable.
        case unreachable
    }

    /// The subject peer being observed.
    public let subject: PeerID

    /// The observer who made this observation.
    public let observer: PeerID

    /// The type of observation.
    public let kind: Kind

    /// Hints for reaching the subject.
    public let hints: [Multiaddr]

    /// When this observation was created.
    public let timestamp: UInt64

    /// Sequence number for ordering.
    public let sequenceNumber: UInt64

    public init(
        subject: PeerID,
        observer: PeerID,
        kind: Kind,
        hints: [Multiaddr],
        timestamp: UInt64,
        sequenceNumber: UInt64
    ) {
        self.subject = subject
        self.observer = observer
        self.kind = kind
        self.hints = hints
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
    }
}

/// A scored candidate for connection.
public struct ScoredCandidate: Sendable {

    /// The peer ID.
    public let peerID: PeerID

    /// Addresses to try.
    public let addresses: [Multiaddr]

    /// The computed score (higher is better).
    public let score: Double

    public init(peerID: PeerID, addresses: [Multiaddr], score: Double) {
        self.peerID = peerID
        self.addresses = addresses
        self.score = score
    }
}

/// Discovery service protocol.
public protocol DiscoveryService: Sendable {

    /// Announces our own reachability.
    func announce(addresses: [Multiaddr]) async throws

    /// Finds candidates for a given peer.
    func find(peer: PeerID) async throws -> [ScoredCandidate]

    /// Subscribes to observations about a peer.
    func subscribe(to peer: PeerID) -> AsyncStream<Observation>

    /// Returns known peers.
    func knownPeers() async -> [PeerID]

    /// Stream of all observations.
    var observations: AsyncStream<Observation> { get }

    /// Shuts down the discovery service and releases operational resources.
    ///
    /// After calling `shutdown()`, the service should not emit new observations.
    /// This method is idempotent and safe to call multiple times.
    /// Restart after `shutdown()` is not currently supported.
    func shutdown() async
}
