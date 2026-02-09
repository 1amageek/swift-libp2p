import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("PhysicalFingerprint")
struct PhysicalFingerprintTests {

    @Test("all nil fields")
    func allNilFields() {
        let fp = PhysicalFingerprint()
        #expect(fp.txPower == nil)
        #expect(fp.channelIndex == nil)
        #expect(fp.timingOffsetMicros == nil)
        #expect(fp.angleOfArrivalDegrees == nil)
    }

    @Test("all fields populated")
    func allFieldsPopulated() {
        let fp = PhysicalFingerprint(
            txPower: -20,
            channelIndex: 37,
            timingOffsetMicros: 1500,
            angleOfArrivalDegrees: 45
        )
        #expect(fp.txPower == -20)
        #expect(fp.channelIndex == 37)
        #expect(fp.timingOffsetMicros == 1500)
        #expect(fp.angleOfArrivalDegrees == 45)
    }

    @Test("Hashable equal values")
    func hashableEqualValues() {
        let a = PhysicalFingerprint(txPower: -10, channelIndex: 38)
        let b = PhysicalFingerprint(txPower: -10, channelIndex: 38)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Hashable different values")
    func hashableDifferentValues() {
        let a = PhysicalFingerprint(txPower: -10)
        let b = PhysicalFingerprint(txPower: -20)
        #expect(a != b)
    }
}
