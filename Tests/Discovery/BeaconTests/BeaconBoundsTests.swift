import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

// MARK: - Store Bounds

@Suite("Beacon Store Bounds")
struct BeaconStoreBoundsTests {

    @Test("confirmed records are bounded under churn")
    func confirmedBounded() throws {
        let cap = 8
        let store = InMemoryBeaconPeerStore(maxConfirmedPeers: cap)
        // Insert far more distinct peers than the cap (Sybil churn).
        for _ in 0..<100 {
            let record = try makeConfirmedPeerRecord()
            store.upsert(record)
        }
        #expect(store.confirmedCount() <= cap)
    }

    @Test("promoted sightings respect the confirmed cap")
    func promoteBounded() throws {
        let cap = 4
        let store = InMemoryBeaconPeerStore(maxConfirmedPeers: cap)
        for i in 0..<50 {
            let kp = makeKeyPair()
            let envelope = try makeEnvelope(keyPair: kp)
            let record = ConfirmedPeerRecord(peerID: kp.peerID, certificate: envelope)
            store.addSighting(UnconfirmedSighting(truncID: UInt16(i)))
            store.promoteSighting(truncID: UInt16(i), to: record)
        }
        #expect(store.confirmedCount() <= cap)
    }

    @Test("unconfirmed sightings are bounded under churn")
    func unconfirmedBounded() {
        let cap = 16
        let store = InMemoryBeaconPeerStore(maxUnconfirmedSightings: cap)
        for i in 0..<1000 {
            // Distinct truncIDs to force growth.
            store.addSighting(UnconfirmedSighting(
                truncID: UInt16(i & 0xFFFF),
                observations: [makeBeaconObservation(timestamp: .now)]
            ))
        }
        #expect(store.unconfirmedCount() <= cap)
    }

    @Test("eviction keeps the most recently observed sighting")
    func unconfirmedKeepsRecent() {
        let store = InMemoryBeaconPeerStore(maxUnconfirmedSightings: 2)
        let old = ContinuousClock.now
        store.addSighting(UnconfirmedSighting(
            truncID: 1, observations: [makeBeaconObservation(timestamp: old)]
        ))
        store.addSighting(UnconfirmedSighting(
            truncID: 2, observations: [makeBeaconObservation(timestamp: old + .seconds(10))]
        ))
        // Inserting #3 evicts the oldest (#1).
        store.addSighting(UnconfirmedSighting(
            truncID: 3, observations: [makeBeaconObservation(timestamp: old + .seconds(20))]
        ))
        #expect(store.sightings(matching: 1).isEmpty)
        #expect(!store.sightings(matching: 2).isEmpty)
        #expect(!store.sightings(matching: 3).isEmpty)
    }
}

// MARK: - Filter Bounds

@Suite("Beacon Filter Bounds")
struct BeaconFilterBoundsTests {

    @Test("rate-limit map is bounded under churn")
    func recentBeaconsBounded() {
        let cap = 32
        let filter = BeaconFilter(maxRecentBeacons: cap)
        // Distinct truncIDs from distinct media → many distinct keys.
        for i in 0..<2000 {
            let beacon = DecodedBeacon(
                tier: .tier1, truncID: UInt16(i & 0xFFFF),
                nonce: Data([0, 0, 0, 1]), powValid: true
            )
            let discovery = makeRawDiscovery(
                payload: Data(repeating: 0xD0, count: 10),
                medium: "ble-\(i % 4)"
            )
            _ = filter.accept(discovery, beacon: beacon, minInterval: .seconds(5))
        }
        #expect(filter.recentBeaconCount() <= cap)
    }

    @Test("fingerprint cluster map is bounded under churn")
    func fingerprintsBounded() {
        let cap = 16
        let filter = BeaconFilter(maxFingerprints: cap)
        for i in 0..<2000 {
            let beacon = DecodedBeacon(
                tier: .tier1, truncID: UInt16(i & 0xFFFF),
                nonce: Data([0, 0, 0, 1]), powValid: true
            )
            let fp = PhysicalFingerprint(timingOffsetMicros: Int64(i))
            let discovery = makeRawDiscovery(
                payload: Data(repeating: 0xD0, count: 10),
                medium: "ble-\(i)",
                fingerprint: fp
            )
            _ = filter.accept(discovery, beacon: beacon, minInterval: .seconds(0))
        }
        #expect(filter.fingerprintCount() <= cap)
    }

    @Test("pruneExpired clears stale entries")
    func pruneExpired() {
        let filter = BeaconFilter(sybilWindow: .milliseconds(1))
        let beacon = DecodedBeacon(
            tier: .tier1, truncID: 0x1234,
            nonce: Data([0, 0, 0, 1]), powValid: true
        )
        let fp = PhysicalFingerprint(txPower: -10)
        let discovery = makeRawDiscovery(
            payload: Data(repeating: 0xD0, count: 10), fingerprint: fp
        )
        _ = filter.accept(discovery, beacon: beacon, minInterval: .seconds(0))
        #expect(filter.fingerprintCount() >= 1)
        // After the window elapses, pruning removes the stale fingerprint.
        Thread.sleep(forTimeInterval: 0.02)
        filter.pruneExpired()
        #expect(filter.fingerprintCount() == 0)
    }
}

// MARK: - GC Scheduling

@Suite("Beacon GC Scheduling")
struct BeaconGCSchedulingTests {

    @Test("runGarbageCollection removes expired confirmed records")
    func gcRemovesExpired() throws {
        let store = InMemoryBeaconPeerStore()
        let config = BeaconDiscoveryConfiguration(keyPair: makeKeyPair(), store: store, gcInterval: nil)
        let service = BeaconDiscovery(configuration: config)

        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        store.upsert(ConfirmedPeerRecord(
            peerID: kp.peerID, certificate: envelope, expiresAt: .now - .seconds(1)
        ))
        #expect(store.get(kp.peerID) != nil)

        service.runGarbageCollection()
        #expect(store.get(kp.peerID) == nil)
    }

    @Test("scheduled GC task runs and prunes under churn")
    func scheduledGCRuns() async throws {
        let store = InMemoryBeaconPeerStore()
        // Very short GC interval so the scheduled task fires during the test.
        let config = BeaconDiscoveryConfiguration(
            keyPair: makeKeyPair(),
            store: store,
            gcInterval: .milliseconds(20)
        )
        let service = BeaconDiscovery(configuration: config)

        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        store.upsert(ConfirmedPeerRecord(
            peerID: kp.peerID, certificate: envelope, expiresAt: .now - .seconds(1)
        ))

        service.start()
        // Wait for at least one GC tick.
        var removed = false
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            if store.get(kp.peerID) == nil { removed = true; break }
        }
        try await service.shutdown()
        #expect(removed)
    }

    @Test("GC task is cancelled on shutdown")
    func gcCancelledOnShutdown() async throws {
        let store = InMemoryBeaconPeerStore()
        let config = BeaconDiscoveryConfiguration(
            keyPair: makeKeyPair(),
            store: store,
            gcInterval: .milliseconds(20)
        )
        let service = BeaconDiscovery(configuration: config)
        service.start()
        try await service.shutdown()
        // After shutdown, inserting an expired record must NOT be auto-removed
        // because the GC task is cancelled.
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        store.upsert(ConfirmedPeerRecord(
            peerID: kp.peerID, certificate: envelope, expiresAt: .now - .seconds(1)
        ))
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.get(kp.peerID) != nil)
    }
}
