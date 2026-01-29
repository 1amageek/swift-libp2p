/// ResourceLimitsConfiguration - Combined system + peer limits configuration

import P2PCore

/// Configuration for resource limits at system and peer levels.
public struct ResourceLimitsConfiguration: Sendable {

    /// System-wide resource limits.
    public var system: ScopeLimits

    /// Default per-peer resource limits.
    public var peer: ScopeLimits

    /// Per-peer limit overrides for specific peers.
    public var peerOverrides: [PeerID: ScopeLimits]

    public init(
        system: ScopeLimits = .defaultSystem,
        peer: ScopeLimits = .defaultPeer,
        peerOverrides: [PeerID: ScopeLimits] = [:]
    ) {
        self.system = system
        self.peer = peer
        self.peerOverrides = peerOverrides
    }

    /// Returns the effective limits for a specific peer.
    ///
    /// Uses peer-specific overrides if available, otherwise falls back
    /// to the default peer limits.
    public func effectivePeerLimits(for peer: PeerID) -> ScopeLimits {
        peerOverrides[peer] ?? self.peer
    }

    /// Default configuration with standard limits.
    public static let `default` = ResourceLimitsConfiguration()
}
