import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("BeaconDiscovery")
struct BeaconDiscoveryTests {

    private func makeService(difficulty: Int = 8) -> BeaconDiscovery {
        let kp = makeKeyPair()
        let config = BeaconDiscoveryConfiguration(keyPair: kp, powDifficulty: difficulty)
        return BeaconDiscovery(configuration: config)
    }

    @Test("start and stop", .timeLimit(.minutes(1)))
    func startAndStop() async {
        let service = makeService()
        service.start()
        // Should not crash on double start
        service.start()
        await service.stop()
    }

    @Test("stop is idempotent", .timeLimit(.minutes(1)))
    func stopIsIdempotent() async {
        let service = makeService()
        service.start()
        await service.stop()
        await service.stop() // second stop should not crash
    }

    @Test("encode beacon tier1")
    func encodeBeaconTier1() throws {
        let service = makeService()
        let data = try service.encodeBeacon(maxSize: 10)
        #expect(data.count == 10)
    }

    @Test("encode beacon tier2")
    func encodeBeaconTier2() throws {
        let service = makeService()
        let data = try service.encodeBeacon(maxSize: 32)
        #expect(data.count == 32)
    }

    @Test("encode beacon tier3")
    func encodeBeaconTier3() throws {
        let service = makeService()
        let data = try service.encodeBeacon(maxSize: 500)
        #expect(data.count >= Tier3Beacon.minHeaderSize)
    }

    @Test("encode beacon too small")
    func encodeBeaconTooSmall() {
        let service = makeService()
        #expect(throws: BeaconEncodingError.self) {
            try service.encodeBeacon(maxSize: 5)
        }
    }

    @Test("announce addresses", .timeLimit(.minutes(1)))
    func announceAddresses() async throws {
        let kp = makeKeyPair()
        let config = BeaconDiscoveryConfiguration(keyPair: kp, powDifficulty: 8)
        let service = BeaconDiscovery(configuration: config)

        let bleAddr = OpaqueAddress(mediumID: "ble", raw: Data([0x01, 0x02]))
        let codec = BeaconAddressCodec()
        let multiaddr = try codec.toMultiaddr(bleAddr)
        try await service.announce(addresses: [multiaddr])

        // Encode a tier3 beacon which should include the address
        let data = try service.encodeBeacon(maxSize: 500)
        #expect(data.count > 0)
    }

    @Test("find peer returns candidate", .timeLimit(.minutes(1)))
    func findPeerReturnsCandidate() async throws {
        let kp = makeKeyPair()
        let store = InMemoryBeaconPeerStore()
        let record = try makeConfirmedPeerRecord(keyPair: kp)
        store.upsert(record)

        let config = BeaconDiscoveryConfiguration(keyPair: makeKeyPair(), store: store)
        let service = BeaconDiscovery(configuration: config)

        let candidates = try await service.find(peer: kp.peerID)
        #expect(candidates.count == 1)
        #expect(candidates[0].peerID == kp.peerID)
    }

    @Test("find peer returns empty for unknown", .timeLimit(.minutes(1)))
    func findPeerReturnsEmptyForUnknown() async throws {
        let service = makeService()
        let candidates = try await service.find(peer: makePeerID())
        #expect(candidates.isEmpty)
    }

    @Test("known peers excludes self", .timeLimit(.minutes(1)))
    func knownPeersExcludesSelf() async throws {
        let localKP = makeKeyPair()
        let store = InMemoryBeaconPeerStore()
        // Add self
        let selfRecord = try makeConfirmedPeerRecord(keyPair: localKP)
        store.upsert(selfRecord)
        // Add other
        let otherRecord = try makeConfirmedPeerRecord()
        store.upsert(otherRecord)

        let config = BeaconDiscoveryConfiguration(keyPair: localKP, store: store)
        let service = BeaconDiscovery(configuration: config)

        let peers = await service.knownPeers()
        #expect(!peers.contains(localKP.peerID))
        #expect(peers.contains(otherRecord.peerID))
    }

    @Test("process discovery valid beacon", .timeLimit(.minutes(1)))
    func processDiscoveryValidBeacon() async throws {
        let localKP = makeKeyPair()
        let config = BeaconDiscoveryConfiguration(keyPair: localKP, powDifficulty: 8)
        let service = BeaconDiscovery(configuration: config)
        service.start()

        // Create a valid tier1 beacon from another peer
        let encoder = BeaconEncoderService()
        let payload = encoder.encodeTier1(truncID: 0x1234, nonce: 0xAABBCCDD, difficulty: 8)

        let discovery = RawDiscovery(
            payload: payload,
            sourceAddress: makeOpaqueAddress(),
            timestamp: .now,
            rssi: -60.0,
            mediumID: "ble",
            physicalFingerprint: nil
        )
        service.processDiscovery(discovery)
        await service.stop()
    }

    @Test("process discovery invalid beacon")
    func processDiscoveryInvalidBeacon() {
        let service = makeService()
        let discovery = RawDiscovery(
            payload: Data([0xFF, 0xFF, 0xFF]),
            sourceAddress: makeOpaqueAddress(),
            timestamp: .now,
            rssi: nil,
            mediumID: "ble",
            physicalFingerprint: nil
        )
        // Should not crash
        service.processDiscovery(discovery)
    }
}
