/// P2PDiscovery - MemoryProtoBook
///
/// In-memory implementation of ProtoBook using Mutex for thread-safe,
/// high-frequency internal access.

import P2PCore
import Synchronization

// MARK: - MemoryProtoBook

/// In-memory implementation of ProtoBook.
///
/// Uses `Mutex` for thread-safe access (high-frequency internal pattern).
///
/// Bounded by peer count with LRU eviction (mirrors `MemoryPeerStore`) so that
/// a Sybil flood of distinct peers cannot grow the maps without limit. The
/// per-peer protocol set is additionally capped.
public final class MemoryProtoBook: ProtoBook, Sendable {

    /// Default cap on the number of peers tracked.
    public static let defaultMaxPeers = 4096
    /// Default cap on the number of protocols stored per peer.
    public static let defaultMaxProtocolsPerPeer = 64

    private let state: Mutex<State>
    private let maxPeers: Int
    private let maxProtocolsPerPeer: Int

    private struct State: Sendable {
        var protocols: [PeerID: Set<String>] = [:]
        /// Reverse index: protocol ID → peers supporting it
        var protocolPeers: [String: Set<PeerID>] = [:]
        var accessOrder = LRUOrder<PeerID>()
    }

    /// Creates a new in-memory ProtoBook.
    public init(
        maxPeers: Int = MemoryProtoBook.defaultMaxPeers,
        maxProtocolsPerPeer: Int = MemoryProtoBook.defaultMaxProtocolsPerPeer
    ) {
        precondition(maxPeers > 0, "maxPeers must be positive")
        precondition(maxProtocolsPerPeer > 0, "maxProtocolsPerPeer must be positive")
        self.maxPeers = maxPeers
        self.maxProtocolsPerPeer = maxProtocolsPerPeer
        self.state = Mutex(State())
    }

    public func protocols(for peer: PeerID) async -> [String] {
        state.withLock { s in
            guard let set = s.protocols[peer] else { return [] }
            s.accessOrder.touch(peer)
            return Array(set)
        }
    }

    public func setProtocols(_ protocols: [String], for peer: PeerID) async {
        state.withLock { s in
            let isNew = s.protocols[peer] == nil
            if isNew {
                evictPeerIfNeeded(&s)
            }
            // Remove peer from old reverse index entries
            if let oldProtocols = s.protocols[peer] {
                for proto in oldProtocols {
                    s.protocolPeers[proto]?.remove(peer)
                    if s.protocolPeers[proto]?.isEmpty == true {
                        s.protocolPeers.removeValue(forKey: proto)
                    }
                }
            }
            // Set new protocols (cap the per-peer set size)
            let newSet = Set(protocols.prefix(maxProtocolsPerPeer))
            s.protocols[peer] = newSet
            // Add peer to new reverse index entries
            for proto in newSet {
                s.protocolPeers[proto, default: []].insert(peer)
            }
            s.accessOrder.insert(peer)
        }
    }

    public func addProtocols(_ protocols: [String], for peer: PeerID) async {
        state.withLock { s in
            let isNew = s.protocols[peer] == nil
            if isNew {
                evictPeerIfNeeded(&s)
            }
            var set = s.protocols[peer] ?? []
            // Cap the per-peer set size: only admit protocols up to the cap.
            for proto in protocols {
                guard set.count < maxProtocolsPerPeer else { break }
                if set.insert(proto).inserted {
                    s.protocolPeers[proto, default: []].insert(peer)
                }
            }
            s.protocols[peer] = set
            s.accessOrder.insert(peer)
        }
    }

    public func removeProtocols(_ protocols: [String], from peer: PeerID) async {
        state.withLock { s in
            s.protocols[peer]?.subtract(protocols)
            // Update reverse index for removed protocols
            for proto in protocols {
                s.protocolPeers[proto]?.remove(peer)
                if s.protocolPeers[proto]?.isEmpty == true {
                    s.protocolPeers.removeValue(forKey: proto)
                }
            }
            if s.protocols[peer]?.isEmpty == true {
                s.protocols.removeValue(forKey: peer)
            }
        }
    }

    public func supportsProtocols(_ protocols: [String], for peer: PeerID) async -> [String] {
        state.withLock { s in
            guard let supported = s.protocols[peer] else { return [] }
            return protocols.filter { supported.contains($0) }
        }
    }

    public func firstSupportedProtocol(_ protocols: [String], for peer: PeerID) async -> String? {
        state.withLock { s in
            guard let supported = s.protocols[peer] else { return nil }
            return protocols.first { supported.contains($0) }
        }
    }

    public func removePeer(_ peer: PeerID) async {
        state.withLock { s in
            removePeerInternal(peer, &s)
        }
    }

    public func peers(supporting protocolID: String) async -> [PeerID] {
        state.withLock { s in
            Array(s.protocolPeers[protocolID] ?? [])
        }
    }

    // MARK: - Private

    /// Evicts least-recently-used peers when the map is at capacity.
    private func evictPeerIfNeeded(_ s: inout State) {
        while s.protocols.count >= maxPeers, let oldest = s.accessOrder.removeOldest() {
            removeProtocolsForPeer(oldest, &s)
        }
    }

    /// Removes a peer and updates both the LRU order and the reverse index.
    private func removePeerInternal(_ peer: PeerID, _ s: inout State) {
        s.accessOrder.remove(peer)
        removeProtocolsForPeer(peer, &s)
    }

    /// Removes a peer's protocols and updates the reverse index (no LRU change).
    private func removeProtocolsForPeer(_ peer: PeerID, _ s: inout State) {
        if let oldProtocols = s.protocols.removeValue(forKey: peer) {
            for proto in oldProtocols {
                s.protocolPeers[proto]?.remove(peer)
                if s.protocolPeers[proto]?.isEmpty == true {
                    s.protocolPeers.removeValue(forKey: proto)
                }
            }
        }
    }
}
