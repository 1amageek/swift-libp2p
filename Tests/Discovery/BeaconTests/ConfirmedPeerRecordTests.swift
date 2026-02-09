import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("ConfirmedPeerRecord")
struct ConfirmedPeerRecordTests {

    @Test("init defaults")
    func initDefaults() throws {
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        let record = ConfirmedPeerRecord(peerID: kp.peerID, certificate: envelope)
        #expect(record.epoch == 0)
        #expect(record.addresses.isEmpty)
        #expect(record.observations.isEmpty)
        #expect(record.presenceScore == 0)
    }

    @Test("isValid when fresh")
    func isValidWhenFresh() throws {
        let record = try makeConfirmedPeerRecord()
        #expect(record.isValid)
    }

    @Test("isValid when expired")
    func isValidWhenExpired() throws {
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        let record = ConfirmedPeerRecord(
            peerID: kp.peerID,
            certificate: envelope,
            expiresAt: .now - .seconds(1)
        )
        #expect(!record.isValid)
    }

    @Test("defaultTTL is 600 seconds")
    func defaultTTLIs600Seconds() {
        #expect(ConfirmedPeerRecord.defaultTTL == .seconds(600))
    }

    @Test("custom TTL")
    func customTTL() throws {
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        let future = ContinuousClock.now + .seconds(3600)
        let record = ConfirmedPeerRecord(
            peerID: kp.peerID,
            certificate: envelope,
            expiresAt: future
        )
        #expect(record.expiresAt == future)
    }

    @Test("epoch preserved")
    func epochPreserved() throws {
        let record = try makeConfirmedPeerRecord(epoch: 42)
        #expect(record.epoch == 42)
    }
}
