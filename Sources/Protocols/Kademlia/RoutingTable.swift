/// RoutingTable - Kademlia routing table with 256 k-buckets.

import Foundation
import Synchronization
import P2PCore

/// A Kademlia routing table.
///
/// Contains 256 k-buckets, one for each bit of the 256-bit key space.
/// Bucket i contains peers whose XOR distance from the local node has
/// i leading zero bits.
public final class RoutingTable: Sendable {
    /// The local node's peer ID.
    public let localPeerID: PeerID

    /// The local node's Kademlia key.
    public let localKey: KademliaKey

    /// The k-buckets (256 total).
    private let buckets: Mutex<[KBucket]>

    /// Maximum entries per bucket.
    public let kValue: Int

    /// Creates a new routing table.
    ///
    /// - Parameters:
    ///   - localPeerID: The local node's peer ID.
    ///   - kValue: Maximum entries per bucket (default: 20).
    public init(localPeerID: PeerID, kValue: Int = KademliaProtocol.kValue) {
        self.localPeerID = localPeerID
        self.localKey = KademliaKey(from: localPeerID)
        self.kValue = kValue
        self.buckets = Mutex((0..<256).map { _ in KBucket(maxSize: kValue) })
    }

    // MARK: - Bucket Access

    /// Gets the bucket index for a peer.
    ///
    /// - Parameter peerID: The peer ID.
    /// - Returns: The bucket index (0-255), or nil if same as local.
    public func bucketIndex(for peerID: PeerID) -> Int? {
        let peerKey = KademliaKey(from: peerID)
        let distance = localKey.distance(to: peerKey)
        return distance.bucketIndex
    }

    /// Gets the bucket index for a key.
    ///
    /// - Parameter key: The Kademlia key.
    /// - Returns: The bucket index (0-255), or nil if same as local.
    public func bucketIndex(for key: KademliaKey) -> Int? {
        let distance = localKey.distance(to: key)
        return distance.bucketIndex
    }

    // MARK: - Peer Management

    /// Adds or updates a peer in the routing table.
    ///
    /// - Parameters:
    ///   - peerID: The peer to add.
    ///   - addresses: Known addresses for the peer.
    /// - Returns: The result of the insertion.
    @discardableResult
    public func addPeer(_ peerID: PeerID, addresses: [Multiaddr] = []) -> KBucket.InsertResult {
        // Don't add ourselves
        guard peerID != localPeerID else { return .selfEntry }

        guard let index = bucketIndex(for: peerID) else { return .selfEntry }

        return buckets.withLock { buckets in
            buckets[index].insert(peerID, addresses: addresses)
        }
    }

    /// Removes a peer from the routing table.
    ///
    /// - Parameter peerID: The peer to remove.
    /// - Returns: The removed entry, if found.
    @discardableResult
    public func removePeer(_ peerID: PeerID) -> KBucketEntry? {
        guard let index = bucketIndex(for: peerID) else { return nil }

        return buckets.withLock { buckets in
            buckets[index].remove(peerID)
        }
    }

    /// Gets an entry for a peer.
    ///
    /// - Parameter peerID: The peer ID.
    /// - Returns: The entry, if found.
    public func entry(for peerID: PeerID) -> KBucketEntry? {
        guard let index = bucketIndex(for: peerID) else { return nil }

        return buckets.withLock { buckets in
            buckets[index].entry(for: peerID)
        }
    }

    /// Checks if the routing table contains a peer.
    ///
    /// - Parameter peerID: The peer ID.
    /// - Returns: True if the peer is in the table.
    public func contains(_ peerID: PeerID) -> Bool {
        entry(for: peerID) != nil
    }

    // MARK: - Queries

    /// Returns the K closest peers to a target key.
    ///
    /// - Parameters:
    ///   - target: The target key.
    ///   - count: Maximum number of peers to return (default: K).
    ///   - excluding: Peers to exclude from the result.
    /// - Returns: Peers sorted by distance to target (closest first).
    public func closestPeers(
        to target: KademliaKey,
        count: Int = KademliaProtocol.kValue,
        excluding: Set<PeerID> = []
    ) -> [KBucketEntry] {
        buckets.withLock { buckets in
            // Collect all entries
            var allEntries: [KBucketEntry] = []
            for bucket in buckets {
                allEntries.append(contentsOf: bucket.allEntries)
            }

            // Filter excluded peers
            let filtered = allEntries.filter { !excluding.contains($0.peerID) }

            // Sort by distance to target
            let sorted = filtered.sorted { e1, e2 in
                e1.key.isCloser(to: target, than: e2.key)
            }

            return Array(sorted.prefix(count))
        }
    }

