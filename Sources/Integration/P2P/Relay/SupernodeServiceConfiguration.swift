/// SupernodeServiceConfiguration - Configuration for SupernodeService.

import Foundation

/// Configuration for `SupernodeService`.
public struct SupernodeServiceConfiguration: Sendable {
    /// Interval between eligibility evaluations.
    public var evaluationInterval: Duration

    /// Minimum connected peers required to activate relay.
    public var minConnectedPeers: Int

    /// Whether to require public NAT status before activating relay.
    public var requirePublicNAT: Bool

    public init(
        evaluationInterval: Duration = .seconds(120),
        minConnectedPeers: Int = 5,
        requirePublicNAT: Bool = true
    ) {
        self.evaluationInterval = evaluationInterval
        self.minConnectedPeers = minConnectedPeers
        self.requirePublicNAT = requirePublicNAT
    }
}
