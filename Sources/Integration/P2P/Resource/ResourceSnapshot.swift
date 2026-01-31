/// ResourceSnapshot - Point-in-time resource usage snapshot

import P2PCore

/// A point-in-time snapshot of resource usage across all scopes.
public struct ResourceSnapshot: Sendable {

    /// System-wide resource usage.
    public let system: ResourceStat

    /// Per-peer resource usage.
    public let peers: [PeerID: ResourceStat]

    /// Per-protocol resource usage.
    public let protocols: [String: ResourceStat]

    /// Per-service resource usage.
    public let services: [String: ResourceStat]

    public init(
        system: ResourceStat,
        peers: [PeerID: ResourceStat],
        protocols: [String: ResourceStat] = [:],
        services: [String: ResourceStat] = [:]
    ) {
        self.system = system
        self.peers = peers
        self.protocols = protocols
        self.services = services
    }
}
