import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("BeaconTier")
struct BeaconTierTests {

    @Test("tagByte encoding for all tiers")
    func tagByteEncodingForAllTiers() {
        #expect(BeaconTier.tier1.tagByte == 0xD0)
        #expect(BeaconTier.tier2.tagByte == 0xD1)
        #expect(BeaconTier.tier3.tagByte == 0xD2)
    }

    @Test("init from valid tag byte")
    func initFromValidTagByte() {
        #expect(BeaconTier(tagByte: 0xD0) == .tier1)
        #expect(BeaconTier(tagByte: 0xD1) == .tier2)
        #expect(BeaconTier(tagByte: 0xD2) == .tier3)
    }

    @Test("init from invalid tag byte returns nil")
    func initFromInvalidTagByte() {
        #expect(BeaconTier(tagByte: 0x00) == nil)
        #expect(BeaconTier(tagByte: 0xFF) == nil)
        #expect(BeaconTier(tagByte: 0xD3) == nil)
    }

    @Test("minimum size per tier")
    func minimumSizePerTier() {
        #expect(BeaconTier.tier1.minimumSize == 10)
        #expect(BeaconTier.tier2.minimumSize == 32)
        #expect(BeaconTier.tier3.minimumSize == 145)
    }

    @Test("rawValue roundtrip")
    func rawValueRoundtrip() {
        for tier in [BeaconTier.tier1, .tier2, .tier3] {
            let raw = tier.rawValue
            #expect(BeaconTier(rawValue: raw) == tier)
        }
    }
}
