/// PeerScorerTests - Tests for GossipSub peer scoring functionality.

import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore

@Suite("PeerScorer Tests")
struct PeerScorerTests {

    // MARK: - Helper Methods

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeMessageID(_ string: String) -> MessageID {
        MessageID(bytes: Data(string.utf8))
    }

    // MARK: - Basic Scoring Tests

    @Test("Initial score is zero")
    func testInitialScoreIsZero() {
        let scorer = PeerScorer()
        let peerID = makePeerID()

        #expect(scorer.score(for: peerID) == 0.0)
    }

    @Test("Penalty reduces score")
    func testPenaltyReducesScore() {
        let scorer = PeerScorer()
        let peerID = makePeerID()

        scorer.recordInvalidMessage(from: peerID)

        #expect(scorer.score(for: peerID) < 0.0)
    }

    @Test("Multiple penalties accumulate")
    func testMultiplePenaltiesAccumulate() {
        let scorer = PeerScorer()
        let peerID = makePeerID()

        scorer.recordDuplicateMessage(from: peerID)
        let firstScore = scorer.score(for: peerID)

        scorer.recordDuplicateMessage(from: peerID)
        let secondScore = scorer.score(for: peerID)

        #expect(secondScore < firstScore)
    }

    @Test("Graylist threshold works")
    func testGraylistThreshold() {
        let config = PeerScorerConfig(graylistThreshold: -50.0)
        let scorer = PeerScorer(config: config)
        let peerID = makePeerID()

        // Apply small penalty - should not be graylisted
        scorer.applyPenalty(to: peerID, amount: -10.0)
        #expect(!scorer.isGraylisted(peerID))

        // Apply larger penalty - should be graylisted
        scorer.applyPenalty(to: peerID, amount: -50.0)
        #expect(scorer.isGraylisted(peerID))
    }

    // MARK: - IWANT Tracking Tests

    @Test("IWANT tracking accepts initial request")
    func testIWantTrackingAcceptsInitialRequest() {
        let scorer = PeerScorer()
        let peerID = makePeerID()
        let messageID = makeMessageID("test-message-1")

        let result = scorer.trackIWantRequest(from: peerID, for: messageID)

        if case .accepted = result {
            // Expected
        } else {
            Issue.record("Expected accepted result")
        }
    }

    @Test("IWANT tracking detects excessive requests")
    func testIWantTrackingDetectsExcessiveRequests() {
        let config = PeerScorerConfig(iwantDuplicateThreshold: 3)
        let scorer = PeerScorer(config: config)
        let peerID = makePeerID()
        let messageID = makeMessageID("test-message-1")

        // First two requests should be accepted
        _ = scorer.trackIWantRequest(from: peerID, for: messageID)
        _ = scorer.trackIWantRequest(from: peerID, for: messageID)

        // Third request should trigger excessive
        let result = scorer.trackIWantRequest(from: peerID, for: messageID)

        if case .excessive(let count) = result {
            #expect(count == 3)
        } else {
            Issue.record("Expected excessive result")
        }
    }

    @Test("IWANT tracking is per-message")
    func testIWantTrackingIsPerMessage() {
        let config = PeerScorerConfig(iwantDuplicateThreshold: 3)
        let scorer = PeerScorer(config: config)
        let peerID = makePeerID()
        let messageID1 = makeMessageID("test-message-1")
        let messageID2 = makeMessageID("test-message-2")

        // Request same message twice
        _ = scorer.trackIWantRequest(from: peerID, for: messageID1)
        _ = scorer.trackIWantRequest(from: peerID, for: messageID1)

        // Different message should be accepted
        let result = scorer.trackIWantRequest(from: peerID, for: messageID2)

        if case .accepted = result {
            // Expected
        } else {
            Issue.record("Expected accepted result for different message")
        }
    }

    @Test("IWANT tracking is per-peer")
    func testIWantTrackingIsPerPeer() {
        let config = PeerScorerConfig(iwantDuplicateThreshold: 3)
        let scorer = PeerScorer(config: config)
        let peerID1 = makePeerID()
        let peerID2 = makePeerID()
        let messageID = makeMessageID("test-message-1")

        // Peer 1 requests twice
        _ = scorer.trackIWantRequest(from: peerID1, for: messageID)
        _ = scorer.trackIWantRequest(from: peerID1, for: messageID)

        // Peer 2's first request for same message should be accepted
        let result = scorer.trackIWantRequest(from: peerID2, for: messageID)

        if case .accepted = result {
            // Expected
        } else {
            Issue.record("Expected accepted result for different peer")
        }
    }

