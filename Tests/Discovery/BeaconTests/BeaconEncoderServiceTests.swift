import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("BeaconEncoderService")
struct BeaconEncoderServiceTests {

    let encoder = BeaconEncoderService()

    @Test("selectTier prefers highest")
    func selectTierPrefersHighest() {
        #expect(encoder.selectTier(maxBeaconSize: 500) == .tier3)
    }

    @Test("selectTier falls to tier2")
    func selectTierFallsToTier2() {
        #expect(encoder.selectTier(maxBeaconSize: 144) == .tier2)
    }

    @Test("selectTier falls to tier1")
    func selectTierFallsToTier1() {
        #expect(encoder.selectTier(maxBeaconSize: 31) == .tier1)
    }

    @Test("selectTier returns nil for too small")
    func selectTierReturnsNilForTooSmall() {
        #expect(encoder.selectTier(maxBeaconSize: 9) == nil)
    }

    @Test("encode tier1 roundtrip")
    func encodeTier1Roundtrip() {
        let data = encoder.encodeTier1(truncID: 0x1234, nonce: 0xAABBCCDD, difficulty: 8)
        let decoded = encoder.decode(payload: data)
        #expect(decoded != nil)
        #expect(decoded?.tier == .tier1)
        #expect(decoded?.truncID == 0x1234)
    }

    @Test("encode tier2 roundtrip")
    func encodeTier2Roundtrip() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x01, count: 32))
        let data = encoder.encodeTier2(
            truncID: 0x5678,
            nonce: 0x11223344,
            tesla: tesla,
            capBloom: Data(repeating: 0xFF, count: 10),
            difficulty: 8
        )
        let decoded = encoder.decode(payload: data)
        #expect(decoded != nil)
        #expect(decoded?.tier == .tier2)
        #expect(decoded?.truncID == 0x5678)
        #expect(decoded?.teslaMAC?.count == 4)
        #expect(decoded?.teslaPrevKey?.count == 8)
        #expect(decoded?.capabilityBloom?.count == 10)
    }

    @Test("encode tier3 roundtrip")
    func encodeTier3Roundtrip() throws {
        let kp = makeKeyPair()
        let data = try encoder.encodeTier3(keyPair: kp, nonce: 0xDEADBEEF)
        let decoded = encoder.decode(payload: data)
        #expect(decoded != nil)
        #expect(decoded?.tier == .tier3)
        #expect(decoded?.fullID == kp.peerID)
        #expect(decoded?.envelope != nil)
    }

    @Test("decode invalid payload")
    func decodeInvalidPayload() {
        let random = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        #expect(encoder.decode(payload: random) == nil)
    }

    @Test("decode empty payload")
    func decodeEmptyPayload() {
        #expect(encoder.decode(payload: Data()) == nil)
    }

    @Test("decode tier1 nonce")
    func decodeTier1Nonce() {
        let data = encoder.encodeTier1(truncID: 0x1111, nonce: 0x22334455, difficulty: 8)
        let decoded = encoder.decode(payload: data)
        #expect(decoded?.nonce.count == 4)
    }

    @Test("tier2 capBloom padding")
    func tier2CapBloomPadding() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x02, count: 32))
        let shortBloom = Data([0x01, 0x02, 0x03]) // only 3 bytes
        let data = encoder.encodeTier2(
            truncID: 0x1234,
            nonce: 0x11111111,
            tesla: tesla,
            capBloom: shortBloom,
            difficulty: 8
        )
        #expect(data.count == 32)
        let decoded = encoder.decode(payload: data)
        #expect(decoded?.capabilityBloom?.count == 10)
    }

    @Test("tier3 with addresses")
    func tier3WithAddresses() throws {
        let kp = makeKeyPair()
        let addrs = [
            OpaqueAddress(mediumID: "ble", raw: Data([0x01, 0x02])),
            OpaqueAddress(mediumID: "lora", raw: Data([0x03]))
        ]
        let data = try encoder.encodeTier3(keyPair: kp, nonce: 1, addresses: addrs)
        let decoded = encoder.decode(payload: data)
        #expect(decoded?.tier == .tier3)
        let record = try decoded?.envelope?.record(as: BeaconPeerRecord.self)
        #expect(record?.opaqueAddresses.count == 2)
    }
}
