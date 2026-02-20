import P2PCore

/// Path category for candidate ordering.
public enum TraversalPathKind: Sendable {
    case local
    case ip
    case holePunch
    case relay
    case unknown
}

/// Candidate route considered by traversal.
public struct TraversalCandidate: Sendable {
    public let mechanismID: String
    public let peer: PeerID
    public let address: Multiaddr?
    public let pathKind: TraversalPathKind
    public let score: Double
    public let metadata: [String: String]

    public init(
        mechanismID: String,
        peer: PeerID,
        address: Multiaddr?,
        pathKind: TraversalPathKind,
        score: Double = 0,
        metadata: [String: String] = [:]
    ) {
        self.mechanismID = mechanismID
        self.peer = peer
        self.address = address
        self.pathKind = pathKind
        self.score = score
        self.metadata = metadata
    }
}

/// Successful traversal outcome.
public struct TraversalAttemptResult: Sendable {
    public let connectedPeer: PeerID
    public let selectedAddress: Multiaddr?
    public let mechanismID: String

    public init(
        connectedPeer: PeerID,
        selectedAddress: Multiaddr?,
        mechanismID: String
    ) {
        self.connectedPeer = connectedPeer
        self.selectedAddress = selectedAddress
        self.mechanismID = mechanismID
    }
}