    // MARK: - Delivery Tracking Tests

    @Test("First delivery gives bonus")
    func testFirstDeliveryGivesBonus() {
        let config = PeerScorerConfig(firstDeliveryBonus: 10.0)
        let scorer = PeerScorer(config: config)
        let peerID = makePeerID()

        scorer.recordMessageDelivery(from: peerID, isFirst: true)

        #expect(scorer.score(for: peerID) == 10.0)
    }

    @Test("Non-first delivery does not give bonus")
    func testNonFirstDeliveryNoBonus() {
        let config = PeerScorerConfig(firstDeliveryBonus: 10.0)
        let scorer = PeerScorer(config: config)
        let peerID = makePeerID()

        scorer.recordMessageDelivery(from: peerID, isFirst: false)

        #expect(scorer.score(for: peerID) == 0.0)
    }

    @Test("Low delivery rate triggers penalty")
    func testLowDeliveryRatePenalty() {
        let config = PeerScorerConfig(
            minDeliveryRate: 0.8,
            lowDeliveryPenalty: -100.0
        )
        let scorer = PeerScorer(config: config)
        let peerID = makePeerID()

        // Expected 10 messages
        for _ in 0..<10 {
            scorer.recordExpectedMessage(from: peerID)
        }

        // Delivered only 5 (50% rate, below 80% threshold)
        for _ in 0..<5 {
            scorer.recordMessageDelivery(from: peerID, isFirst: false)
        }

        let penalized = scorer.applyDeliveryRatePenalties()

        #expect(penalized.keys.contains(peerID))
        #expect(scorer.score(for: peerID) < 0.0)
    }

    @Test("Good delivery rate no penalty")
    func testGoodDeliveryRateNoPenalty() {
        let config = PeerScorerConfig(
            minDeliveryRate: 0.8,
            lowDeliveryPenalty: -100.0
        )
        let scorer = PeerScorer(config: config)
        let peerID = makePeerID()

        // Expected 10 messages
        for _ in 0..<10 {
            scorer.recordExpectedMessage(from: peerID)
        }

        // Delivered 9 (90% rate, above 80% threshold)
        for _ in 0..<9 {
            scorer.recordMessageDelivery(from: peerID, isFirst: false)
        }

        let penalized = scorer.applyDeliveryRatePenalties()

        #expect(!penalized.keys.contains(peerID))
    }

    // MARK: - IP Colocation Tests

    @Test("IP colocation allows threshold peers")
    func testIPColocationAllowsThresholdPeers() {
        let config = PeerScorerConfig(ipColocationThreshold: 2)
        let scorer = PeerScorer(config: config)
        let peerID1 = makePeerID()
        let peerID2 = makePeerID()

        let result1 = scorer.registerPeerIP(peerID1, ip: "192.0.2.1")
        let result2 = scorer.registerPeerIP(peerID2, ip: "192.0.2.1")

        #expect(!result1.penaltyApplied)
        #expect(!result2.penaltyApplied)
        #expect(result2.peerCount == 2)
    }

    @Test("IP colocation penalizes excess peers")
    func testIPColocationPenalizesExcessPeers() {
        let config = PeerScorerConfig(
            ipColocationThreshold: 2,
            ipColocationPenalty: -10.0
        )
        let scorer = PeerScorer(config: config)
        let peerID1 = makePeerID()
        let peerID2 = makePeerID()
        let peerID3 = makePeerID()

        scorer.registerPeerIP(peerID1, ip: "192.0.2.1")
        scorer.registerPeerIP(peerID2, ip: "192.0.2.1")
        let result3 = scorer.registerPeerIP(peerID3, ip: "192.0.2.1")

        #expect(result3.penaltyApplied)
        #expect(result3.peerCount == 3)

        // All three peers should have penalties
        #expect(scorer.score(for: peerID1) < 0.0)
        #expect(scorer.score(for: peerID2) < 0.0)
        #expect(scorer.score(for: peerID3) < 0.0)
    }

    @Test("IP colocation normalizes IPv4-mapped IPv6")
    func testIPColocationNormalizesIPv4MappedIPv6() {
        let config = PeerScorerConfig(ipColocationThreshold: 1)
        let scorer = PeerScorer(config: config)
        let peerID1 = makePeerID()
        let peerID2 = makePeerID()

        scorer.registerPeerIP(peerID1, ip: "192.0.2.1")
        let result2 = scorer.registerPeerIP(peerID2, ip: "::ffff:192.0.2.1")

        // Should be treated as same IP
        #expect(result2.penaltyApplied)
        #expect(result2.peerCount == 2)
    }

