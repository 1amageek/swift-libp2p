import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("DecodedBeacon")
struct DecodedBeaconTests {

    @Test("tier1 fields populated")
    func tier1FieldsPopulated() {
        let beacon = DecodedBeacon(
            tier: .tier1,
            truncID: 0x1234,
            nonce: Data([0x00, 0x00, 0x00, 0x01]),
            powValid: true
        )
        #expect(beacon.tier == .tier1)
        #expect(beacon.truncID == 0x1234)
        #expect(beacon.fullID == nil)
        #expect(beacon.powValid)
    }

    @Test("tier2 fields populated")
    func tier2FieldsPopulated() {
        let beacon = DecodedBeacon(
            tier: .tier2,
            truncID: 0xABCD,
            nonce: Data([0x01, 0x02, 0x03, 0x04]),
            powValid: true,
            teslaMAC: Data(repeating: 0xAA, count: 4),
            teslaPrevKey: Data(repeating: 0xBB, count: 8),
            capabilityBloom: Data(repeating: 0xCC, count: 10)
        )
        #expect(beacon.teslaMAC?.count == 4)
        #expect(beacon.teslaPrevKey?.count == 8)
        #expect(beacon.capabilityBloom?.count == 10)
    }

    @Test("tier3 fields populated")
    func tier3FieldsPopulated() throws {
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        let beacon = DecodedBeacon(
            tier: .tier3,
            fullID: kp.peerID,
            nonce: Data([0x05, 0x06, 0x07, 0x08]),
            powValid: true,
            envelope: envelope
        )
        #expect(beacon.fullID == kp.peerID)
        #expect(beacon.truncID == nil)
        #expect(beacon.envelope != nil)
    }

    @Test("optional fields nil by default")
    func optionalFieldsNilByDefault() {
        let beacon = DecodedBeacon(
            tier: .tier1,
            nonce: Data([0x00, 0x00, 0x00, 0x00]),
            powValid: false
        )
        #expect(beacon.truncID == nil)
        #expect(beacon.fullID == nil)
        #expect(beacon.teslaMAC == nil)
        #expect(beacon.teslaPrevKey == nil)
        #expect(beacon.capabilityBloom == nil)
        #expect(beacon.envelope == nil)
    }
}
