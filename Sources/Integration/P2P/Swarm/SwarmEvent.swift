/// Events emitted by the Swarm layer.
///
/// These events are consumed internally by Node to drive behaviour notifications
/// and external NodeEvent emission.
internal enum SwarmEvent: Sendable {
    /// A peer connected (first connection, deduped).
    case peerConnected(PeerID)

    /// A peer disconnected (last connection closed, deduped).
    case peerDisconnected(PeerID)

    /// A connection-level event occurred.
    case connection(ConnectionEvent)

    /// An error occurred while listening.
    case listenError(Multiaddr, any Error & Sendable)

    /// A new listen address is active.
    case newListenAddr(Multiaddr)

    /// A listen address expired.
    case expiredListenAddr(Multiaddr)

    /// Dialing a peer.
    case dialing(PeerID)

    /// An outgoing connection attempt failed.
    case outgoingConnectionError(peer: PeerID?, error: any Error & Sendable)

    /// A connection error occurred.
    case connectionError(PeerID?, any Error & Sendable)
}
