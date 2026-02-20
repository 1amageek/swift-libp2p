/// NATTraversalConfiguration - Configuration for NAT traversal integration.
///
/// Bundles all NAT traversal service instances and settings.
/// Pass existing service instances that the NATManager will coordinate.

import P2PCore
import P2PAutoNAT
import P2PCircuitRelay
import P2PDCUtR
import P2PNAT

/// Configuration for NAT traversal in the Node.
public struct NATTraversalConfiguration: Sendable {

    /// AutoNAT service for NAT detection (required for probing).
    public var autoNAT: AutoNATService?

    /// Relay client for making reservations and connecting through relays.
    public var relayClient: RelayClient?

    /// Relay server for serving as a relay to other peers (optional).
    public var relayServer: RelayServer?

    /// AutoRelay for automatic relay address management.
    public var autoRelay: AutoRelay?

    /// DCUtR service for direct connection upgrade coordination.
    public var dcutr: DCUtRService?

    /// HolePunch service for executing actual hole punches.
    public var holePunch: HolePunchService?

    /// NAT port mapper for UPnP/NAT-PMP (optional).
    public var portMapper: NATPortMapper?

    /// Interval between AutoNAT probe cycles.
    public var probeInterval: Duration

    /// Minimum number of connected peers required before probing.
    public var minPeersForProbe: Int

    /// Whether to attempt hole punching on inbound relay connections.
    public var enableHolePunching: Bool

    /// Delay before initiating DCUtR after Identify completes on a relay connection.
    public var dcutrDelay: Duration

    /// Creates a new NAT traversal configuration.
    public init(
        autoNAT: AutoNATService? = nil,
        relayClient: RelayClient? = nil,
        relayServer: RelayServer? = nil,
        autoRelay: AutoRelay? = nil,
        dcutr: DCUtRService? = nil,
        holePunch: HolePunchService? = nil,
        portMapper: NATPortMapper? = nil,
        probeInterval: Duration = .seconds(60),
        minPeersForProbe: Int = 4,
        enableHolePunching: Bool = true,
        dcutrDelay: Duration = .milliseconds(500)
    ) {
        self.autoNAT = autoNAT
        self.relayClient = relayClient
        self.relayServer = relayServer
        self.autoRelay = autoRelay
        self.dcutr = dcutr
        self.holePunch = holePunch
        self.portMapper = portMapper
        self.probeInterval = probeInterval
        self.minPeersForProbe = minPeersForProbe
        self.enableHolePunching = enableHolePunching
        self.dcutrDelay = dcutrDelay
    }
}
