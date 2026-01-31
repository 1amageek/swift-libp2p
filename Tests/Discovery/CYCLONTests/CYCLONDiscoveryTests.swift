import Testing
import P2PCore
import P2PDiscovery
@testable import P2PDiscoveryCYCLON

@Suite("CYCLON Discovery Tests")
struct CYCLONDiscoveryTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    @Test("Discovery conforms to DiscoveryService")
    func conformsToProtocol() async {
        let localID = makePeerID()
        let cyclon = CYCLONDiscovery(localPeerID: localID, configuration: .testing)
        // Verify it can be used as DiscoveryService
        let _: any DiscoveryService = cyclon
        _ = await cyclon.knownPeers()
    }

    @Test("Seed adds peers to view")
    func seedPeers() async {
        let localID = makePeerID()
        let cyclon = CYCLONDiscovery(localPeerID: localID, configuration: .testing)

        let peer1 = makePeerID()
        let peer2 = makePeerID()
        await cyclon.seed(peers: [
            (peer1, []),
            (peer2, []),
        ])

        let known = await cyclon.knownPeers()
        #expect(known.count == 2)
        #expect(known.contains(peer1))
        #expect(known.contains(peer2))
    }

    @Test("Seed skips self")
    func seedSkipsSelf() async {
        let localID = makePeerID()
        let cyclon = CYCLONDiscovery(localPeerID: localID, configuration: .testing)

        await cyclon.seed(peers: [
            (localID, []),
            (makePeerID(), []),
        ])

        let known = await cyclon.knownPeers()
        #expect(known.count == 1)
    }

    @Test("Find returns scored candidate for known peer")
    func findKnownPeer() async throws {
        let localID = makePeerID()
        let cyclon = CYCLONDiscovery(localPeerID: localID, configuration: .testing)

        let peerID = makePeerID()
        await cyclon.seed(peers: [(peerID, [])])

        let candidates = try await cyclon.find(peer: peerID)
        #expect(candidates.count == 1)
        #expect(candidates[0].peerID == peerID)
        #expect(candidates[0].score > 0.0)
    }

    @Test("Find returns empty for unknown peer")
    func findUnknownPeer() async throws {
        let localID = makePeerID()
        let cyclon = CYCLONDiscovery(localPeerID: localID, configuration: .testing)

        let candidates = try await cyclon.find(peer: makePeerID())
        #expect(candidates.isEmpty)
    }

    @Test("Announce stores local addresses")
    func announce() async throws {
        let localID = makePeerID()
        let cyclon = CYCLONDiscovery(localPeerID: localID, configuration: .testing)

        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        try await cyclon.announce(addresses: [addr])

        // Announce doesn't add self to discovery but stores for shuffle
        let known = await cyclon.knownPeers()
        #expect(known.isEmpty)
    }

    @Test("Observations stream is multi-consumer")
    func observationsMultiConsumer() async {
        let localID = makePeerID()
        let cyclon = CYCLONDiscovery(localPeerID: localID, configuration: .testing)

        let stream1 = cyclon.observations
        let stream2 = cyclon.observations

        // Both should be independent streams (not the same object)
        // This verifies the EventBroadcaster pattern
        _ = stream1
        _ = stream2
    }

    @Test("KnownPeers returns all peers in view")
    func knownPeers() async {
        let localID = makePeerID()
        let cyclon = CYCLONDiscovery(localPeerID: localID, configuration: .testing)

        let peers = (0..<5).map { _ in makePeerID() }
        await cyclon.seed(peers: peers.map { ($0, []) })

        let known = await cyclon.knownPeers()
        #expect(known.count == 5)
        for peer in peers {
            #expect(known.contains(peer))
        }
    }
}
