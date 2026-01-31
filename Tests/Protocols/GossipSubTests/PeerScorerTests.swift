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

    // MARK: - Per-Topic Scoring Tests

    @Test("Time in mesh scoring")
    func testTimeInMeshScoring() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 1.0,
            timeInMeshQuantum: .seconds(1),
            timeInMeshCap: 3600,
            firstMessageDeliveriesWeight: 0,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        // Peer joins mesh
        scorer.peerJoinedMesh(peerID, topic: topic)

        // Immediately after joining, time in mesh is very small but non-negative
        let score = scorer.computeScore(for: peerID)
        // P1 = timeInMeshWeight * min(timeInMesh / quantum, cap) >= 0
        #expect(score >= 0.0)
    }

    @Test("First message delivery bonus")
    func testFirstMessageDeliveryBonus() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 5.0,
            firstMessageDeliveriesDecay: 1.0,  // no decay
            firstMessageDeliveriesCap: 100,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        // Record 3 first message deliveries
        scorer.recordFirstMessageDelivery(from: peerID, topic: topic)
        scorer.recordFirstMessageDelivery(from: peerID, topic: topic)
        scorer.recordFirstMessageDelivery(from: peerID, topic: topic)

        let score = scorer.computeScore(for: peerID)
        // P2 = firstMessageDeliveriesWeight * min(3, cap) = 5.0 * 3 = 15.0
        // topicWeight * topicScore = 1.0 * 15.0 = 15.0
        #expect(score == 15.0)
    }

    @Test("Mesh message delivery deficit penalty")
    func testMeshMessageDeliveryDeficit() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 0,
            meshMessageDeliveriesWeight: -1.0,
            meshMessageDeliveriesDecay: 1.0,  // no decay
            meshMessageDeliveriesThreshold: 10,
            meshMessageDeliveriesCap: 100,
            meshMessageDeliveriesActivation: .zero,  // activate immediately
            meshMessageDeliveriesWindow: .seconds(5),
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        // Join mesh (activation is immediate with .zero)
        scorer.peerJoinedMesh(peerID, topic: topic)

        // Deliver only 3 messages (deficit = 10 - 3 = 7)
        scorer.recordMeshMessageDelivery(from: peerID, topic: topic)
        scorer.recordMeshMessageDelivery(from: peerID, topic: topic)
        scorer.recordMeshMessageDelivery(from: peerID, topic: topic)

        let score = scorer.computeScore(for: peerID)
        // P3 = meshMessageDeliveriesWeight * (threshold - delivered)^2
        //    = -1.0 * (10 - 3)^2 = -1.0 * 49 = -49.0
        #expect(score == -49.0)
    }

    @Test("Mesh failure penalty")
    func testMeshFailurePenalty() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 0,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: -2.0,
            meshFailurePenaltyDecay: 1.0,  // no decay
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        // Record mesh failure directly
        scorer.recordMeshFailure(peer: peerID, topic: topic)

        let score = scorer.computeScore(for: peerID)
        // P3b = meshFailurePenaltyWeight * meshFailurePenalty = -2.0 * 1 = -2.0
        #expect(score == -2.0)
    }

    @Test("Invalid message per-topic penalty")
    func testInvalidMessagePerTopicPenalty() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 0,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: -10.0,
            invalidMessageDeliveriesDecay: 1.0  // no decay
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        // Record 2 invalid messages
        scorer.recordInvalidMessageDelivery(from: peerID, topic: topic)
        scorer.recordInvalidMessageDelivery(from: peerID, topic: topic)

        let score = scorer.computeScore(for: peerID)
        // P4 = invalidMessageDeliveriesWeight * invalidMessageDeliveries^2
        //    = -10.0 * 2^2 = -10.0 * 4 = -40.0
        #expect(score == -40.0)
    }

    @Test("Topic weights in overall score")
    func testTopicWeights() {
        let topic1: Topic = "topic-1"
        let topic2: Topic = "topic-2"

        let params1 = TopicScoreParams(
            topicWeight: 2.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 1.0,
            firstMessageDeliveriesDecay: 1.0,
            firstMessageDeliveriesCap: 100,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let params2 = TopicScoreParams(
            topicWeight: 3.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 1.0,
            firstMessageDeliveriesDecay: 1.0,
            firstMessageDeliveriesCap: 100,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )

        let scorer = PeerScorer(
            topicParams: [topic1: params1, topic2: params2]
        )
        let peerID = makePeerID()

        // 1 first delivery in topic1, 1 in topic2
        scorer.recordFirstMessageDelivery(from: peerID, topic: topic1)
        scorer.recordFirstMessageDelivery(from: peerID, topic: topic2)

        let score = scorer.computeScore(for: peerID)
        // topic1: topicWeight * P2 = 2.0 * (1.0 * 1) = 2.0
        // topic2: topicWeight * P2 = 3.0 * (1.0 * 1) = 3.0
        // total = 2.0 + 3.0 = 5.0
        #expect(score == 5.0)
    }

    @Test("Per-topic decay")
    func testPerTopicDecay() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 1.0,
            firstMessageDeliveriesDecay: 0.5,  // halve each decay
            firstMessageDeliveriesCap: 100,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        // Record 10 first deliveries
        for _ in 0..<10 {
            scorer.recordFirstMessageDelivery(from: peerID, topic: topic)
        }

        let scoreBefore = scorer.computeScore(for: peerID)
        // P2 = 1.0 * 10 = 10.0
        #expect(scoreBefore == 10.0)

        // Apply decay
        scorer.applyDecayToAll()

        let scoreAfter = scorer.computeScore(for: peerID)
        // After decay: firstMessageDeliveries = 10 * 0.5 = 5
        // P2 = 1.0 * 5.0 = 5.0
        #expect(scoreAfter == 5.0)
    }

    @Test("Activation window delays deficit penalty")
    func testActivationWindow() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 0,
            meshMessageDeliveriesWeight: -1.0,
            meshMessageDeliveriesDecay: 1.0,
            meshMessageDeliveriesThreshold: 10,
            meshMessageDeliveriesCap: 100,
            meshMessageDeliveriesActivation: .seconds(3600),  // very long activation
            meshMessageDeliveriesWindow: .seconds(5),
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        // Join mesh
        scorer.peerJoinedMesh(peerID, topic: topic)

        // Deliver no messages at all

        let score = scorer.computeScore(for: peerID)
        // Activation window is 3600 seconds, so P3 = 0 (not yet active)
        // No other contributions, so score = 0
        #expect(score == 0.0)
    }

    @Test("computeScore combines global and per-topic scores")
    func testComputeScoreCombinesGlobalAndPerTopic() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 1.0,
            firstMessageDeliveriesDecay: 1.0,
            firstMessageDeliveriesCap: 100,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        // Apply global penalty
        scorer.applyPenalty(to: peerID, amount: -5.0)

        // Record per-topic first delivery
        scorer.recordFirstMessageDelivery(from: peerID, topic: topic)

        // Global score: -5.0
        // Per-topic score: 1.0 * (1.0 * 1) = 1.0
        // Combined: -5.0 + 1.0 = -4.0
        let combined = scorer.computeScore(for: peerID)
        #expect(combined == -4.0)

        // score(for:) only returns global
        let globalOnly = scorer.score(for: peerID)
        #expect(globalOnly == -5.0)
    }

    @Test("Default topic params used for unconfigured topics")
    func testDefaultTopicParams() {
        let defaultParams = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 2.0,
            firstMessageDeliveriesDecay: 1.0,
            firstMessageDeliveriesCap: 100,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            defaultTopicParams: defaultParams
        )
        let peerID = makePeerID()
        let unconfiguredTopic: Topic = "unconfigured"

        scorer.recordFirstMessageDelivery(from: peerID, topic: unconfiguredTopic)

        let score = scorer.computeScore(for: peerID)
        // Using default params: P2 = 2.0 * 1 = 2.0
        #expect(score == 2.0)
    }

    @Test("Mesh message deliveries above threshold gives no penalty")
    func testMeshMessageDeliveriesAboveThreshold() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 0,
            meshMessageDeliveriesWeight: -1.0,
            meshMessageDeliveriesDecay: 1.0,
            meshMessageDeliveriesThreshold: 5,
            meshMessageDeliveriesCap: 100,
            meshMessageDeliveriesActivation: .zero,
            meshMessageDeliveriesWindow: .seconds(5),
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        scorer.peerJoinedMesh(peerID, topic: topic)

        // Deliver more than threshold
        for _ in 0..<10 {
            scorer.recordMeshMessageDelivery(from: peerID, topic: topic)
        }

        let score = scorer.computeScore(for: peerID)
        // deficit = threshold - delivered = 5 - 10 = -5 (negative, so P3 = 0)
        #expect(score == 0.0)
    }

    @Test("removePeer clears per-topic state")
    func testRemovePeerClearsTopicState() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 1.0,
            firstMessageDeliveriesDecay: 1.0,
            firstMessageDeliveriesCap: 100,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        scorer.recordFirstMessageDelivery(from: peerID, topic: topic)
        #expect(scorer.computeScore(for: peerID) == 1.0)

        scorer.removePeer(peerID)

        // After removal, score should be 0
        #expect(scorer.computeScore(for: peerID) == 0.0)
    }

    @Test("clear clears per-topic state")
    func testClearClearsTopicState() {
        let topic: Topic = "test-topic"
        let params = TopicScoreParams(
            topicWeight: 1.0,
            timeInMeshWeight: 0,
            firstMessageDeliveriesWeight: 1.0,
            firstMessageDeliveriesDecay: 1.0,
            firstMessageDeliveriesCap: 100,
            meshMessageDeliveriesWeight: 0,
            meshFailurePenaltyWeight: 0,
            invalidMessageDeliveriesWeight: 0
        )
        let scorer = PeerScorer(
            topicParams: [topic: params]
        )
        let peerID = makePeerID()

        scorer.recordFirstMessageDelivery(from: peerID, topic: topic)
        #expect(scorer.computeScore(for: peerID) == 1.0)

        scorer.clear()

        #expect(scorer.computeScore(for: peerID) == 0.0)
    }
}
