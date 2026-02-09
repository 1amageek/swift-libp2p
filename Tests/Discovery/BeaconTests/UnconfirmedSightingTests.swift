import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("UnconfirmedSighting")
struct UnconfirmedSightingTests {

    @Test("init defaults")
    func initDefaults() {
        let sighting = UnconfirmedSighting(truncID: 0x1234)
        #expect(sighting.truncID == 0x1234)
        #expect(sighting.addresses.isEmpty)
        #expect(sighting.observations.isEmpty)
        #expect(sighting.presenceScore == 0)
    }

    @Test("mutable addresses")
    func mutableAddresses() {
        var sighting = UnconfirmedSighting(truncID: 0x0001)
        let addr = makeOpaqueAddress()
        sighting.addresses.append(addr)
        #expect(sighting.addresses.count == 1)
        #expect(sighting.addresses[0] == addr)
    }

    @Test("mutable observations")
    func mutableObservations() {
        var sighting = UnconfirmedSighting(truncID: 0x0002)
        let obs = makeBeaconObservation()
        sighting.observations.append(obs)
        #expect(sighting.observations.count == 1)
    }

    @Test("presenceScore update")
    func presenceScoreUpdate() {
        var sighting = UnconfirmedSighting(truncID: 0x0003)
        sighting.presenceScore = 0.75
        #expect(sighting.presenceScore == 0.75)
    }
}
