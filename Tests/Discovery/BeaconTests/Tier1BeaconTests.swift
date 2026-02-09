import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("Tier1Beacon")
struct Tier1BeaconTests {

    @Test("encode/decode roundtrip")
    func encodeDecodeRoundtrip() {
        let pow = MicroPoW.solve(truncID: 0x1234, nonce: 0xAABBCCDD, difficulty: 8)
        let beacon = Tier1Beacon(truncID: 0x1234, pow: pow, nonce: 0xAABBCCDD)
        let encoded = beacon.encode()
        let decoded = Tier1Beacon.decode(from: encoded)
        #expect(decoded != nil)
        #expect(decoded?.truncID == 0x1234)
        #expect(decoded?.nonce == 0xAABBCCDD)
        #expect(decoded?.pow.0 == pow.0)
        #expect(decoded?.pow.1 == pow.1)
        #expect(decoded?.pow.2 == pow.2)
    }

    @Test("encoded size is 10")
    func encodedSizeIs10() {
        #expect(Tier1Beacon.encodedSize == 10)
        let pow = MicroPoW.solve(truncID: 1, nonce: 1, difficulty: 8)
        let beacon = Tier1Beacon(truncID: 1, pow: pow, nonce: 1)
        #expect(beacon.encode().count == 10)
    }

    @Test("decode invalid tag")
    func decodeInvalidTag() {
        var data = Data(repeating: 0, count: 10)
        data[0] = 0xD1 // Tier2 tag
        #expect(Tier1Beacon.decode(from: data) == nil)
    }

    @Test("decode truncated data")
    func decodeTruncatedData() {
        let data = Data(repeating: 0xD0, count: 9)
        #expect(Tier1Beacon.decode(from: data) == nil)
    }

    @Test("isValid with correct PoW")
    func isValidWithCorrectPoW() {
        let truncID: UInt16 = 0x5678
        let nonce: UInt32 = 0x11223344
        let pow = MicroPoW.solve(truncID: truncID, nonce: nonce, difficulty: 8)
        let beacon = Tier1Beacon(truncID: truncID, pow: pow, nonce: nonce)
        #expect(beacon.isValid(difficulty: 8))
    }

    @Test("isValid with wrong PoW")
    func isValidWithWrongPoW() {
        let beacon = Tier1Beacon(truncID: 0x1234, pow: (0xFF, 0xFF, 0xFF), nonce: 0x11223344)
        #expect(!beacon.isValid())
    }
}
