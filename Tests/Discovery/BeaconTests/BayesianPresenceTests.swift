import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("BayesianPresence")
struct BayesianPresenceTests {

    @Test("empty observations returns zero")
    func emptyObservationsReturnsZero() {
        let score = BayesianPresence.presenceScore(observations: [])
        #expect(score == 0.0)
    }

    @Test("single fresh observation")
    func singleFreshObservation() {
        let obs = makeBeaconObservation(medium: "ble")
        let score = BayesianPresence.presenceScore(observations: [obs])
        // BLE freshness: initialWeight=0.8, age≈0 → score ≈ 0.8
        #expect(score > 0.7)
        #expect(score <= 1.0)
    }

    @Test("multiple observations increase score")
    func multipleObservationsIncrease() {
        let obs1 = makeBeaconObservation(medium: "ble")
        let obs2 = makeBeaconObservation(medium: "ble")
        let score1 = BayesianPresence.presenceScore(observations: [obs1])
        let score2 = BayesianPresence.presenceScore(observations: [obs1, obs2])
        #expect(score2 > score1)
    }

    @Test("stale observations low score")
    func staleObservationsLowScore() {
        let past = ContinuousClock.now - .seconds(600) // 10 half-lives for BLE (60s halflife)
        let obs = BeaconObservation(
            timestamp: past,
            mediumID: "ble",
            address: makeOpaqueAddress(),
            freshnessFunction: .ble
        )
        let score = BayesianPresence.presenceScore(observations: [obs])
        #expect(score < 0.01)
    }

    @Test("noisy OR formula")
    func noisyOrFormula() {
        // Manual calculation: 1 - (1-f1)*(1-f2) where f1, f2 ≈ 0.8
        let obs1 = makeBeaconObservation(medium: "ble")
        let obs2 = makeBeaconObservation(medium: "ble")
        let score = BayesianPresence.presenceScore(observations: [obs1, obs2])
        // With f ≈ 0.8: 1 - (0.2)*(0.2) = 1 - 0.04 = 0.96
        #expect(score > 0.9)
    }

    @Test("max score below 1.0")
    func maxScoreBelow1() {
        let observations = (0..<10).map { _ in makeBeaconObservation(medium: "ble") }
        let score = BayesianPresence.presenceScore(observations: observations)
        #expect(score < 1.0)
        #expect(score > 0.99)
    }
}
