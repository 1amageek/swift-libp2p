/// KBucket - A single k-bucket for Kademlia routing table.

import Foundation
import P2PCore

/// An entry in the k-bucket.
public struct KBucketEntry: Sendable, Equatable {
    /// The peer ID.
    public let peerID: PeerID

    /// The Kademlia key derived from the peer ID.
    public let key: KademliaKey

    /// Known addresses for the peer.
    public var addresses: [Multiaddr]

    /// When the peer was last seen.
    public var lastSeen: ContinuousClock.Instant

    /// Creates a new entry.
    public init(peerID: PeerID, addresses: [Multiaddr] = []) {
        self.peerID = peerID
        self.key = KademliaKey(from: peerID)
        self.addresses = addresses
        self.lastSeen = .now
    }

    /// Updates the last seen time.
    public mutating func touch() {
        lastSeen = .now
    }

    /// Adds an address if not already present.
    public mutating func addAddress(_ addr: Multiaddr) {
        if !addresses.contains(addr) {
            addresses.append(addr)
        }
    }
}

/// A single k-bucket in the Kademlia routing table.
///
/// Holds up to K peers within a certain distance range from the local node.
/// Peers are ordered by last-seen time (most recently seen at the end).
public struct KBucket: Sendable {
    /// Maximum entries in the bucket.
    public let maxSize: Int

    /// The entries in the bucket, ordered by last-seen (oldest first).
    private var entries: [KBucketEntry]

    /// Pending entries waiting for space (replacement cache).
    private var pending: [KBucketEntry]

    /// Maximum pending entries.
    private let maxPending: Int

    /// Creates a new k-bucket.
    public init(maxSize: Int = KademliaProtocol.kValue, maxPending: Int = 3) {
        self.maxSize = maxSize
        self.maxPending = maxPending
        self.entries = []
        self.pending = []
    }

    /// Number of entries in the bucket.
    public var count: Int { entries.count }

    /// Whether the bucket is full.
    public var isFull: Bool { entries.count >= maxSize }

    /// Whether the bucket is empty.
    public var isEmpty: Bool { entries.isEmpty }

    /// All entries in the bucket.
    public var allEntries: [KBucketEntry] { entries }

    /// Gets an entry by peer ID.
    public func entry(for peerID: PeerID) -> KBucketEntry? {
        entries.first { $0.peerID == peerID }
    }

    /// Result of an insert operation.
    public enum InsertResult: Sendable {
        /// Entry was inserted.
        case inserted
        /// Entry was updated (already present).
        case updated
        /// Bucket is full, entry added to pending.
        case pending
        /// Entry is the local node (rejected).
        case selfEntry
    }

    /// Inserts or updates a peer in the bucket.
    ///
    /// - Parameters:
    ///   - peerID: The peer to insert.
    ///   - addresses: Known addresses for the peer.
    /// - Returns: The result of the operation.
    public mutating func insert(_ peerID: PeerID, addresses: [Multiaddr] = []) -> InsertResult {
        // Check if already present
        if let index = entries.firstIndex(where: { $0.peerID == peerID }) {
            // Update and move to end (most recently seen)
            var entry = entries.remove(at: index)
            entry.touch()
            for addr in addresses {
                entry.addAddress(addr)
            }
            entries.append(entry)
            return .updated
        }

        // Check pending list
        if let pendingIndex = pending.firstIndex(where: { $0.peerID == peerID }) {
            var entry = pending.remove(at: pendingIndex)
            entry.touch()
            for addr in addresses {
                entry.addAddress(addr)
            }
            pending.append(entry)
            return .pending
        }

        // Create new entry
        var entry = KBucketEntry(peerID: peerID, addresses: addresses)
        entry.touch()

        // Try to insert
        if entries.count < maxSize {
            entries.append(entry)
            return .inserted
        }

        // Bucket is full, add to pending
        if pending.count < maxPending {
            pending.append(entry)
        } else {
            // Replace oldest pending
            pending.removeFirst()
            pending.append(entry)
        }
        return .pending
    }

    /// Removes a peer from the bucket.
    ///
    /// - Parameter peerID: The peer to remove.
    /// - Returns: The removed entry, if found.
    @discardableResult
    public mutating func remove(_ peerID: PeerID) -> KBucketEntry? {
        if let index = entries.firstIndex(where: { $0.peerID == peerID }) {
            let removed = entries.remove(at: index)

            // Promote from pending if available
            if !pending.isEmpty {
                entries.append(pending.removeFirst())
            }

            return removed
        }

        // Check pending
        if let index = pending.firstIndex(where: { $0.peerID == peerID }) {
            return pending.remove(at: index)
        }

        return nil
    }

    /// Gets the oldest entry (candidate for eviction check).
    public var oldest: KBucketEntry? {
        entries.first
    }

    /// Evicts the oldest entry if the bucket is full and there are pending entries.
    ///
    /// - Returns: The evicted peer ID, if any.
    public mutating func evictOldest() -> PeerID? {
        guard isFull && !pending.isEmpty else { return nil }

        let evicted = entries.removeFirst()
        entries.append(pending.removeFirst())
        return evicted.peerID
    }

    /// Returns entries sorted by distance to a target key.
    ///
    /// - Parameter target: The target key.
    /// - Returns: Entries sorted by distance (closest first).
    public func entriesSorted(by target: KademliaKey) -> [KBucketEntry] {
        entries.sorted { e1, e2 in
            e1.key.isCloser(to: target, than: e2.key)
        }
    }
}
