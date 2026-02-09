import Foundation
import P2PCore

/// An unconfirmed sighting from Tier 1/2 beacon (TruncID only).
/// Kept locally -- never propagated beyond the aggregation layer.
public struct UnconfirmedSighting: Sendable {
    /// First 2 bytes of EphID (collision possible).
    public let truncID: UInt16

    /// Addresses where this TruncID was observed.
    public var addresses: [OpaqueAddress]

    /// Observation history.
    public var observations: [BeaconObservation]

    /// Bayesian presence score (0.0-1.0).
    public var presenceScore: Double

    public init(
        truncID: UInt16,
        addresses: [OpaqueAddress] = [],
        observations: [BeaconObservation] = [],
        presenceScore: Double = 0
    ) {
        self.truncID = truncID
        self.addresses = addresses
        self.observations = observations
        self.presenceScore = presenceScore
    }
}
