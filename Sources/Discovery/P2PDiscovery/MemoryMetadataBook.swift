/// P2PDiscovery - MemoryMetadataBook
///
/// In-memory implementation of MetadataBook using Mutex for thread-safe,
/// high-frequency internal access. Events are distributed via EventBroadcaster
/// (multi-consumer, Discovery layer pattern).

import Foundation
import P2PCore
import Synchronization

// MARK: - MemoryMetadataBook

/// In-memory implementation of MetadataBook.
///
/// Uses `Mutex` for thread-safe access (high-frequency internal pattern).
/// Events are distributed via `EventBroadcaster` (multi-consumer).
///
/// Bounded against Sybil memory-DoS on three axes: peer count (LRU), number of
/// metadata keys per peer, and the byte size of each stored value.
public final class MemoryMetadataBook: MetadataBook, Sendable {

    /// Default cap on the number of peers tracked.
    public static let defaultMaxPeers = 4096
    /// Default cap on the number of metadata keys per peer.
    public static let defaultMaxKeysPerPeer = 64
    /// Default cap on the encoded byte size of a single metadata value.
    public static let defaultMaxValueSize = 64 * 1024

    private let state: Mutex<State>
    private let broadcaster = EventBroadcaster<MetadataBookEvent>()
    private let maxPeers: Int
    private let maxKeysPerPeer: Int
    private let maxValueSize: Int

    private struct State: Sendable {
        /// Per-peer metadata stored as JSON-encoded Data keyed by string name.
        var metadata: [PeerID: [String: Data]] = [:]
        var accessOrder = LRUOrder<PeerID>()
    }

    /// Creates a new in-memory MetadataBook.
    public init(
        maxPeers: Int = MemoryMetadataBook.defaultMaxPeers,
        maxKeysPerPeer: Int = MemoryMetadataBook.defaultMaxKeysPerPeer,
        maxValueSize: Int = MemoryMetadataBook.defaultMaxValueSize
    ) {
        precondition(maxPeers > 0, "maxPeers must be positive")
        precondition(maxKeysPerPeer > 0, "maxKeysPerPeer must be positive")
        precondition(maxValueSize > 0, "maxValueSize must be positive")
        self.maxPeers = maxPeers
        self.maxKeysPerPeer = maxKeysPerPeer
        self.maxValueSize = maxValueSize
        self.state = Mutex(State())
    }

    deinit {
        broadcaster.shutdown()
    }

    // MARK: - MetadataBook Protocol

    public var events: AsyncStream<MetadataBookEvent> {
        broadcaster.subscribe()
    }

    public func get<V: Sendable & Codable>(_ key: MetadataKey<V>, for peer: PeerID) -> V? {
        let data = state.withLock { s -> Data? in
            guard let data = s.metadata[peer]?[key.name] else { return nil }
            s.accessOrder.touch(peer)
            return data
        }
        guard let data else { return nil }
        do {
            return try JSONDecoder().decode(V.self, from: data)
        } catch {
            // Data is corrupted or type mismatch - return nil
            return nil
        }
    }

    public func set<V: Sendable & Codable>(_ key: MetadataKey<V>, value: V, for peer: PeerID) {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            // Encoding failure indicates a programming error in the type's Codable conformance.
            // Skip silently rather than crash.
            return
        }

        // Bound the encoded value size before storing.
        guard data.count <= maxValueSize else {
            broadcaster.emit(.metadataRejected(
                peer, key: key.name,
                reason: "value size \(data.count) exceeds cap \(maxValueSize)"
            ))
            return
        }

        let event: MetadataBookEvent = state.withLock { s in
            if var peerMeta = s.metadata[peer] {
                // Existing peer: enforce the per-peer key cap for new keys.
                if peerMeta[key.name] == nil, peerMeta.count >= maxKeysPerPeer {
                    return .metadataRejected(
                        peer, key: key.name,
                        reason: "per-peer key cap \(maxKeysPerPeer) reached"
                    )
                }
                peerMeta[key.name] = data
                s.metadata[peer] = peerMeta
                s.accessOrder.touch(peer)
                return .metadataSet(peer, key: key.name)
            } else {
                // New peer: evict LRU peers if at capacity, then insert.
                evictIfNeeded(&s)
                s.metadata[peer] = [key.name: data]
                s.accessOrder.insert(peer)
                return .metadataSet(peer, key: key.name)
            }
        }
        broadcaster.emit(event)
    }

    public func remove(key: String, for peer: PeerID) {
        let removed = state.withLock { s -> Bool in
            s.metadata[peer]?.removeValue(forKey: key) != nil
        }
        if removed {
            broadcaster.emit(.metadataRemoved(peer, key: key))
        }
    }

    public func removePeer(_ peer: PeerID) {
        let hadData = state.withLock { s -> Bool in
            if s.metadata.removeValue(forKey: peer) != nil {
                s.accessOrder.remove(peer)
                return true
            }
            return false
        }
        if hadData {
            broadcaster.emit(.peerRemoved(peer))
        }
    }

    public func keys(for peer: PeerID) -> [String] {
        state.withLock { s in
            guard let peerMeta = s.metadata[peer] else { return [] }
            return Array(peerMeta.keys)
        }
    }

    public func shutdown() {
        state.withLock { s in
            s.metadata.removeAll()
            s.accessOrder.removeAll()
        }
        broadcaster.shutdown()
    }

    // MARK: - Private

    /// Evicts least-recently-used peers when the map is at capacity.
    private func evictIfNeeded(_ s: inout State) {
        while s.metadata.count >= maxPeers, let oldest = s.accessOrder.removeOldest() {
            s.metadata.removeValue(forKey: oldest)
        }
    }
}
