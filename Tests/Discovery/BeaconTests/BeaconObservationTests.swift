import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("BeaconObservation")
struct BeaconObservationTests {

    @Test("init with defaults")
    func initWithDefaults() {
        let before = ContinuousClock.now
        let obs = BeaconObservation(
            mediumID: "ble",
            address: makeOpaqueAddress(),
            freshnessFunction: .ble
        )
        let after = ContinuousClock.now
        #expect(obs.timestamp >= before)
        #expect(obs.timestamp <= after)
    }

    @Test("age computation")
    func ageComputation() throws {
        let past = ContinuousClock.now - .milliseconds(100)
        let obs = BeaconObservation(
            timestamp: past,
            mediumID: "ble",
            address: makeOpaqueAddress(),
            freshnessFunction: .ble
        )
        #expect(obs.age >= .milliseconds(100))
    }

    @Test("optional RSSI")
    func optionalRSSI() {
        let obs1 = BeaconObservation(
            mediumID: "ble",
            rssi: nil,
            address: makeOpaqueAddress(),
            freshnessFunction: .ble
        )
        #expect(obs1.rssi == nil)

        let obs2 = BeaconObservation(
            mediumID: "ble",
            rssi: -70,
            address: makeOpaqueAddress(),
            freshnessFunction: .ble
        )
        #expect(obs2.rssi == -70)
    }

    @Test("mediumID preserved")
    func mediumIDPreserved() {
        let obs = BeaconObservation(
            mediumID: "lora",
            address: makeOpaqueAddress(medium: "lora"),
            freshnessFunction: .lora
        )
        #expect(obs.mediumID == "lora")
    }
}