    /// Returns the K closest peers to a peer ID.
    ///
    /// - Parameters:
    ///   - peerID: The target peer ID.
    ///   - count: Maximum number of peers to return (default: K).
    ///   - excluding: Peers to exclude from the result.
    /// - Returns: Peers sorted by distance (closest first).
    public func closestPeers(
        to peerID: PeerID,
        count: Int = KademliaProtocol.kValue,
        excluding: Set<PeerID> = []
    ) -> [KBucketEntry] {
        let key = KademliaKey(from: peerID)
        return closestPeers(to: key, count: count, excluding: excluding)
    }

    /// Returns all peers in the routing table.
    ///
    /// - Returns: All entries in the table.
    public var allPeers: [KBucketEntry] {
        buckets.withLock { buckets in
            buckets.flatMap { $0.allEntries }
        }
    }

    /// Returns the total number of peers in the routing table.
    public var count: Int {
        buckets.withLock { buckets in
            buckets.reduce(0) { $0 + $1.count }
        }
    }

    /// Whether the routing table is empty.
    public var isEmpty: Bool {
        count == 0
    }

    // MARK: - Bucket Operations

    /// Returns peers in a specific bucket.
    ///
    /// - Parameter index: The bucket index (0-255).
    /// - Returns: Entries in that bucket.
    public func peersInBucket(_ index: Int) -> [KBucketEntry] {
        guard index >= 0 && index < 256 else { return [] }

        return buckets.withLock { buckets in
            buckets[index].allEntries
        }
    }

    /// Checks if a bucket is full.
    ///
    /// - Parameter index: The bucket index.
    /// - Returns: True if the bucket has K entries.
    public func isBucketFull(_ index: Int) -> Bool {
        guard index >= 0 && index < 256 else { return false }

        return buckets.withLock { buckets in
            buckets[index].isFull
        }
    }

    /// Gets the oldest entry in a bucket (candidate for liveness check).
    ///
    /// - Parameter index: The bucket index.
    /// - Returns: The oldest entry, if any.
    public func oldestInBucket(_ index: Int) -> KBucketEntry? {
        guard index >= 0 && index < 256 else { return nil }

        return buckets.withLock { buckets in
            buckets[index].oldest
        }
    }

    /// Evicts the oldest entry from a bucket if full and pending entries exist.
    ///
    /// - Parameter index: The bucket index.
    /// - Returns: The evicted peer ID, if any.
    public func evictOldestInBucket(_ index: Int) -> PeerID? {
        guard index >= 0 && index < 256 else { return nil }

        return buckets.withLock { buckets in
            buckets[index].evictOldest()
        }
    }

    // MARK: - Statistics

    /// Returns statistics about the routing table.
    public var statistics: RoutingTableStatistics {
        buckets.withLock { buckets in
            var nonEmptyBuckets = 0
            var fullBuckets = 0
            var totalPeers = 0

            for bucket in buckets {
                if !bucket.isEmpty {
                    nonEmptyBuckets += 1
                }
                if bucket.isFull {
                    fullBuckets += 1
                }
                totalPeers += bucket.count
            }

            return RoutingTableStatistics(
                totalPeers: totalPeers,
                totalBuckets: 256,
                nonEmptyBuckets: nonEmptyBuckets,
                fullBuckets: fullBuckets,
                kValue: kValue
            )
        }
    }
}

/// Statistics about a routing table.
public struct RoutingTableStatistics: Sendable {
    /// Total number of peers in the table.
    public let totalPeers: Int

    /// Total number of buckets (always 256).
    public let totalBuckets: Int

    /// Number of non-empty buckets.
    public let nonEmptyBuckets: Int

    /// Number of full buckets.
    public let fullBuckets: Int

    /// Maximum entries per bucket.
    public let kValue: Int

    /// Percentage of buckets that are non-empty.
    public var fillPercentage: Double {
        Double(nonEmptyBuckets) / Double(totalBuckets) * 100
    }

    /// Average peers per non-empty bucket.
    public var averagePeersPerBucket: Double {
        guard nonEmptyBuckets > 0 else { return 0 }
        return Double(totalPeers) / Double(nonEmptyBuckets)
    }
}
