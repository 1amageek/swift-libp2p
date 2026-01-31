/// ResourceLimitsConfiguration - Combined system + peer limits configuration

import P2PCore

/// Configuration for resource limits at system, peer, protocol, and service levels.
public struct ResourceLimitsConfiguration: Sendable {

    /// System-wide resource limits.
    public var system: ScopeLimits

    /// Default per-peer resource limits.
    public var peer: ScopeLimits

    /// Per-peer limit overrides for specific peers.
    public var peerOverrides: [PeerID: ScopeLimits]

    /// Default per-protocol resource limits.
    public var protocolLimits: ScopeLimits

    /// Per-protocol limit overrides for specific protocols.
    public var protocolOverrides: [String: ScopeLimits]

    /// Default per-service resource limits.
    public var serviceLimits: ScopeLimits

    /// Per-service limit overrides for specific services.
    public var serviceOverrides: [String: ScopeLimits]

    public init(
        system: ScopeLimits = .defaultSystem,
        peer: ScopeLimits = .defaultPeer,
        peerOverrides: [PeerID: ScopeLimits] = [:],
        protocolLimits: ScopeLimits = .defaultProtocol,
        protocolOverrides: [String: ScopeLimits] = [:],
        serviceLimits: ScopeLimits = .defaultService,
        serviceOverrides: [String: ScopeLimits] = [:]
    ) {
        self.system = system
        self.peer = peer
        self.peerOverrides = peerOverrides
        self.protocolLimits = protocolLimits
        self.protocolOverrides = protocolOverrides
        self.serviceLimits = serviceLimits
        self.serviceOverrides = serviceOverrides
    }

    /// Returns the effective limits for a specific peer.
    ///
    /// Uses peer-specific overrides if available, otherwise falls back
    /// to the default peer limits.
    public func effectivePeerLimits(for peer: PeerID) -> ScopeLimits {
        peerOverrides[peer] ?? self.peer
    }

    /// Returns the effective limits for a specific protocol.
    ///
    /// Uses protocol-specific overrides if available, otherwise falls back
    /// to the default protocol limits.
    public func effectiveProtocolLimits(for protocolID: String) -> ScopeLimits {
        protocolOverrides[protocolID] ?? protocolLimits
    }

    /// Returns the effective limits for a specific service.
    ///
    /// Uses service-specific overrides if available, otherwise falls back
    /// to the default service limits.
    public func effectiveServiceLimits(for service: String) -> ScopeLimits {
        serviceOverrides[service] ?? serviceLimits
    }

    /// Default configuration with standard limits.
    public static let `default` = ResourceLimitsConfiguration()
}
