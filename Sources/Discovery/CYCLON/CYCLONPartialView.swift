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
            var candidates = Array(s.entries.values)
            if let excluded = excluding {
                candidates.removeAll { $0.peerID == excluded }
            }
            candidates.shuffle()
            return Array(candidates.prefix(count))
        }
    }

    /// Adds an entry. If the view exceeds cacheSize, evicts the oldest.
    func add(_ entry: CYCLONEntry) {
        state.withLock { s in
            s.entries[entry.peerID] = entry
            evictIfNeeded(&s)
        }
    }

    /// Adds multiple entries. Skips self and duplicates.
    func addAll(_ entries: [CYCLONEntry], selfID: PeerID) {
        state.withLock { s in
            for entry in entries {
                guard entry.peerID != selfID else { continue }
                s.entries[entry.peerID] = entry
            }
            evictIfNeeded(&s)
        }
    }

    /// Removes an entry.
    @discardableResult
    func remove(_ peerID: PeerID) -> CYCLONEntry? {
        state.withLock { $0.entries.removeValue(forKey: peerID) }
    }

    /// Merges received entries after a shuffle exchange.
    ///
    /// Algorithm:
    /// 1. Remove entries we sent (they are now at the other node)
    /// 2. Add received entries (excluding self and already-known peers)
    /// 3. If over capacity, evict oldest entries
    func merge(
        received: [CYCLONEntry],
        sent: [CYCLONEntry],
        selfID: PeerID
    ) {
        state.withLock { s in
            // Step 1: Make room by removing entries we sent (that aren't in the received set)
            let receivedIDs = Set(received.map(\.peerID))
            for entry in sent {
                if !receivedIDs.contains(entry.peerID) && s.entries.count >= cacheSize {
                    s.entries.removeValue(forKey: entry.peerID)
                }
            }

            // Step 2: Add received entries
            for entry in received {
                guard entry.peerID != selfID else { continue }
                if s.entries[entry.peerID] == nil {
                    s.entries[entry.peerID] = entry
                }
            }

            // Step 3: Evict if still over capacity
            evictIfNeeded(&s)
        }
    }

    /// Removes all entries.
    func clear() {
        state.withLock { $0.entries.removeAll() }
    }

    // MARK: - Private

    private func evictIfNeeded(_ s: inout ViewState) {
        while s.entries.count > cacheSize {
            if let oldest = s.entries.values.max(by: { $0.age < $1.age }) {
                s.entries.removeValue(forKey: oldest.peerID)
            } else {
                break
            }
        }
    }
}
