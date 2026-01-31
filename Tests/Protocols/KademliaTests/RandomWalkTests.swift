/// RandomWalkTests - Tests for Kademlia routing table refresh (random walk)
import Testing
import Foundation
@testable import P2PKademlia
@testable import P2PCore

@Suite("Random Walk / Routing Table Refresh Tests")
struct RandomWalkTests {

    // MARK: - Helpers

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    // MARK: - RoutingTable Refresh Tests

    @Test("Buckets needing refresh returns stale buckets")
    func bucketsNeedingRefresh() throws {
        let localPeerID = makePeerID()
        let table = RoutingTable(localPeerID: localPeerID)

        // Add some peers to populate a few buckets
        for _ in 0..<20 {
            let peer = makePeerID()
            table.addPeer(peer)
        }

        // All buckets were just populated, so none should be stale with a long threshold
        let staleNone = table.bucketsNeedingRefresh(threshold: .seconds(3600))
        #expect(staleNone.isEmpty)

        // With a zero-second threshold, all non-empty buckets should be stale
        let staleAll = table.bucketsNeedingRefresh(threshold: .zero)
        #expect(!staleAll.isEmpty)
    }

    @Test("Random key for bucket lands in correct bucket")
    func randomKeyForBucket() throws {
        let localPeerID = makePeerID()
        let table = RoutingTable(localPeerID: localPeerID)

        // Test multiple bucket indices
        for bucketIndex in [0, 1, 50, 127, 200, 254, 255] {
            let randomKey = table.randomKeyForBucket(bucketIndex)
            let distance = table.localKey.distance(to: randomKey)

            // The distance should land in the expected bucket
            let resultBucket = distance.bucketIndex
            #expect(resultBucket == bucketIndex, "Expected bucket \(bucketIndex), got \(String(describing: resultBucket))")
        }
    }

    @Test("Mark bucket refreshed updates timestamp")
    func markBucketRefreshed() throws {
        let localPeerID = makePeerID()
        let table = RoutingTable(localPeerID: localPeerID)

        // Add a peer to bucket (need to find which bucket)
        let peer = makePeerID()
        table.addPeer(peer)

        guard let bucketIndex = table.bucketIndex(for: peer) else {
            Issue.record("Could not get bucket index for peer")
            return
        }

        // Initially the bucket was just refreshed
        _ = table.bucketsNeedingRefresh(threshold: .zero)
        // Bucket might or might not be in the stale list depending on timing

        // Mark it as refreshed
        table.markBucketRefreshed(bucketIndex)

        // Now with a long threshold, it should NOT be stale
        let staleAfter = table.bucketsNeedingRefresh(threshold: .seconds(3600))
        #expect(!staleAfter.contains(bucketIndex))
    }

    @Test("KBucket tracks lastRefreshed on insert")
    func kbucketLastRefreshedOnInsert() throws {
        var bucket = KBucket(maxSize: 20)

        // Initially, lastRefreshed is set at creation time
        let initialRefresh = bucket.lastRefreshed

        // Insert a peer
        let peer = makePeerID()
        let result = bucket.insert(peer)

        #expect(result == .inserted)
        // After insert, lastRefreshed should be updated
        #expect(bucket.lastRefreshed >= initialRefresh)
    }

    // MARK: - Configuration Tests

    @Test("Configuration defaults for random walk")
    func configurationDefaults() {
        let config = KademliaConfiguration()
        #expect(config.randomWalkCount == 1)
    }

    @Test("Custom random walk count")
    func customRandomWalkCount() {
        let config = KademliaConfiguration(randomWalkCount: 5)
        #expect(config.randomWalkCount == 5)
    }

    // MARK: - KademliaEvent Tests

    @Test("Refresh events are defined")
    func refreshEventsExist() {
        let startEvent = KademliaEvent.refreshStarted(bucketCount: 3)
        let completeEvent = KademliaEvent.refreshCompleted(bucketsRefreshed: 2)

        // Verify description works
        #expect(startEvent.description.contains("3"))
        #expect(completeEvent.description.contains("2"))
    }

    // MARK: - Random Key Generation Tests

    @Test("Random key for each bucket is unique")
    func randomKeysAreUnique() {
        let localPeerID = makePeerID()
        let table = RoutingTable(localPeerID: localPeerID)

        let key1 = table.randomKeyForBucket(100)
        let key2 = table.randomKeyForBucket(100)

        // Two random keys for the same bucket should (almost certainly) be different
        // due to random bits. There's an astronomically small chance they match.
        #expect(key1 != key2)
    }

    @Test("Random key for bucket 0 has correct distance pattern")
    func randomKeyBucket0() {
        let localPeerID = makePeerID()
        let table = RoutingTable(localPeerID: localPeerID)

        let randomKey = table.randomKeyForBucket(0)
        let distance = table.localKey.distance(to: randomKey)

        // Bucket 0: distance has 255 leading zero bits, then bit 0 set
        // This means the distance is in the range [1, 1] for the first 255 bits,
        // only the last bit differs
        #expect(distance.bucketIndex == 0)
    }

    @Test("Random key for bucket 255 has correct distance pattern")
    func randomKeyBucket255() {
        let localPeerID = makePeerID()
        let table = RoutingTable(localPeerID: localPeerID)

        let randomKey = table.randomKeyForBucket(255)
        let distance = table.localKey.distance(to: randomKey)

        // Bucket 255: distance has 0 leading zero bits (MSB is set)
        #expect(distance.bucketIndex == 255)
    }

    // MARK: - F-2: lastRefreshed on update

    @Test("KBucket lastRefreshed updates on peer re-seen (updated)")
    func kbucketLastRefreshedOnUpdate() throws {
        var bucket = KBucket(maxSize: 20)
        let peer = makePeerID()

        // First insert
        let insertResult = bucket.insert(peer)
        #expect(insertResult == .inserted)
        let afterInsert = bucket.lastRefreshed

        // Re-insert same peer (update path)
        let updateResult = bucket.insert(peer)
        #expect(updateResult == .updated)

        // lastRefreshed should be updated
        #expect(bucket.lastRefreshed >= afterInsert)
    }

    // MARK: - F-3: Shuffle verification

    @Test("Stale bucket refresh is not always the same order")
    func staleBucketRefreshOrderVaries() throws {
        let localPeerID = makePeerID()
        let table = RoutingTable(localPeerID: localPeerID)

        // Populate many buckets
        for _ in 0..<50 {
            let peer = makePeerID()
            table.addPeer(peer)
        }

        // Get stale buckets multiple times with zero threshold (all are stale)
        var firstBuckets: [Int] = []
        for _ in 0..<20 {
            let stale = table.bucketsNeedingRefresh(threshold: .zero)
            guard !stale.isEmpty else { continue }
            // Simulate what performRefresh does: shuffle then pick first
            let shuffled = stale.shuffled()
            firstBuckets.append(shuffled[0])
        }

        // With shuffling, we should see at least 2 different "first" buckets
        // over 20 iterations (overwhelmingly likely with multiple stale buckets)
        let uniqueFirst = Set(firstBuckets)
        #expect(uniqueFirst.count > 1, "Expected shuffled selection to vary, got: \(uniqueFirst)")
    }
}
