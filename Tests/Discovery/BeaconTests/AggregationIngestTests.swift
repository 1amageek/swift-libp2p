import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("AggregationIngest")
struct AggregationIngestTests {

    @Test("ingest tier1 creates new sighting", .timeLimit(.minutes(1)))
    func ingestTier1CreatesNewSighting() async {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)
        let events = ingest.aggregationEvents

        let event = BeaconDiscoveryEvent(
            tier: .tier1,
            truncID: 0x1234,
            source: makeOpaqueAddress(),
            directObservationTrust: 0.5
        )
        ingest.ingest(event)

        var received: AggregationResult?
        for await result in events {
            received = result
            break
        }

        if case .newSighting(let sighting) = received {
            #expect(sighting.truncID == 0x1234)
        } else {
            Issue.record("Expected newSighting")
        }
        ingest.shutdown()
    }

    @Test("ingest tier1 updates existing", .timeLimit(.minutes(1)))
    func ingestTier1UpdatesExisting() async {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)
        let events = ingest.aggregationEvents

        let source = makeOpaqueAddress()
        let e1 = BeaconDiscoveryEvent(
            tier: .tier1, truncID: 0x5678,
            source: source, directObservationTrust: 0.5
        )
        let e2 = BeaconDiscoveryEvent(
            tier: .tier1, truncID: 0x5678,
            source: source, directObservationTrust: 0.5
        )
        ingest.ingest(e1)
        ingest.ingest(e2)

        var count = 0
        var lastResult: AggregationResult?
        for await result in events {
            count += 1
            lastResult = result
            if count >= 2 { break }
        }
        if case .sightingUpdated(let truncID, _) = lastResult {
            #expect(truncID == 0x5678)
        } else {
            Issue.record("Expected sightingUpdated")
        }
        ingest.shutdown()
    }

    @Test("ingest tier3 creates new confirmed", .timeLimit(.minutes(1)))
    func ingestTier3CreatesNewConfirmed() async throws {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)
        let events = ingest.aggregationEvents

        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp, seq: 1)

        let event = BeaconDiscoveryEvent(
            tier: .tier3,
            fullPeerID: kp.peerID,
            source: makeOpaqueAddress(),
            directObservationTrust: 0.8,
            envelope: envelope
        )
        ingest.ingest(event)

        var received: AggregationResult?
        for await result in events {
            received = result
            break
        }

        if case .newConfirmed(let record) = received {
            #expect(record.peerID == kp.peerID)
        } else {
            Issue.record("Expected newConfirmed")
        }
        ingest.shutdown()
    }

    @Test("ingest tier3 updates existing", .timeLimit(.minutes(1)))
    func ingestTier3UpdatesExisting() async throws {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)
        let events = ingest.aggregationEvents

        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp, seq: 1)
        let source = makeOpaqueAddress()

        let e1 = BeaconDiscoveryEvent(
            tier: .tier3, fullPeerID: kp.peerID,
            source: source, directObservationTrust: 0.8, envelope: envelope
        )
        let e2 = BeaconDiscoveryEvent(
            tier: .tier3, fullPeerID: kp.peerID,
            source: source, directObservationTrust: 0.8, envelope: envelope
        )
        ingest.ingest(e1)
        ingest.ingest(e2)

        var count = 0
        var lastResult: AggregationResult?
        for await result in events {
            count += 1
            lastResult = result
            if count >= 2 { break }
        }
        if case .confirmedUpdated(let peerID, _) = lastResult {
            #expect(peerID == kp.peerID)
        } else {
            Issue.record("Expected confirmedUpdated")
        }
        ingest.shutdown()
    }

    @Test("ingest tier3 without envelope ignored")
    func ingestTier3WithoutEnvelopeIgnored() {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)

        let kp = makeKeyPair()
        let event = BeaconDiscoveryEvent(
            tier: .tier3,
            fullPeerID: kp.peerID,
            source: makeOpaqueAddress(),
            directObservationTrust: 0.8,
            envelope: nil
        )
        ingest.ingest(event)

        // No confirmed record should be created
        #expect(store.get(kp.peerID) == nil)
        ingest.shutdown()
    }

    @Test("ingest tier3 PeerID mismatch ignored")
    func ingestTier3PeerIDMismatchIgnored() throws {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)

        let kp1 = makeKeyPair()
        let kp2 = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp1) // signed by kp1

        let event = BeaconDiscoveryEvent(
            tier: .tier3,
            fullPeerID: kp2.peerID, // different peer
            source: makeOpaqueAddress(),
            directObservationTrust: 0.8,
            envelope: envelope
        )
        ingest.ingest(event)

        // Should not create a record for either peer
        #expect(store.get(kp2.peerID) == nil)
        ingest.shutdown()
    }

    @Test("sighting promotion on tier3", .timeLimit(.minutes(1)))
    func sightingPromotionOnTier3() async throws {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)
        let events = ingest.aggregationEvents

        let kp = makeKeyPair()
        let ephGen = EphIDGenerator(keyPair: kp)
        let truncID = ephGen.truncID()

        // First: unconfirmed sighting
        let e1 = BeaconDiscoveryEvent(
            tier: .tier1, truncID: truncID,
            source: makeOpaqueAddress(),
            directObservationTrust: 0.5
        )
        ingest.ingest(e1)

        // Wait for first event
        var firstResult: AggregationResult?
        for await r in events {
            firstResult = r
            break
        }
        #expect(firstResult != nil)

        // Then: tier3 with same truncID
        let envelope = try makeEnvelope(keyPair: kp, seq: 1)
        let e2 = BeaconDiscoveryEvent(
            tier: .tier3, truncID: truncID, fullPeerID: kp.peerID,
            source: makeOpaqueAddress(),
            directObservationTrust: 0.8, envelope: envelope
        )
        ingest.ingest(e2)

        var secondResult: AggregationResult?
        for await r in events {
            secondResult = r
            break
        }

        if case .promoted(let from, let to) = secondResult {
            #expect(from == truncID)
            #expect(to.peerID == kp.peerID)
        } else {
            Issue.record("Expected promoted, got \(String(describing: secondResult))")
        }
        ingest.shutdown()
    }

    @Test("freshness selection by medium")
    func freshnessSelectionByMedium() {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)

        // Ingest BLE event
        let bleEvent = BeaconDiscoveryEvent(
            tier: .tier1, truncID: 0x0001,
            source: makeOpaqueAddress(medium: "ble"),
            directObservationTrust: 0.5
        )
        ingest.ingest(bleEvent)

        let sightings = store.sightings(matching: 0x0001)
        #expect(!sightings.isEmpty)
        ingest.shutdown()
    }

    @Test("shutdown finishes stream", .timeLimit(.minutes(1)))
    func shutdownFinishesStream() async {
        let store = InMemoryBeaconPeerStore()
        let ingest = AggregationIngest(store: store)
        let events = ingest.aggregationEvents

        ingest.shutdown()

        var count = 0
        for await _ in events {
            count += 1
        }
        #expect(count == 0)
    }
}
