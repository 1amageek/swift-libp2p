/// LazyPushBuffer - Batching buffer for IHave notifications
///
/// Collects IHave entries destined for lazy peers and flushes them
/// in batches at configurable intervals to reduce per-message overhead.

import P2PCore
import Synchronization

/// A thread-safe buffer for batching IHave notifications.
///
/// When the Plumtree router decides to send IHave to lazy peers,
/// entries are added to this buffer. The service layer periodically
/// calls `flush()` to collect and send batched notifications.
final class LazyPushBuffer: Sendable {

    private let state: Mutex<BufferState>
    private let maxBatchSize: Int
    private let maxTotalEntries: Int

    struct BufferState: Sendable {
        var pending: [PeerID: [PlumtreeIHaveEntry]]
        var totalCount: Int = 0
    }

    /// Creates a new lazy push buffer.
    ///
    /// - Parameters:
    ///   - maxBatchSize: Maximum entries per peer per flush
    ///   - maxTotalEntries: Maximum total entries across all peers (default: 10000)
    init(maxBatchSize: Int, maxTotalEntries: Int = 10000) {
        self.maxBatchSize = maxBatchSize
        self.maxTotalEntries = maxTotalEntries
        self.state = Mutex(BufferState(pending: [:]))
    }

    /// Adds an IHave entry for a peer.
    ///
    /// - Parameters:
    ///   - entry: The IHave entry to add
    ///   - peer: The peer to send it to
    func add(_ entry: PlumtreeIHaveEntry, for peer: PeerID) {
        state.withLock { s in
            guard s.totalCount < maxTotalEntries else { return }
            if (s.pending[peer]?.count ?? 0) < maxBatchSize {
                s.pending[peer, default: []].append(entry)
                s.totalCount += 1
            }
        }
    }

    /// Adds an IHave entry for multiple peers.
    ///
    /// - Parameters:
    ///   - entry: The IHave entry to add
    ///   - peers: The peers to send it to
    func add(_ entry: PlumtreeIHaveEntry, for peers: [PeerID]) {
        state.withLock { s in
            for peer in peers {
                guard s.totalCount < maxTotalEntries else { return }
                if (s.pending[peer]?.count ?? 0) < maxBatchSize {
                    s.pending[peer, default: []].append(entry)
                    s.totalCount += 1
                }
            }
        }
    }

    /// Flushes all pending entries and returns them grouped by peer.
    ///
    /// - Returns: Dictionary mapping peer IDs to their IHave entries
    func flush() -> [PeerID: [PlumtreeIHaveEntry]] {
        state.withLock { s in
            let result = s.pending
            s.pending.removeAll()
            s.totalCount = 0
            return result
        }
    }

    /// Removes all pending entries for a peer.
    ///
    /// - Parameter peer: The peer to remove entries for
    func remove(peer: PeerID) {
        state.withLock { s in
            if let removed = s.pending.removeValue(forKey: peer) {
                s.totalCount -= removed.count
            }
        }
    }

    /// Removes all pending entries.
    func clear() {
        state.withLock { s in
            s.pending.removeAll()
            s.totalCount = 0
        }
    }

    /// The total number of pending entries across all peers.
    var totalCount: Int {
        state.withLock { $0.totalCount }
    }

    /// The number of peers with pending entries.
    var peerCount: Int {
        state.withLock { $0.pending.count }
    }
}
