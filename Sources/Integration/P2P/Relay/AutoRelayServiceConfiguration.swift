/// AutoRelayServiceConfiguration - Configuration for AutoRelayService.

import Foundation
import P2PCore

/// Configuration for `AutoRelayService`.
public struct AutoRelayServiceConfiguration: Sendable {
    /// Number of relay reservations to maintain.
    public var desiredRelays: Int

    /// Interval between monitoring cycles.
    public var monitorInterval: Duration

    /// Static relay peers to always consider as candidates.
    public var staticRelays: [PeerID]

    /// Relay selection strategy.
    public var selector: any RelaySelector

    /// Cooldown after a failure before retrying a candidate.
    public var failureCooldown: Duration

    /// Whether to use connected peers as relay candidates.
    public var useConnectedPeers: Bool

    public init(
        desiredRelays: Int = 3,
        monitorInterval: Duration = .seconds(60),
        staticRelays: [PeerID] = [],
        selector: any RelaySelector = DefaultRelaySelector(),
        failureCooldown: Duration = .seconds(300),
        useConnectedPeers: Bool = true
    ) {
        self.desiredRelays = desiredRelays
        self.monitorInterval = monitorInterval
        self.staticRelays = staticRelays
        self.selector = selector
        self.failureCooldown = failureCooldown
        self.useConnectedPeers = useConnectedPeers
    }
}