    @Test("IP colocation tracks different IPs separately")
    func testIPColocationTracksSeparateIPs() {
        let config = PeerScorerConfig(ipColocationThreshold: 1)
        let scorer = PeerScorer(config: config)
        let peerID1 = makePeerID()
        let peerID2 = makePeerID()

        scorer.registerPeerIP(peerID1, ip: "192.0.2.1")
        let result2 = scorer.registerPeerIP(peerID2, ip: "192.0.2.2")

        // Different IPs should not trigger penalty
        #expect(!result2.penaltyApplied)
    }

    @Test("Peer same IP count works")
    func testPeersOnSameIPCount() {
        let scorer = PeerScorer()
        let peerID1 = makePeerID()
        let peerID2 = makePeerID()
        let peerID3 = makePeerID()

        scorer.registerPeerIP(peerID1, ip: "192.0.2.1")
        scorer.registerPeerIP(peerID2, ip: "192.0.2.1")
        scorer.registerPeerIP(peerID3, ip: "192.0.2.2")

        #expect(scorer.peersOnSameIP(as: peerID1) == 2)
        #expect(scorer.peersOnSameIP(as: peerID2) == 2)
        #expect(scorer.peersOnSameIP(as: peerID3) == 1)
    }

    // MARK: - Cleanup Tests

    @Test("Remove peer clears all tracking")
    func testRemovePeerClearsAllTracking() {
        let scorer = PeerScorer()
        let peerID = makePeerID()
        let messageID = makeMessageID("test-message")

        // Add data to all tracking systems
        scorer.applyPenalty(to: peerID, amount: -10.0)
        _ = scorer.trackIWantRequest(from: peerID, for: messageID)
        scorer.recordExpectedMessage(from: peerID)
        scorer.registerPeerIP(peerID, ip: "192.0.2.1")

        // Remove peer
        scorer.removePeer(peerID)

        // All tracking should be cleared
        #expect(scorer.score(for: peerID) == 0.0)
        #expect(scorer.peersOnSameIP(as: peerID) == 0)

        // IWANT should accept as new
        let result = scorer.trackIWantRequest(from: peerID, for: messageID)
        if case .accepted = result {
            // Expected
        } else {
            Issue.record("Expected IWANT tracking to be reset")
        }
    }

    @Test("Clear clears all state")
    func testClearClearsAllState() {
        let scorer = PeerScorer()
        let peerID1 = makePeerID()
        let peerID2 = makePeerID()

        scorer.applyPenalty(to: peerID1, amount: -10.0)
        scorer.registerPeerIP(peerID1, ip: "192.0.2.1")
        scorer.registerPeerIP(peerID2, ip: "192.0.2.1")

        scorer.clear()

        #expect(scorer.score(for: peerID1) == 0.0)
        #expect(scorer.peersOnSameIP(as: peerID1) == 0)
        #expect(scorer.allScores().isEmpty)
    }

    // MARK: - Peer Selection Tests

    @Test("Select best peers filters graylisted")
    func testSelectBestPeersFiltersGraylisted() {
        let config = PeerScorerConfig(graylistThreshold: -50.0)
        let scorer = PeerScorer(config: config)

        let goodPeer = makePeerID()
        let badPeer = makePeerID()

        scorer.applyPenalty(to: goodPeer, amount: 10.0)
        scorer.applyPenalty(to: badPeer, amount: -100.0)

        let selected = scorer.selectBestPeers(from: [goodPeer, badPeer], count: 2)

        #expect(selected.count == 1)
        #expect(selected.contains(goodPeer))
        #expect(!selected.contains(badPeer))
    }

    @Test("Select best peers sorts by score")
    func testSelectBestPeersSortsByScore() {
        let scorer = PeerScorer()

        let peer1 = makePeerID()
        let peer2 = makePeerID()
        let peer3 = makePeerID()

        scorer.applyPenalty(to: peer1, amount: -5.0)
        scorer.applyPenalty(to: peer2, amount: 10.0)
        scorer.applyPenalty(to: peer3, amount: 5.0)

        let selected = scorer.selectBestPeers(from: [peer1, peer2, peer3], count: 3)

        #expect(selected[0] == peer2)  // Highest score
        #expect(selected[1] == peer3)  // Second highest
        #expect(selected[2] == peer1)  // Lowest score
    }
}
