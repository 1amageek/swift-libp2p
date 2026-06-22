/// P2PDiscovery - MemoryKeyBook
///
/// In-memory implementation of KeyBook using Mutex for thread-safe,
/// high-frequency internal access.

import P2PCore
import Synchronization

// MARK: - MemoryKeyBook

/// In-memory implementation of KeyBook.
///
/// Uses `Mutex` for thread-safe access (high-frequency internal pattern).
/// Falls back to PeerID identity extraction when no key is explicitly stored.
///
/// Bounded by peer count with LRU eviction (mirrors `MemoryPeerStore`) so that
/// a Sybil flood of distinct peers cannot grow the map without limit.
public final class MemoryKeyBook: KeyBook, Sendable {

    /// Default cap on the number of stored keys.
    public static let defaultMaxPeers = 4096

    private struct State: Sendable {
        var keys: [PeerID: PublicKey] = [:]
        var accessOrder = LRUOrder<PeerID>()
    }

    private let state: Mutex<State>
    private let maxPeers: Int

    /// Creates a new in-memory KeyBook.
    public init(maxPeers: Int = MemoryKeyBook.defaultMaxPeers) {
        precondition(maxPeers > 0, "maxPeers must be positive")
        self.maxPeers = maxPeers
        self.state = Mutex(State())
    }

    public func publicKey(for peer: PeerID) async -> PublicKey? {
        let stored = state.withLock { s -> PublicKey? in
            guard let key = s.keys[peer] else { return nil }
            s.accessOrder.touch(peer)
            return key
        }
        if let stored { return stored }
        // Fallback: extract from identity-encoded PeerID
        do {
            return try peer.extractPublicKey()
        } catch {
            return nil
        }
    }

    public func setPublicKey(_ key: PublicKey, for peer: PeerID) async throws {
        let derived = PeerID(publicKey: key)
        guard derived == peer else {
            throw KeyBookError.peerIDMismatch(expected: peer, derived: derived)
        }
        state.withLock { s in
            if s.keys[peer] == nil {
                evictIfNeeded(&s)
            }
            s.keys[peer] = key
            s.accessOrder.insert(peer)
        }
    }

    public func removePublicKey(for peer: PeerID) async {
        state.withLock { s in
            if s.keys.removeValue(forKey: peer) != nil {
                s.accessOrder.remove(peer)
            }
        }
    }

    public func removePeer(_ peer: PeerID) async {
        state.withLock { s in
            if s.keys.removeValue(forKey: peer) != nil {
                s.accessOrder.remove(peer)
            }
        }
    }

    public func peersWithKeys() async -> [PeerID] {
        state.withLock { Array($0.keys.keys) }
    }

    // MARK: - Private

    /// Evicts the least-recently-used key when the map is at capacity.
    private func evictIfNeeded(_ s: inout State) {
        while s.keys.count >= maxPeers, let oldest = s.accessOrder.removeOldest() {
            s.keys.removeValue(forKey: oldest)
        }
    }
}
