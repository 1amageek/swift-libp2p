import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("Tier2Beacon")
struct Tier2BeaconTests {

    @Test("encode/decode roundtrip")
    func encodeDecodeRoundtrip() {
        let pow = MicroPoW.solve(truncID: 0xABCD, nonce: 0x12345678, difficulty: 8)
        let beacon = Tier2Beacon(
            truncID: 0xABCD,
            pow: pow,
            nonce: 0x12345678,
            macT: Data(repeating: 0xAA, count: 4),
            keyP: Data(repeating: 0xBB, count: 8),
            capBloom: Data(repeating: 0xCC, count: 10)
        )
        let encoded = beacon.encode()
        let decoded = Tier2Beacon.decode(from: encoded)
        #expect(decoded != nil)
        #expect(decoded?.truncID == 0xABCD)
        #expect(decoded?.nonce == 0x12345678)
    }

    @Test("encoded size is 32")
    func encodedSizeIs32() {
        #expect(Tier2Beacon.encodedSize == 32)
        let pow = MicroPoW.solve(truncID: 1, nonce: 1, difficulty: 8)
        let beacon = Tier2Beacon(
            truncID: 1, pow: pow, nonce: 1,
            macT: Data(repeating: 0, count: 4),
            keyP: Data(repeating: 0, count: 8),
            capBloom: Data(repeating: 0, count: 10)
        )
        #expect(beacon.encode().count == 32)
    }

    @Test("macT is 4 bytes")
    func macTIs4Bytes() {
        let pow = MicroPoW.solve(truncID: 1, nonce: 1, difficulty: 8)
        let beacon = Tier2Beacon(
            truncID: 1, pow: pow, nonce: 1,
            macT: Data([0x11, 0x22, 0x33, 0x44]),
            keyP: Data(repeating: 0, count: 8),
            capBloom: Data(repeating: 0, count: 10)
        )
        let encoded = beacon.encode()
        let decoded = Tier2Beacon.decode(from: encoded)
        #expect(decoded?.macT == Data([0x11, 0x22, 0x33, 0x44]))
    }

    @Test("keyP is 8 bytes")
    func keyPIs8Bytes() {
        let pow = MicroPoW.solve(truncID: 1, nonce: 1, difficulty: 8)
        let keyP = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let beacon = Tier2Beacon(
            truncID: 1, pow: pow, nonce: 1,
            macT: Data(repeating: 0, count: 4),
            keyP: keyP,
            capBloom: Data(repeating: 0, count: 10)
        )
        let decoded = Tier2Beacon.decode(from: beacon.encode())
        #expect(decoded?.keyP == keyP)
    }

    @Test("capBloom is 10 bytes")
    func capBloomIs10Bytes() {
        let pow = MicroPoW.solve(truncID: 1, nonce: 1, difficulty: 8)
        let bloom = Data(repeating: 0xFF, count: 10)
        let beacon = Tier2Beacon(
            truncID: 1, pow: pow, nonce: 1,
            macT: Data(repeating: 0, count: 4),
            keyP: Data(repeating: 0, count: 8),
            capBloom: bloom
        )
        let decoded = Tier2Beacon.decode(from: beacon.encode())
        #expect(decoded?.capBloom == bloom)
    }

    @Test("decode invalid tag")
    func decodeInvalidTag() {
        var data = Data(repeating: 0, count: 32)
        data[0] = 0xD0 // Tier1 tag
        #expect(Tier2Beacon.decode(from: data) == nil)
    }

    @Test("decode truncated data")
    func decodeTruncatedData() {
        let data = Data(repeating: 0xD1, count: 31)
        #expect(Tier2Beacon.decode(from: data) == nil)
    }
}
