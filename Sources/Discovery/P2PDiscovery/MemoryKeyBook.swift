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
public final class MemoryKeyBook: KeyBook, Sendable {

    private let state: Mutex<[PeerID: PublicKey]>

    /// Creates a new in-memory KeyBook.
    public init() {
        self.state = Mutex([:])
    }

    public func publicKey(for peer: PeerID) async -> PublicKey? {
        let stored = state.withLock { $0[peer] }
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
        state.withLock { $0[peer] = key }
    }

    public func removePublicKey(for peer: PeerID) async {
        _ = state.withLock { $0.removeValue(forKey: peer) }
    }

    public func removePeer(_ peer: PeerID) async {
        _ = state.withLock { $0.removeValue(forKey: peer) }
    }

    public func peersWithKeys() async -> [PeerID] {
        state.withLock { Array($0.keys) }
    }
}
