/// DefaultResourceManager - Concrete Mutex-based resource manager
///
/// Tracks connections, streams, and memory across system, per-peer,
/// per-protocol, and per-service scopes. All reservations are atomic:
/// all scope limits checked and committed within a single Mutex.withLock call.

import Synchronization
import P2PCore

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
internal final class DefaultResourceManager: ResourceManager, Sendable {

    private let config: ResourceLimitsConfiguration
    private let state: Mutex<ManagerState>

    private struct ManagerState: Sendable {
        var systemStat: ResourceStat = ResourceStat()
        var peerStats: [PeerID: ResourceStat] = [:]
        var protocolStats: [String: ResourceStat] = [:]
        var serviceStats: [String: ResourceStat] = [:]
    }

    init(configuration: ResourceLimitsConfiguration = .default) {
        self.config = configuration
        self.state = Mutex(ManagerState())
    }

    // MARK: - Scope Access

    var systemScope: ResourceScope {
        let stat = state.withLock { $0.systemStat }
        return SnapshotScope(name: "system", stat: stat, limits: config.system)
    }

    func peerScope(for peer: PeerID) -> ResourceScope {
        let stat = state.withLock { $0.peerStats[peer] ?? ResourceStat() }
        let limits = config.effectivePeerLimits(for: peer)
        return SnapshotScope(name: "peer:\(peer.shortDescription)", stat: stat, limits: limits)
    }

    func protocolScope(for protocolID: String) -> ResourceScope {
        let stat = state.withLock { $0.protocolStats[protocolID] ?? ResourceStat() }
        let limits = config.effectiveProtocolLimits(for: protocolID)
        return SnapshotScope(name: "protocol:\(protocolID)", stat: stat, limits: limits)
    }

    func serviceScope(for service: String) -> ResourceScope {
        let stat = state.withLock { $0.serviceStats[service] ?? ResourceStat() }
        let limits = config.effectiveServiceLimits(for: service)
        return SnapshotScope(name: "service:\(service)", stat: stat, limits: limits)
    }

    // MARK: - Connection Reservations

    func reserveInboundConnection(from peer: PeerID) throws {
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

    func reserveOutboundConnection(to peer: PeerID) throws {
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

    func releaseConnection(peer: PeerID, direction: ConnectionDirection) {
        state.withLock { s in
            switch direction {
            case .inbound:
                s.systemStat.inboundConnections = max(0, s.systemStat.inboundConnections - 1)
                if var peerStat = s.peerStats[peer] {
                    peerStat.inboundConnections = max(0, peerStat.inboundConnections - 1)
                    s.peerStats[peer] = peerStat
                }
            case .outbound:
                s.systemStat.outboundConnections = max(0, s.systemStat.outboundConnections - 1)
                if var peerStat = s.peerStats[peer] {
                    peerStat.outboundConnections = max(0, peerStat.outboundConnections - 1)
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

    func reserveInboundStream(from peer: PeerID) throws {
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

    func reserveOutboundStream(to peer: PeerID) throws {
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

    func releaseStream(peer: PeerID, direction: ConnectionDirection) {
        state.withLock { s in
            switch direction {
            case .inbound:
                s.systemStat.inboundStreams = max(0, s.systemStat.inboundStreams - 1)
                if var peerStat = s.peerStats[peer] {
                    peerStat.inboundStreams = max(0, peerStat.inboundStreams - 1)
                    s.peerStats[peer] = peerStat
                }
            case .outbound:
                s.systemStat.outboundStreams = max(0, s.systemStat.outboundStreams - 1)
                if var peerStat = s.peerStats[peer] {
                    peerStat.outboundStreams = max(0, peerStat.outboundStreams - 1)
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

    func reserveStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) throws {
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

    func releaseStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) {
        state.withLock { s in
            switch direction {
            case .inbound:
                s.systemStat.inboundStreams = max(0, s.systemStat.inboundStreams - 1)
                if var peerStat = s.peerStats[peer] {
                    peerStat.inboundStreams = max(0, peerStat.inboundStreams - 1)
                    s.peerStats[peer] = peerStat
                }
                if var protoStat = s.protocolStats[protocolID] {
                    protoStat.inboundStreams = max(0, protoStat.inboundStreams - 1)
                    s.protocolStats[protocolID] = protoStat
                }
            case .outbound:
                s.systemStat.outboundStreams = max(0, s.systemStat.outboundStreams - 1)
                if var peerStat = s.peerStats[peer] {
                    peerStat.outboundStreams = max(0, peerStat.outboundStreams - 1)
                    s.peerStats[peer] = peerStat
                }
                if var protoStat = s.protocolStats[protocolID] {
                    protoStat.outboundStreams = max(0, protoStat.outboundStreams - 1)
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

    func reserveMemory(_ bytes: Int, for peer: PeerID) throws {
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

    func releaseMemory(_ bytes: Int, for peer: PeerID) {
        state.withLock { s in
            s.systemStat.memory = max(0, s.systemStat.memory - bytes)
            if var peerStat = s.peerStats[peer] {
                peerStat.memory = max(0, peerStat.memory - bytes)
                s.peerStats[peer] = peerStat
            }

            // Garbage-collect peer entry if all counters are zero
            if s.peerStats[peer]?.isZero == true {
                s.peerStats.removeValue(forKey: peer)
            }
        }
    }

    // MARK: - Service Memory Reservations

    func reserveServiceMemory(_ bytes: Int, service: String) throws {
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

    func releaseServiceMemory(_ bytes: Int, service: String) {
        state.withLock { s in
            s.systemStat.memory = max(0, s.systemStat.memory - bytes)
            if var svcStat = s.serviceStats[service] {
                svcStat.memory = max(0, svcStat.memory - bytes)
                s.serviceStats[service] = svcStat
            }

            // Garbage-collect service entry if all counters are zero
            if s.serviceStats[service]?.isZero == true {
                s.serviceStats.removeValue(forKey: service)
            }
        }
    }

    // MARK: - Snapshot

    func snapshot() -> ResourceSnapshot {
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
