/// NullResourceManager - No-op resource manager for testing and backwards compatibility
///
/// All operations succeed without tracking. Useful when resource
/// limiting is not needed.

import P2PCore
import P2PRuntime

/// A no-op resource manager that imposes no limits.
///
/// All reserve operations succeed immediately. All release operations
/// are ignored. Scope queries return zero usage and unlimited limits.
public final class NullResourceManager: ResourceManager, Sendable {

    public init() {}

    public var systemScope: ResourceScope {
        NullScope(name: "system")
    }

    public func peerScope(for peer: PeerID) -> ResourceScope {
        NullScope(name: "peer:\(peer.shortDescription)")
    }

    public func reserveInboundConnection(from peer: PeerID) throws {}
    public func reserveOutboundConnection(to peer: PeerID) throws {}
    public func releaseConnection(peer: PeerID, direction: ConnectionDirection) {}

    public func reserveInboundStream(from peer: PeerID) throws {}
    public func reserveOutboundStream(to peer: PeerID) throws {}
    public func releaseStream(peer: PeerID, direction: ConnectionDirection) {}

    public func reserveMemory(_ bytes: Int, for peer: PeerID) throws {}
    public func releaseMemory(_ bytes: Int, for peer: PeerID) {}

    // Protocol scope — deliberately unlimited (this is the explicit opt-out).
    public func protocolScope(for protocolID: String) -> ResourceScope {
        NullScope(name: "protocol:\(protocolID)")
    }

    public func reserveStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) throws {}

    public func releaseStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) {}

    // Service scope — deliberately unlimited (this is the explicit opt-out).
    public func serviceScope(for service: String) -> ResourceScope {
        NullScope(name: "service:\(service)")
    }

    public func reserveServiceMemory(_ bytes: Int, service: String) throws {}

    public func releaseServiceMemory(_ bytes: Int, service: String) {}

    public func snapshot() -> ResourceSnapshot {
        ResourceSnapshot(system: ResourceStat(), peers: [:])
    }
}

/// A no-op scope that reports zero usage and unlimited limits.
private struct NullScope: ResourceScope, Sendable {
    let name: String
    var stat: ResourceStat { ResourceStat() }
    var limits: ScopeLimits { .unlimited }
}
