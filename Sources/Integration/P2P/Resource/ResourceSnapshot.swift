/// ResourceSnapshot - Point-in-time resource usage snapshot

import P2PCore

/// A point-in-time snapshot of resource usage across all scopes.
public struct ResourceSnapshot: Sendable {

    /// System-wide resource usage.
    public let system: ResourceStat

    /// Per-peer resource usage.
    public let peers: [PeerID: ResourceStat]

    public init(system: ResourceStat, peers: [PeerID: ResourceStat]) {
        self.system = system
        self.peers = peers
    }
}
