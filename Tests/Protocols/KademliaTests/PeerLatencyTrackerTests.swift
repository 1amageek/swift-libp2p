/// PeerLatencyTrackerTests - Tests for PeerLatencyTracker

import Testing
import Foundation
import P2PCore
@testable import P2PKademlia

private func randomPeerID() -> PeerID {
    PeerID(publicKey: KeyPair.generateEd25519().publicKey)
}

@Suite("PeerLatencyTracker Tests")
struct PeerLatencyTrackerTests {

    // MARK: - Basic Operations

    @Test("Initial state has zero tracked peers")
    func initialState() {
        let tracker = PeerLatencyTracker()

        #expect(tracker.trackedPeerCount == 0)
    }

    @Test("Record success tracks peer")
    func recordSuccess() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .milliseconds(50))

        #expect(tracker.trackedPeerCount == 1)
    }

    @Test("Record failure tracks peer")
    func recordFailure() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordFailure(peer: peer)

        #expect(tracker.trackedPeerCount == 1)
    }

    // MARK: - Average Latency

    @Test("Average latency for single measurement")
    func averageLatencySingle() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .milliseconds(100))

        let avg = tracker.averageLatency(for: peer)
        #expect(avg == .milliseconds(100))
    }

    @Test("Average latency for multiple measurements")
    func averageLatencyMultiple() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .milliseconds(100))
        tracker.recordSuccess(peer: peer, latency: .milliseconds(200))
        tracker.recordSuccess(peer: peer, latency: .milliseconds(300))

        let avg = tracker.averageLatency(for: peer)
        #expect(avg == .milliseconds(200))
    }

    @Test("Average latency returns nil for unknown peer")
    func averageLatencyUnknown() {
        let tracker = PeerLatencyTracker()

        let avg = tracker.averageLatency(for: randomPeerID())
        #expect(avg == nil)
    }

    @Test("Average latency returns nil for failure-only peer")
    func averageLatencyFailureOnly() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordFailure(peer: peer)

        let avg = tracker.averageLatency(for: peer)
        #expect(avg == nil)
    }

    // MARK: - Success Rate

    @Test("Success rate for all successes")
    func successRateAllSuccess() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .milliseconds(50))
        tracker.recordSuccess(peer: peer, latency: .milliseconds(60))

        let rate = tracker.successRate(for: peer)
        #expect(rate == 1.0)
    }

    @Test("Success rate for mixed results")
    func successRateMixed() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .milliseconds(50))
        tracker.recordFailure(peer: peer)

        let rate = tracker.successRate(for: peer)
        #expect(rate == 0.5)
    }

    @Test("Success rate for all failures")
    func successRateAllFailure() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordFailure(peer: peer)
        tracker.recordFailure(peer: peer)

        let rate = tracker.successRate(for: peer)
        #expect(rate == 0.0)
    }

    @Test("Success rate returns nil for unknown peer")
    func successRateUnknown() {
        let tracker = PeerLatencyTracker()

        let rate = tracker.successRate(for: randomPeerID())
        #expect(rate == nil)
    }

    // MARK: - Overall Stats

    @Test("Overall success rate across multiple peers")
    func overallSuccessRate() {
        let tracker = PeerLatencyTracker()
        let peer1 = randomPeerID()
        let peer2 = randomPeerID()

        // peer1: 2 success
        tracker.recordSuccess(peer: peer1, latency: .milliseconds(50))
        tracker.recordSuccess(peer: peer1, latency: .milliseconds(60))
        // peer2: 1 success, 1 failure
        tracker.recordSuccess(peer: peer2, latency: .milliseconds(70))
        tracker.recordFailure(peer: peer2)

        let rate = tracker.overallSuccessRate()
        #expect(rate == 0.75) // 3 success / 4 total
    }

    @Test("Overall success rate returns nil when empty")
    func overallSuccessRateEmpty() {
        let tracker = PeerLatencyTracker()

        #expect(tracker.overallSuccessRate() == nil)
    }

    @Test("Overall average latency across multiple peers")
    func overallAverageLatency() {
        let tracker = PeerLatencyTracker()
        let peer1 = randomPeerID()
        let peer2 = randomPeerID()

        tracker.recordSuccess(peer: peer1, latency: .milliseconds(100))
        tracker.recordSuccess(peer: peer2, latency: .milliseconds(200))

        let avg = tracker.overallAverageLatency()
        #expect(avg == .milliseconds(150))
    }

    // MARK: - Suggested Timeout

    @Test("Suggested timeout returns 3x average")
    func suggestedTimeout() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .seconds(1))

        let timeout = tracker.suggestedTimeout(for: peer, default: .seconds(10))
        #expect(timeout == .seconds(3))
    }

    @Test("Suggested timeout capped at default")
    func suggestedTimeoutCapped() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .seconds(5))

        // 5 * 3 = 15, but default is 10 → capped to 10
        let timeout = tracker.suggestedTimeout(for: peer, default: .seconds(10))
        #expect(timeout == .seconds(10))
    }

    @Test("Suggested timeout minimum of 1 second")
    func suggestedTimeoutMinimum() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .milliseconds(100))

        // 0.1 * 3 = 0.3s, but min is 1s
        let timeout = tracker.suggestedTimeout(for: peer, default: .seconds(10))
        #expect(timeout == .seconds(1))
    }

    @Test("Suggested timeout returns default for unknown peer")
    func suggestedTimeoutDefault() {
        let tracker = PeerLatencyTracker()

        let timeout = tracker.suggestedTimeout(for: randomPeerID(), default: .seconds(10))
        #expect(timeout == .seconds(10))
    }

    // MARK: - Cleanup

    @Test("Cleanup removes old entries")
    func cleanup() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .milliseconds(50))
        #expect(tracker.trackedPeerCount == 1)

        // Cleanup with zero threshold removes everything
        tracker.cleanup(olderThan: .zero)
        #expect(tracker.trackedPeerCount == 0)
    }

    @Test("Cleanup keeps recent entries")
    func cleanupKeepsRecent() {
        let tracker = PeerLatencyTracker()
        let peer = randomPeerID()

        tracker.recordSuccess(peer: peer, latency: .milliseconds(50))

        // Cleanup with large threshold keeps everything
        tracker.cleanup(olderThan: Duration.seconds(3600))
        #expect(tracker.trackedPeerCount == 1)
    }

    // MARK: - Clear

    @Test("Clear removes all data")
    func clear() {
        let tracker = PeerLatencyTracker()

        for _ in 0..<10 {
            tracker.recordSuccess(peer: randomPeerID(), latency: .milliseconds(50))
        }
        #expect(tracker.trackedPeerCount == 10)

        tracker.clear()
        #expect(tracker.trackedPeerCount == 0)
    }

    // MARK: - Capacity

    @Test("Evicts oldest when over capacity")
    func eviction() {
        let tracker = PeerLatencyTracker(maxPeers: 3)

        let peer1 = randomPeerID()
        let peer2 = randomPeerID()
        let peer3 = randomPeerID()
        let peer4 = randomPeerID()

        tracker.recordSuccess(peer: peer1, latency: .milliseconds(10))
        tracker.recordSuccess(peer: peer2, latency: .milliseconds(20))
        tracker.recordSuccess(peer: peer3, latency: .milliseconds(30))

        #expect(tracker.trackedPeerCount == 3)

        // Adding peer4 should evict the oldest (peer1)
        tracker.recordSuccess(peer: peer4, latency: .milliseconds(40))
        #expect(tracker.trackedPeerCount == 3)
    }
}
