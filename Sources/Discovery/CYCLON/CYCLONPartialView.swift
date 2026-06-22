/// Thread-safe partial view data structure for CYCLON.
///
/// Uses class + Mutex for high-frequency access from shuffle operations.

import P2PCore
import Synchronization

final class CYCLONPartialView: Sendable {

    private let state: Mutex<ViewState>
    private let cacheSize: Int

    struct ViewState: Sendable {
        var entries: [PeerID: CYCLONEntry]
        /// Local insertion order. Eviction uses THIS (oldest insertion first),
        /// never the attacker-supplied `age` field, so a remote peer cannot
        /// poison eviction by claiming a huge age for legitimate peers.
        var insertionOrder = LRUOrder<PeerID>()
    }

    init(cacheSize: Int) {
        self.cacheSize = cacheSize
        self.state = Mutex(ViewState(entries: [:]))
    }

    /// The number of entries in the view.
    var count: Int {
        state.withLock { $0.entries.count }
    }

    /// Whether the view is empty.
    var isEmpty: Bool {
        state.withLock { $0.entries.isEmpty }
    }

    /// Returns all entries as an array.
    func allEntries() -> [CYCLONEntry] {
        state.withLock { Array($0.entries.values) }
    }

    /// Returns all known peer IDs.
    func allPeerIDs() -> [PeerID] {
        state.withLock { Array($0.entries.keys) }
    }

    /// Returns the entry for a specific peer, if present.
    func entry(for peerID: PeerID) -> CYCLONEntry? {
        state.withLock { $0.entries[peerID] }
    }

    /// Increments the age of all entries by 1.
    func incrementAges() {
        state.withLock { s in
            for key in s.entries.keys {
                s.entries[key]?.age += 1
            }
        }
    }

    /// Returns the entry with the highest age (oldest).
    func oldest() -> CYCLONEntry? {
        state.withLock { s in
            s.entries.values.max(by: { $0.age < $1.age })
        }
    }

    /// Returns a random subset of entries, optionally excluding a peer.
    func randomSubset(count: Int, excluding: PeerID? = nil) -> [CYCLONEntry] {
        state.withLock { s in
            let values: any Collection<CYCLONEntry>
            if let excluded = excluding {
                values = s.entries.values.lazy.filter { $0.peerID != excluded }
            } else {
                values = s.entries.values
            }
            // Use Fisher-Yates partial shuffle on array to avoid full shuffle
            var candidates = Array(values)
            let n = min(count, candidates.count)
            for i in 0..<n {
                let j = Int.random(in: i..<candidates.count)
                if i != j { candidates.swapAt(i, j) }
            }
            return Array(candidates.prefix(n))
        }
    }

    /// Adds an entry. If the view exceeds cacheSize, evicts the oldest insertion.
    func add(_ entry: CYCLONEntry) {
        state.withLock { s in
            insert(entry, &s)
            evictIfNeeded(&s)
        }
    }

    /// Adds multiple entries. Skips self and duplicates.
    /// Received `age` is reset to 0: age is a LOCAL freshness counter advanced
    /// by `incrementAges()`, never a value to be trusted from a remote peer.
    func addAll(_ entries: [CYCLONEntry], selfID: PeerID) {
        state.withLock { s in
            for entry in entries {
                guard entry.peerID != selfID else { continue }
                insert(sanitized(entry), &s)
            }
            evictIfNeeded(&s)
        }
    }

    /// Removes an entry.
    @discardableResult
    func remove(_ peerID: PeerID) -> CYCLONEntry? {
        state.withLock { s in
            s.insertionOrder.remove(peerID)
            return s.entries.removeValue(forKey: peerID)
        }
    }

    /// Merges received entries after a shuffle exchange.
    ///
    /// Algorithm:
    /// 1. Remove entries we sent (they are now at the other node)
    /// 2. Add received entries (excluding self and already-known peers), with
    ///    their `age` reset to 0 (local-only freshness; never trust remote age)
    /// 3. If over capacity, evict by LOCAL insertion order (oldest first)
    ///
    /// Eviction by insertion order (rather than by the wire `age`) prevents an
    /// eclipse attack where a malicious peer claims a huge age for our existing
    /// legitimate peers to force them all out of the view.
    func merge(
        received: [CYCLONEntry],
        sent: [CYCLONEntry],
        selfID: PeerID
    ) {
        state.withLock { s in
            // Dedupe received against self and the entries we sent: an attacker
            // could otherwise echo our own sent entries back to inflate churn.
            let sentIDs = Set(sent.map(\.peerID))
            let receivedIDs = Set(received.map(\.peerID))

            // Step 1: Make room by removing entries we sent (that aren't in the received set)
            for entry in sent {
                if !receivedIDs.contains(entry.peerID) && s.entries.count >= cacheSize {
                    s.insertionOrder.remove(entry.peerID)
                    s.entries.removeValue(forKey: entry.peerID)
                }
            }

            // Step 2: Add received entries (skip self, skip ones we just sent,
            // skip already-known peers), resetting age to 0.
            for entry in received {
                guard entry.peerID != selfID else { continue }
                guard !sentIDs.contains(entry.peerID) else { continue }
                if s.entries[entry.peerID] == nil {
                    insert(sanitized(entry), &s)
                }
            }

            // Step 3: Evict if still over capacity (by insertion order)
            evictIfNeeded(&s)
        }
    }

    /// Removes all entries.
    func clear() {
        state.withLock { s in
            s.entries.removeAll()
            s.insertionOrder.removeAll()
        }
    }

    // MARK: - Private

    /// Inserts/updates an entry and records its local insertion order.
    private func insert(_ entry: CYCLONEntry, _ s: inout ViewState) {
        s.entries[entry.peerID] = entry
        s.insertionOrder.insert(entry.peerID)
    }

    /// Returns a copy of the entry with `age` reset to 0 so remote-supplied age
    /// can never influence local eviction or scoring.
    private func sanitized(_ entry: CYCLONEntry) -> CYCLONEntry {
        CYCLONEntry(peerID: entry.peerID, addresses: entry.addresses, age: 0)
    }

    /// Evicts entries over capacity by local insertion order (oldest first).
    private func evictIfNeeded(_ s: inout ViewState) {
        while s.entries.count > cacheSize, let oldest = s.insertionOrder.removeOldest() {
            s.entries.removeValue(forKey: oldest)
        }
    }
}
