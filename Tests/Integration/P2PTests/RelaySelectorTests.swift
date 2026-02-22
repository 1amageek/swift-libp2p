import Testing
import P2PCore
@testable import P2P

@Suite("RelaySelectorTests")
struct RelaySelectorTests {

    private func makePeer() -> PeerID {
        PeerID(publicKey: KeyPair.generateEd25519().publicKey)
    }

    // MARK: - RTT Normalization

    @Test("RTT at or below ideal scores 1.0", .timeLimit(.minutes(1)))
    func rttBelowIdealScoresMax() {
        let selector = DefaultRelaySelector()
        let score = selector.normalizeRTT(.milliseconds(10))
        #expect(score == 1.0)
    }

    @Test("RTT at ideal scores 1.0", .timeLimit(.minutes(1)))
    func rttAtIdealScoresMax() {
        let selector = DefaultRelaySelector()
        let score = selector.normalizeRTT(.milliseconds(50))
        #expect(score == 1.0)
    }

    @Test("RTT at or above worst scores 0.0", .timeLimit(.minutes(1)))
    func rttAboveWorstScoresZero() {
        let selector = DefaultRelaySelector()
        let score = selector.normalizeRTT(.seconds(3))
        #expect(score == 0.0)
    }

    @Test("RTT between ideal and worst scores linearly", .timeLimit(.minutes(1)))
    func rttMidpointScoresLinearly() {
        let config = RelaySelectorConfiguration(
            idealRTT: .milliseconds(0),
            worstRTT: .seconds(2)
        )
        let selector = DefaultRelaySelector(configuration: config)
        let score = selector.normalizeRTT(.seconds(1))
        #expect(abs(score - 0.5) < 0.01)
    }

    @Test("Unknown RTT returns neutral score 0.5", .timeLimit(.minutes(1)))
    func unknownRTTReturnsNeutral() {
        let selector = DefaultRelaySelector()
        let score = selector.normalizeRTT(nil)
        #expect(score == 0.5)
    }

    // MARK: - Failure Normalization

    @Test("Zero failures scores 1.0", .timeLimit(.minutes(1)))
    func zeroFailuresScoreMax() {
        let selector = DefaultRelaySelector()
        let score = selector.normalizeFailures(0)
        #expect(score == 1.0)
    }

    @Test("Max failures scores 0.0", .timeLimit(.minutes(1)))
    func maxFailuresScoreZero() {
        let selector = DefaultRelaySelector()
        let score = selector.normalizeFailures(5)
        #expect(score == 0.0)
    }

    @Test("Above max failures still scores 0.0", .timeLimit(.minutes(1)))
    func aboveMaxFailuresScoreZero() {
        let selector = DefaultRelaySelector()
        let score = selector.normalizeFailures(10)
        #expect(score == 0.0)
    }

    // MARK: - Selection

    @Test("Filters out candidates that don't support relay", .timeLimit(.minutes(1)))
    func filtersNonRelaySupporting() {
        let selector = DefaultRelaySelector()
        let peer = makePeer()
        let candidates = [
            RelayCandidateInfo(
                peer: peer,
                addresses: [],
                rtt: .milliseconds(100),
                recentFailures: 0,
                supportsRelay: false
            )
        ]
        let results = selector.select(from: candidates)
        #expect(results.isEmpty)
    }

    @Test("Sorts candidates by score descending (best first)", .timeLimit(.minutes(1)))
    func sortsBestFirst() {
        let selector = DefaultRelaySelector()
        let peer1 = makePeer()
        let peer2 = makePeer()
        let peer3 = makePeer()

        let candidates = [
            RelayCandidateInfo(peer: peer1, addresses: [], rtt: .seconds(1), recentFailures: 3, supportsRelay: true),
            RelayCandidateInfo(peer: peer2, addresses: [], rtt: .milliseconds(10), recentFailures: 0, supportsRelay: true),
            RelayCandidateInfo(peer: peer3, addresses: [], rtt: .milliseconds(500), recentFailures: 1, supportsRelay: true),
        ]

        let results = selector.select(from: candidates)
        #expect(results.count == 3)
        #expect(results[0].peer == peer2)
        // peer2 (low RTT, 0 failures) should beat peer3 which beats peer1
        #expect(results[0].score > results[1].score)
        #expect(results[1].score > results[2].score)
    }

    // MARK: - Custom Selector

    @Test("Custom selector protocol conformance", .timeLimit(.minutes(1)))
    func customSelectorConformance() {
        struct FixedSelector: RelaySelector {
            func select(from candidates: [RelayCandidateInfo]) -> [RelayCandidateScore] {
                candidates.map { c in
                    RelayCandidateScore(peer: c.peer, score: 0.42, rtt: c.rtt, recentFailures: c.recentFailures)
                }
            }
        }

        let selector = FixedSelector()
        let peer = makePeer()
        let candidates = [
            RelayCandidateInfo(peer: peer, addresses: [], rtt: .milliseconds(100), recentFailures: 0, supportsRelay: true)
        ]
        let results = selector.select(from: candidates)
        #expect(results.count == 1)
        #expect(results[0].score == 0.42)
    }

    @Test("Empty candidates returns empty results", .timeLimit(.minutes(1)))
    func emptyCandidatesReturnsEmpty() {
        let selector = DefaultRelaySelector()
        let results = selector.select(from: [])
        #expect(results.isEmpty)
    }

    @Test("Reset failures restore full score", .timeLimit(.minutes(1)))
    func resetFailuresRestoreFullScore() {
        let selector = DefaultRelaySelector()
        let peer = makePeer()

        // Before reset: 5 failures → failure score 0.0
        let penalized = selector.select(from: [
            RelayCandidateInfo(peer: peer, addresses: [], rtt: nil, recentFailures: 5, supportsRelay: true)
        ])
        #expect(penalized.count == 1)
        let penalizedScore = penalized[0].score

        // After reset: 0 failures → failure score 1.0
        let reset = selector.select(from: [
            RelayCandidateInfo(peer: peer, addresses: [], rtt: nil, recentFailures: 0, supportsRelay: true)
        ])
        #expect(reset.count == 1)
        let resetScore = reset[0].score

        // Reset score must be strictly higher than penalized score
        #expect(resetScore > penalizedScore)
        // With RTT neutral (0.5) and failures 0 (1.0):
        // score = 0.6 * 0.5 + 0.4 * 1.0 = 0.7
        #expect(abs(resetScore - 0.7) < 0.01)
    }
}
