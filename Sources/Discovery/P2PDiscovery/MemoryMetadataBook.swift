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
public final class MemoryMetadataBook: MetadataBook, Sendable {

    private let state: Mutex<State>
    private let broadcaster = EventBroadcaster<MetadataBookEvent>()

    private struct State: Sendable {
        /// Per-peer metadata stored as JSON-encoded Data keyed by string name.
        var metadata: [PeerID: [String: Data]] = [:]
    }

    /// Creates a new in-memory MetadataBook.
    public init() {
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
        let data = state.withLock { s in
            s.metadata[peer]?[key.name]
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
        state.withLock { s in
            if s.metadata[peer] == nil {
                s.metadata[peer] = [:]
            }
            s.metadata[peer]?[key.name] = data
        }
        broadcaster.emit(.metadataSet(peer, key: key.name))
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
            s.metadata.removeValue(forKey: peer) != nil
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
        }
        broadcaster.shutdown()
    }
}
