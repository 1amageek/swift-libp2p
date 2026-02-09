import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("OpaqueAddress")
struct OpaqueAddressTests {

    @Test("init and properties")
    func initAndProperties() {
        let raw = Data([0x01, 0x02, 0x03])
        let addr = OpaqueAddress(mediumID: "ble", raw: raw)
        #expect(addr.mediumID == "ble")
        #expect(addr.raw == raw)
    }

    @Test("Hashable conformance")
    func hashableConformance() {
        let raw = Data([0x01, 0x02])
        let a = OpaqueAddress(mediumID: "ble", raw: raw)
        let b = OpaqueAddress(mediumID: "ble", raw: raw)
        let c = OpaqueAddress(mediumID: "lora", raw: raw)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(a != c)
    }

    @Test("Codable roundtrip")
    func codableRoundtrip() throws {
        let original = OpaqueAddress(mediumID: "wifi-direct", raw: Data([0xAB, 0xCD]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OpaqueAddress.self, from: data)
        #expect(decoded == original)
    }

    @Test("empty raw data")
    func emptyRawData() {
        let addr = OpaqueAddress(mediumID: "nfc", raw: Data())
        #expect(addr.raw.isEmpty)
        #expect(addr.mediumID == "nfc")
    }

    @Test("description format")
    func descriptionFormat() {
        let addr = OpaqueAddress(mediumID: "ble", raw: Data(repeating: 0, count: 16))
        #expect(addr.description == "OpaqueAddress(ble, 16B)")
    }
}
