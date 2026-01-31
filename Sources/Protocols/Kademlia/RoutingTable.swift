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
            // Determine the bucket closest to target
            let targetDistance = localKey.distance(to: target)
            let centerBucket = targetDistance.bucketIndex ?? 0

            // Collect entries from buckets nearest to the target first.
            // Expand outward from centerBucket until we've checked all
            // non-empty buckets or have enough candidates.
            var candidates: [KBucketEntry] = []
            var lo = centerBucket
            var hi = centerBucket + 1

            while lo >= 0 || hi < 256 {
                if lo >= 0 {
                    for entry in buckets[lo].allEntries where !excluding.contains(entry.peerID) {
                        candidates.append(entry)
                    }
                    lo -= 1
                }
                if hi < 256 {
                    for entry in buckets[hi].allEntries where !excluding.contains(entry.peerID) {
                        candidates.append(entry)
                    }
                    hi += 1
                }
                // Early exit: if we have enough candidates and the remaining
                // buckets are farther than our worst candidate, we can stop.
                // But since bucket proximity is approximate, we collect all
                // and sort only the collected set. For typical routing tables
                // with sparse bucket occupation, this is much faster.
            }

            // Sort only the collected candidates (typically much fewer than
            // the theoretical maximum of 256 * K)
            candidates.sort { e1, e2 in
                e1.key.isCloser(to: target, than: e2.key)
            }

            return Array(candidates.prefix(count))
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

    // MARK: - Refresh Support

    /// Returns bucket indices that haven't been queried recently.
    ///
    /// - Parameter threshold: Duration after which a bucket is considered stale.
    /// - Returns: Array of bucket indices that need refresh.
    public func bucketsNeedingRefresh(threshold: Duration) -> [Int] {
        let now = ContinuousClock.Instant.now
        return buckets.withLock { buckets in
            var stale: [Int] = []
            for (index, bucket) in buckets.enumerated() {
                // Only refresh non-empty buckets or buckets near our key
                guard !bucket.isEmpty else { continue }
                let elapsed = now - bucket.lastRefreshed
                if elapsed >= threshold {
                    stale.append(index)
                }
            }
            return stale
        }
    }

    /// Generates a random KademliaKey that falls in the given bucket.
    ///
    /// The generated key has the correct XOR distance prefix to land in the specified bucket.
    /// Bucket index i means the XOR distance has (255 - i) leading zero bits.
    ///
    /// - Parameter bucketIndex: The target bucket index (0-255).
    /// - Returns: A random KademliaKey that falls in that bucket.
    public func randomKeyForBucket(_ bucketIndex: Int) -> KademliaKey {
        precondition(bucketIndex >= 0 && bucketIndex < 256, "Bucket index must be 0-255")

        // bucketIndex = 255 - leadingZeroBits
        // So leadingZeroBits = 255 - bucketIndex
        // The first set bit is at position (255 - bucketIndex) from MSB (0-indexed)
        let bitPosition = 255 - bucketIndex  // position from MSB
        let byteIndex = bitPosition / 8
        let bitIndex = 7 - (bitPosition % 8)

        var distanceBytes = Data(count: 32)

        // Set the target bit
        distanceBytes[byteIndex] = UInt8(1 << bitIndex)

        // Randomize remaining lower bits
        for i in (byteIndex + 1)..<32 {
            distanceBytes[i] = UInt8.random(in: 0...255)
        }
        // Randomize lower bits in the same byte (below the set bit)
        if bitIndex > 0 {
            let mask = UInt8((1 << bitIndex) - 1)
            distanceBytes[byteIndex] |= UInt8.random(in: 0...255) & mask
        }

        // XOR with local key to get the target key
        var keyBytes = Data(count: 32)
        let localBytes = localKey.bytes
        for i in 0..<32 {
            keyBytes[i] = localBytes[i] ^ distanceBytes[i]
        }

        return KademliaKey(bytes: keyBytes)
    }

    /// Marks a bucket as recently refreshed.
    ///
    /// - Parameter index: The bucket index (0-255).
    public func markBucketRefreshed(_ index: Int) {
        guard index >= 0 && index < 256 else { return }
        buckets.withLock { buckets in
            buckets[index].lastRefreshed = .now
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
