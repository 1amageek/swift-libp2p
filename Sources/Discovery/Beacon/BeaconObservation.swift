import Foundation

/// A single observation event from a specific medium at a specific time.
/// Used by the aggregation layer for Bayesian presence estimation.
///
/// Renamed from `Observation` (in swift-p2p-discovery) to avoid collision
/// with `P2PDiscovery.Observation`.
public struct BeaconObservation: Sendable {
    /// When the observation occurred.
    public let timestamp: ContinuousClock.Instant

    /// The medium that produced this observation.
    public let mediumID: String

    /// Signal strength (dBm), if available.
    public let rssi: Double?

    /// The transport-specific address of the observed peer.
    public let address: OpaqueAddress

    /// The freshness function for this medium.
    public let freshnessFunction: FreshnessFunction

    public init(
        timestamp: ContinuousClock.Instant = .now,
        mediumID: String,
        rssi: Double? = nil,
        address: OpaqueAddress,
        freshnessFunction: FreshnessFunction
    ) {
        self.timestamp = timestamp
        self.mediumID = mediumID
        self.rssi = rssi
        self.address = address
        self.freshnessFunction = freshnessFunction
    }

    /// Elapsed time since the observation.
    public var age: Duration {
        ContinuousClock.now - timestamp
    }
}
