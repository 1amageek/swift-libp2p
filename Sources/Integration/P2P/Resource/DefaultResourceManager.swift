/// DefaultResourceManager - Concrete Mutex-based resource manager
///
/// Tracks connections, streams, and memory across system, per-peer,
/// per-protocol, and per-service scopes. All reservations are atomic:
/// all scope limits checked and committed within a single Mutex.withLock call.

import Synchronization
import P2PCore
import P2PRuntime

private let resourceLogger = Logger(label: "p2p.resource")

/// Decrements a counter, surfacing accounting drift instead of silently masking
/// it. An underflow means a release without a matching reserve (a real bug):
/// it trips an assertion in debug builds and logs an error in release builds,
/// clamping to zero only to keep the process alive.
@inline(__always)
private func decrement(
    _ value: inout Int,
    by amount: Int = 1,
    scope: @autoclosure () -> String,
    resource: String
) {
    let next = value - amount
    if next < 0 {
        assertionFailure("Resource accounting underflow in \(scope()).\(resource): \(value) - \(amount)")
        resourceLogger.error("Resource accounting underflow in \(scope()).\(resource): \(value) - \(amount)")
        value = 0
    } else {
        value = next
    }
}

/// Concrete resource manager with system-wide, per-peer, per-protocol,
/// and per-service limits.
///
/// ## Thread Safety
///
/// All state is protected by a single `Mutex<ManagerState>`. Reservations
/// check all scope limits before mutating, ensuring no partial
/// updates on failure.
///
/// ## Peer Cleanup
///
/// Peer entries are automatically removed when all their counters reach zero.
/// Protocol and service entries follow the same cleanup pattern.
public final class DefaultResourceManager: ResourceManager, Sendable {

    private let config: ResourceLimitsConfiguration
    private let state: Mutex<ManagerState>

    private struct ManagerState: Sendable {
        var systemStat: ResourceStat = ResourceStat()
        var peerStats: [PeerID: ResourceStat] = [:]
        var protocolStats: [String: ResourceStat] = [:]
        var serviceStats: [String: ResourceStat] = [:]
    }

    public init(configuration: ResourceLimitsConfiguration = .default) {
        self.config = configuration
        self.state = Mutex(ManagerState())
    }

    // MARK: - Scope Access

    public var systemScope: ResourceScope {
        let stat = state.withLock { $0.systemStat }
        return SnapshotScope(name: "system", stat: stat, limits: config.system)
    }

    public func peerScope(for peer: PeerID) -> ResourceScope {
        let stat = state.withLock { $0.peerStats[peer] ?? ResourceStat() }
        let limits = config.effectivePeerLimits(for: peer)
        return SnapshotScope(name: "peer:\(peer.shortDescription)", stat: stat, limits: limits)
    }

    public func protocolScope(for protocolID: String) -> ResourceScope {
        let stat = state.withLock { $0.protocolStats[protocolID] ?? ResourceStat() }
        let limits = config.effectiveProtocolLimits(for: protocolID)
        return SnapshotScope(name: "protocol:\(protocolID)", stat: stat, limits: limits)
    }

    public func serviceScope(for service: String) -> ResourceScope {
        let stat = state.withLock { $0.serviceStats[service] ?? ResourceStat() }
        let limits = config.effectiveServiceLimits(for: service)
        return SnapshotScope(name: "service:\(service)", stat: stat, limits: limits)
    }

    // MARK: - Connection Reservations

