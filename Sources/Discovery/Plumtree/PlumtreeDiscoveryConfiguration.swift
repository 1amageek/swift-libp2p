import P2PPlumtree

/// Configuration for `PlumtreeDiscovery`.
public struct PlumtreeDiscoveryConfiguration: Sendable {
    /// Discovery topic used for announcements.
    public var topic: String

    /// Time-to-live for learned peers.
    public var peerTTL: Duration

    /// Maximum number of peers kept in memory.
    public var maxKnownPeers: Int

    /// Base score assigned to peers discovered via Plumtree.
    public var baseScore: Double

    /// Whether announcements without valid addresses are rejected.
    public var requireAddresses: Bool

    /// Underlying Plumtree protocol configuration.
    public var plumtreeConfiguration: PlumtreeConfiguration

    public init(
        topic: String = "/libp2p/discovery/plumtree/1.0.0",
        peerTTL: Duration = .seconds(600),
        maxKnownPeers: Int = 10_000,
        baseScore: Double = 0.7,
        requireAddresses: Bool = true,
        plumtreeConfiguration: PlumtreeConfiguration = .default
    ) {
        self.topic = topic
        self.peerTTL = peerTTL
        self.maxKnownPeers = maxKnownPeers
        self.baseScore = baseScore
        self.requireAddresses = requireAddresses
        self.plumtreeConfiguration = plumtreeConfiguration
    }
}

extension PlumtreeDiscoveryConfiguration {
    /// Default production settings.
    public static var `default`: PlumtreeDiscoveryConfiguration {
        PlumtreeDiscoveryConfiguration()
    }

    /// Short-lived settings for unit tests.
    public static var testing: PlumtreeDiscoveryConfiguration {
        PlumtreeDiscoveryConfiguration(
            peerTTL: .seconds(2),
            maxKnownPeers: 128,
            baseScore: 0.8,
            requireAddresses: true,
            plumtreeConfiguration: .testing
        )
    }
}
