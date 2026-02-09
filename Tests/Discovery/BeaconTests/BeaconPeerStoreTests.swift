import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("BeaconPeerStore")
struct BeaconPeerStoreTests {

    @Test("add and query sighting")
    func addAndQuerySighting() {
        let store = InMemoryBeaconPeerStore()
        let sighting = UnconfirmedSighting(truncID: 0x1234, addresses: [makeOpaqueAddress()])
        store.addSighting(sighting)
        let results = store.sightings(matching: 0x1234)
        #expect(results.count == 1)
        #expect(results[0].truncID == 0x1234)
    }

    @Test("query nonexistent truncID")
    func queryNonexistentTruncID() {
        let store = InMemoryBeaconPeerStore()
        #expect(store.sightings(matching: 0xFFFF).isEmpty)
    }

    @Test("upsert new confirmed")
    func upsertNewConfirmed() throws {
        let store = InMemoryBeaconPeerStore()
        let record = try makeConfirmedPeerRecord()
        store.upsert(record)
        #expect(store.get(record.peerID) != nil)
    }

    @Test("upsert with higher epoch")
    func upsertWithHigherEpoch() throws {
        let store = InMemoryBeaconPeerStore()
        let kp = makeKeyPair()
        let r1 = try makeConfirmedPeerRecord(keyPair: kp, epoch: 2)
        let r2 = try makeConfirmedPeerRecord(keyPair: kp, epoch: 5)
        store.upsert(r1)
        store.upsert(r2)
        let stored = store.get(kp.peerID)
        #expect(stored?.epoch == 5)
    }

    @Test("upsert with lower epoch ignored")
    func upsertWithLowerEpochIgnored() throws {
        let store = InMemoryBeaconPeerStore()
        let kp = makeKeyPair()
        let r1 = try makeConfirmedPeerRecord(keyPair: kp, epoch: 5)
        let r2 = try makeConfirmedPeerRecord(keyPair: kp, epoch: 2)
        store.upsert(r1)
        store.upsert(r2)
        let stored = store.get(kp.peerID)
        #expect(stored?.epoch == 5)
    }

    @Test("promote sighting")
    func promoteSighting() throws {
        let store = InMemoryBeaconPeerStore()
        let sighting = UnconfirmedSighting(truncID: 0x1111)
        store.addSighting(sighting)

        let record = try makeConfirmedPeerRecord()
        store.promoteSighting(truncID: 0x1111, to: record)

        #expect(store.sightings(matching: 0x1111).isEmpty)
        #expect(store.get(record.peerID) != nil)
    }

    @Test("remove expired")
    func removeExpired() throws {
        let store = InMemoryBeaconPeerStore()
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        let expired = ConfirmedPeerRecord(
            peerID: kp.peerID,
            certificate: envelope,
            expiresAt: .now - .seconds(1)
        )
        store.upsert(expired)
        #expect(store.get(kp.peerID) != nil)
        store.removeExpired()
        #expect(store.get(kp.peerID) == nil)
    }

    @Test("all confirmed")
    func allConfirmed() throws {
        let store = InMemoryBeaconPeerStore()
        let r1 = try makeConfirmedPeerRecord()
        let r2 = try makeConfirmedPeerRecord()
        store.upsert(r1)
        store.upsert(r2)
        #expect(store.allConfirmed().count == 2)
    }

    @Test("confirmed newer than")
    func confirmedNewerThan() throws {
        let store = InMemoryBeaconPeerStore()
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)

        let past = ContinuousClock.now - .seconds(10)
        let r = ConfirmedPeerRecord(
            peerID: kp.peerID,
            certificate: envelope,
            expiresAt: .now + .seconds(600)
        )
        store.upsert(r)

        let results = store.confirmedNewerThan(past)
        #expect(results.count == 1)

        let futureFilter = ContinuousClock.now + .seconds(700)
        let emptyResults = store.confirmedNewerThan(futureFilter)
        #expect(emptyResults.isEmpty)
    }
}