    public func reserveInboundConnection(from peer: PeerID) throws {
        try state.withLock { s in
            let peerLimits = config.effectivePeerLimits(for: peer)
            let peerStat = s.peerStats[peer] ?? ResourceStat()

            // Check system limits
            if let max = config.system.maxInboundConnections, s.systemStat.inboundConnections >= max {
                throw ResourceError.limitExceeded(scope: "system", resource: "inboundConnections")
            }
            if let max = config.system.maxTotalConnections, s.systemStat.totalConnections >= max {
                throw ResourceError.limitExceeded(scope: "system", resource: "totalConnections")
            }

            // Check peer limits
            if let max = peerLimits.maxInboundConnections, peerStat.inboundConnections >= max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "inboundConnections")
            }
            if let max = peerLimits.maxTotalConnections, peerStat.totalConnections >= max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "totalConnections")
            }

            // All checks passed — commit atomically
            s.systemStat.inboundConnections += 1
            s.peerStats[peer, default: ResourceStat()].inboundConnections += 1
        }
    }

    public func reserveOutboundConnection(to peer: PeerID) throws {
        try state.withLock { s in
            let peerLimits = config.effectivePeerLimits(for: peer)
            let peerStat = s.peerStats[peer] ?? ResourceStat()

            // Check system limits
            if let max = config.system.maxOutboundConnections, s.systemStat.outboundConnections >= max {
                throw ResourceError.limitExceeded(scope: "system", resource: "outboundConnections")
            }
            if let max = config.system.maxTotalConnections, s.systemStat.totalConnections >= max {
                throw ResourceError.limitExceeded(scope: "system", resource: "totalConnections")
            }

            // Check peer limits
            if let max = peerLimits.maxOutboundConnections, peerStat.outboundConnections >= max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "outboundConnections")
            }
            if let max = peerLimits.maxTotalConnections, peerStat.totalConnections >= max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "totalConnections")
            }

            // All checks passed — commit atomically
            s.systemStat.outboundConnections += 1
            s.peerStats[peer, default: ResourceStat()].outboundConnections += 1
        }
    }

    public func releaseConnection(peer: PeerID, direction: ConnectionDirection) {
        state.withLock { s in
            switch direction {
            case .inbound:
                decrement(&s.systemStat.inboundConnections, scope: "system", resource: "inboundConnections")
                if var peerStat = s.peerStats[peer] {
                    decrement(&peerStat.inboundConnections, scope: "peer:\(peer.shortDescription)", resource: "inboundConnections")
                    s.peerStats[peer] = peerStat
                }
            case .outbound:
                decrement(&s.systemStat.outboundConnections, scope: "system", resource: "outboundConnections")
                if var peerStat = s.peerStats[peer] {
                    decrement(&peerStat.outboundConnections, scope: "peer:\(peer.shortDescription)", resource: "outboundConnections")
                    s.peerStats[peer] = peerStat
                }
            }

            // Garbage-collect peer entry if all counters are zero
            if s.peerStats[peer]?.isZero == true {
                s.peerStats.removeValue(forKey: peer)
            }
        }
    }

    // MARK: - Stream Reservations

    public func reserveInboundStream(from peer: PeerID) throws {
        try state.withLock { s in
            let peerLimits = config.effectivePeerLimits(for: peer)
            let peerStat = s.peerStats[peer] ?? ResourceStat()

            // Check system limits
            if let max = config.system.maxInboundStreams, s.systemStat.inboundStreams >= max {
                throw ResourceError.limitExceeded(scope: "system", resource: "inboundStreams")
            }
            if let max = config.system.maxTotalStreams, s.systemStat.totalStreams >= max {
                throw ResourceError.limitExceeded(scope: "system", resource: "totalStreams")
            }

            // Check peer limits
            if let max = peerLimits.maxInboundStreams, peerStat.inboundStreams >= max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "inboundStreams")
            }
            if let max = peerLimits.maxTotalStreams, peerStat.totalStreams >= max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "totalStreams")
            }

            // All checks passed — commit atomically
            s.systemStat.inboundStreams += 1
            s.peerStats[peer, default: ResourceStat()].inboundStreams += 1
        }
    }

    public func reserveOutboundStream(to peer: PeerID) throws {
        try state.withLock { s in
            let peerLimits = config.effectivePeerLimits(for: peer)
            let peerStat = s.peerStats[peer] ?? ResourceStat()

            // Check system limits
            if let max = config.system.maxOutboundStreams, s.systemStat.outboundStreams >= max {
                throw ResourceError.limitExceeded(scope: "system", resource: "outboundStreams")
            }
            if let max = config.system.maxTotalStreams, s.systemStat.totalStreams >= max {
                throw ResourceError.limitExceeded(scope: "system", resource: "totalStreams")
            }

            // Check peer limits
            if let max = peerLimits.maxOutboundStreams, peerStat.outboundStreams >= max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "outboundStreams")
            }
            if let max = peerLimits.maxTotalStreams, peerStat.totalStreams >= max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "totalStreams")
            }

            // All checks passed — commit atomically
            s.systemStat.outboundStreams += 1
            s.peerStats[peer, default: ResourceStat()].outboundStreams += 1
        }
    }

    public func releaseStream(peer: PeerID, direction: ConnectionDirection) {
        state.withLock { s in
            switch direction {
            case .inbound:
                decrement(&s.systemStat.inboundStreams, scope: "system", resource: "inboundStreams")
                if var peerStat = s.peerStats[peer] {
                    decrement(&peerStat.inboundStreams, scope: "peer:\(peer.shortDescription)", resource: "inboundStreams")
                    s.peerStats[peer] = peerStat
                }
            case .outbound:
                decrement(&s.systemStat.outboundStreams, scope: "system", resource: "outboundStreams")
                if var peerStat = s.peerStats[peer] {
                    decrement(&peerStat.outboundStreams, scope: "peer:\(peer.shortDescription)", resource: "outboundStreams")
                    s.peerStats[peer] = peerStat
                }
            }

            // Garbage-collect peer entry if all counters are zero
            if s.peerStats[peer]?.isZero == true {
                s.peerStats.removeValue(forKey: peer)
            }
        }
    }

    // MARK: - Protocol-Scoped Stream Reservations

    public func reserveStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) throws {
        try state.withLock { s in
            let peerLimits = config.effectivePeerLimits(for: peer)
            let peerStat = s.peerStats[peer] ?? ResourceStat()
            let protoLimits = config.effectiveProtocolLimits(for: protocolID)
            let protoStat = s.protocolStats[protocolID] ?? ResourceStat()

            switch direction {
            case .inbound:
                // Check system limits
                if let max = config.system.maxInboundStreams, s.systemStat.inboundStreams >= max {
                    throw ResourceError.limitExceeded(scope: "system", resource: "inboundStreams")
                }
                if let max = config.system.maxTotalStreams, s.systemStat.totalStreams >= max {
                    throw ResourceError.limitExceeded(scope: "system", resource: "totalStreams")
                }
                // Check peer limits
                if let max = peerLimits.maxInboundStreams, peerStat.inboundStreams >= max {
                    throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "inboundStreams")
                }
                if let max = peerLimits.maxTotalStreams, peerStat.totalStreams >= max {
                    throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "totalStreams")
                }
                // Check protocol limits
                if let max = protoLimits.maxInboundStreams, protoStat.inboundStreams >= max {
                    throw ResourceError.limitExceeded(scope: "protocol:\(protocolID)", resource: "inboundStreams")
                }
                if let max = protoLimits.maxTotalStreams, protoStat.totalStreams >= max {
                    throw ResourceError.limitExceeded(scope: "protocol:\(protocolID)", resource: "totalStreams")
                }

                // All checks passed — commit atomically
                s.systemStat.inboundStreams += 1
                s.peerStats[peer, default: ResourceStat()].inboundStreams += 1
                s.protocolStats[protocolID, default: ResourceStat()].inboundStreams += 1

            case .outbound:
                // Check system limits
                if let max = config.system.maxOutboundStreams, s.systemStat.outboundStreams >= max {
                    throw ResourceError.limitExceeded(scope: "system", resource: "outboundStreams")
                }
                if let max = config.system.maxTotalStreams, s.systemStat.totalStreams >= max {
                    throw ResourceError.limitExceeded(scope: "system", resource: "totalStreams")
                }
                // Check peer limits
                if let max = peerLimits.maxOutboundStreams, peerStat.outboundStreams >= max {
                    throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "outboundStreams")
                }
                if let max = peerLimits.maxTotalStreams, peerStat.totalStreams >= max {
                    throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "totalStreams")
                }
                // Check protocol limits
                if let max = protoLimits.maxOutboundStreams, protoStat.outboundStreams >= max {
                    throw ResourceError.limitExceeded(scope: "protocol:\(protocolID)", resource: "outboundStreams")
                }
                if let max = protoLimits.maxTotalStreams, protoStat.totalStreams >= max {
                    throw ResourceError.limitExceeded(scope: "protocol:\(protocolID)", resource: "totalStreams")
                }

                // All checks passed — commit atomically
                s.systemStat.outboundStreams += 1
                s.peerStats[peer, default: ResourceStat()].outboundStreams += 1
                s.protocolStats[protocolID, default: ResourceStat()].outboundStreams += 1
            }
        }
    }

    public func releaseStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) {
        state.withLock { s in
            switch direction {
            case .inbound:
                decrement(&s.systemStat.inboundStreams, scope: "system", resource: "inboundStreams")
                if var peerStat = s.peerStats[peer] {
                    decrement(&peerStat.inboundStreams, scope: "peer:\(peer.shortDescription)", resource: "inboundStreams")
                    s.peerStats[peer] = peerStat
                }
                if var protoStat = s.protocolStats[protocolID] {
                    decrement(&protoStat.inboundStreams, scope: "protocol:\(protocolID)", resource: "inboundStreams")
                    s.protocolStats[protocolID] = protoStat
                }
            case .outbound:
                decrement(&s.systemStat.outboundStreams, scope: "system", resource: "outboundStreams")
                if var peerStat = s.peerStats[peer] {
                    decrement(&peerStat.outboundStreams, scope: "peer:\(peer.shortDescription)", resource: "outboundStreams")
                    s.peerStats[peer] = peerStat
                }
                if var protoStat = s.protocolStats[protocolID] {
                    decrement(&protoStat.outboundStreams, scope: "protocol:\(protocolID)", resource: "outboundStreams")
                    s.protocolStats[protocolID] = protoStat
                }
            }

            // Garbage-collect entries if all counters are zero
            if s.peerStats[peer]?.isZero == true {
                s.peerStats.removeValue(forKey: peer)
            }
            if s.protocolStats[protocolID]?.isZero == true {
                s.protocolStats.removeValue(forKey: protocolID)
            }
        }
    }

    // MARK: - Memory Reservations

    public func reserveMemory(_ bytes: Int, for peer: PeerID) throws {
        try state.withLock { s in
            let peerLimits = config.effectivePeerLimits(for: peer)
            let peerStat = s.peerStats[peer] ?? ResourceStat()

            // Check system limits
            if let max = config.system.maxMemory, s.systemStat.memory + bytes > max {
                throw ResourceError.limitExceeded(scope: "system", resource: "memory")
            }

            // Check peer limits
            if let max = peerLimits.maxMemory, peerStat.memory + bytes > max {
                throw ResourceError.limitExceeded(scope: "peer:\(peer.shortDescription)", resource: "memory")
            }

            // All checks passed — commit atomically
            s.systemStat.memory += bytes
            s.peerStats[peer, default: ResourceStat()].memory += bytes
        }
    }

    public func releaseMemory(_ bytes: Int, for peer: PeerID) {
        state.withLock { s in
            decrement(&s.systemStat.memory, by: bytes, scope: "system", resource: "memory")
            if var peerStat = s.peerStats[peer] {
                decrement(&peerStat.memory, by: bytes, scope: "peer:\(peer.shortDescription)", resource: "memory")
                s.peerStats[peer] = peerStat
            }

            // Garbage-collect peer entry if all counters are zero
            if s.peerStats[peer]?.isZero == true {
                s.peerStats.removeValue(forKey: peer)
            }
        }
    }

    // MARK: - Service Memory Reservations

    public func reserveServiceMemory(_ bytes: Int, service: String) throws {
        try state.withLock { s in
            let svcLimits = config.effectiveServiceLimits(for: service)
            let svcStat = s.serviceStats[service] ?? ResourceStat()

            // Check system limits
            if let max = config.system.maxMemory, s.systemStat.memory + bytes > max {
                throw ResourceError.limitExceeded(scope: "system", resource: "memory")
            }

            // Check service limits
            if let max = svcLimits.maxMemory, svcStat.memory + bytes > max {
                throw ResourceError.limitExceeded(scope: "service:\(service)", resource: "memory")
            }

            // All checks passed — commit atomically
            s.systemStat.memory += bytes
            s.serviceStats[service, default: ResourceStat()].memory += bytes
        }
    }

    public func releaseServiceMemory(_ bytes: Int, service: String) {
        state.withLock { s in
            decrement(&s.systemStat.memory, by: bytes, scope: "system", resource: "memory")
            if var svcStat = s.serviceStats[service] {
                decrement(&svcStat.memory, by: bytes, scope: "service:\(service)", resource: "memory")
                s.serviceStats[service] = svcStat
            }

            // Garbage-collect service entry if all counters are zero
            if s.serviceStats[service]?.isZero == true {
                s.serviceStats.removeValue(forKey: service)
            }
        }
    }

    // MARK: - Snapshot

    public func snapshot() -> ResourceSnapshot {
        state.withLock { s in
            ResourceSnapshot(
                system: s.systemStat,
                peers: s.peerStats,
                protocols: s.protocolStats,
                services: s.serviceStats
            )
        }
    }
}

// MARK: - SnapshotScope

/// A point-in-time scope view returned by DefaultResourceManager.
internal struct SnapshotScope: ResourceScope, Sendable {
    let name: String
    let stat: ResourceStat
    let limits: ScopeLimits
}
