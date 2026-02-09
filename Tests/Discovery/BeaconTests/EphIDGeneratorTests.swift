import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("EphIDGenerator")
struct EphIDGeneratorTests {

    @Test("ephID is 4 bytes")
    func ephIDIs4Bytes() {
        let kp = makeKeyPair()
        let gen = EphIDGenerator(keyPair: kp)
        let id = gen.ephID()
        #expect(id.count == 4)
    }

    @Test("truncID is first 2 bytes")
    func truncIDIsFirst2Bytes() {
        let kp = makeKeyPair()
        let gen = EphIDGenerator(keyPair: kp)
        let now = ContinuousClock.now
        let id = gen.ephID(at: now)
        let truncID = gen.truncID(at: now)
        let expected = id.loadBigEndianUInt16(at: id.startIndex)
        #expect(truncID == expected)
    }

    @Test("nonce is all 4 bytes")
    func nonceIsAll4Bytes() {
        let kp = makeKeyPair()
        let gen = EphIDGenerator(keyPair: kp)
        let now = ContinuousClock.now
        let id = gen.ephID(at: now)
        let nonce = gen.nonce(at: now)
        let expected = id.loadBigEndianUInt32(at: id.startIndex)
        #expect(nonce == expected)
    }

    @Test("deterministic")
    func deterministic() {
        let kp = makeKeyPair()
        let ref = ContinuousClock.now
        let gen = EphIDGenerator(keyPair: kp, referencePoint: ref)
        let instant = ref + .seconds(10)
        let id1 = gen.ephID(at: instant)
        let id2 = gen.ephID(at: instant)
        #expect(id1 == id2)
    }

    @Test("rotation changes ephID")
    func rotationChangesEphID() {
        let kp = makeKeyPair()
        let ref = ContinuousClock.now
        let gen = EphIDGenerator(keyPair: kp, rotationInterval: .seconds(600), referencePoint: ref)
        let id1 = gen.ephID(at: ref)
        let id2 = gen.ephID(at: ref + .seconds(601))
        #expect(id1 != id2)
    }

    @Test("day boundary changes")
    func dayBoundaryChanges() {
        let kp = makeKeyPair()
        let ref = ContinuousClock.now
        let gen = EphIDGenerator(keyPair: kp, referencePoint: ref)
        let day0 = gen.dayNumber(at: ref)
        let day1 = gen.dayNumber(at: ref + .seconds(86400))
        #expect(day1 == day0 + 1)
    }

    @Test("epoch index wraps")
    func epochIndexWraps() {
        let kp = makeKeyPair()
        let ref = ContinuousClock.now
        let gen = EphIDGenerator(keyPair: kp, rotationInterval: .seconds(600), referencePoint: ref)
        // 86400 / 600 = 144 epochs per day
        let epochsPerDay = 144
        let idx = gen.epochIndex(at: ref + .seconds(600 * epochsPerDay))
        #expect(idx >= 0)
        #expect(idx < epochsPerDay)
    }

    @Test("different key pairs different ephIDs")
    func differentKeyPairsDifferentEphIDs() {
        let kp1 = makeKeyPair()
        let kp2 = makeKeyPair()
        let ref = ContinuousClock.now
        let gen1 = EphIDGenerator(keyPair: kp1, referencePoint: ref)
        let gen2 = EphIDGenerator(keyPair: kp2, referencePoint: ref)
        let instant = ref + .seconds(5)
        #expect(gen1.ephID(at: instant) != gen2.ephID(at: instant))
    }
}
