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

    struct BufferState: Sendable {
        var pending: [PeerID: [PlumtreeIHaveEntry]]
    }

    /// Creates a new lazy push buffer.
    ///
    /// - Parameter maxBatchSize: Maximum entries per peer per flush
    init(maxBatchSize: Int) {
        self.maxBatchSize = maxBatchSize
        self.state = Mutex(BufferState(pending: [:]))
    }

    /// Adds an IHave entry for a peer.
    ///
    /// - Parameters:
    ///   - entry: The IHave entry to add
    ///   - peer: The peer to send it to
    func add(_ entry: PlumtreeIHaveEntry, for peer: PeerID) {
        state.withLock { s in
            var entries = s.pending[peer, default: []]
            if entries.count < maxBatchSize {
                entries.append(entry)
                s.pending[peer] = entries
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
                var entries = s.pending[peer, default: []]
                if entries.count < maxBatchSize {
                    entries.append(entry)
                    s.pending[peer] = entries
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
            return result
        }
    }

    /// Removes all pending entries for a peer.
    ///
    /// - Parameter peer: The peer to remove entries for
    func remove(peer: PeerID) {
        state.withLock { _ = $0.pending.removeValue(forKey: peer) }
    }

    /// Removes all pending entries.
    func clear() {
        state.withLock { $0.pending.removeAll() }
    }

    /// The total number of pending entries across all peers.
    var totalCount: Int {
        state.withLock { s in
            s.pending.values.reduce(0) { $0 + $1.count }
        }
    }

    /// The number of peers with pending entries.
    var peerCount: Int {
        state.withLock { $0.pending.count }
    }
}
