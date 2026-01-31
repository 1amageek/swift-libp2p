/// OpportunisticGraftTests - Tests for GossipSub v1.1 opportunistic grafting
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore
@testable import P2PMux

@Suite("Opportunistic Graft Tests", .serialized)
struct OpportunisticGraftTests {

    // MARK: - Helpers

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeRouter(
        configuration: GossipSubConfiguration = .testing
    ) -> GossipSubRouter {
        let localPeerID = makePeerID()
        return GossipSubRouter(localPeerID: localPeerID, configuration: configuration)
    }

    // MARK: - Tests

    @Test("Opportunistic graft triggers when mesh median score is low")
    func opportunisticGraftTriggers() throws {
        var config = GossipSubConfiguration.testing
        config.opportunisticGraftThreshold = 5.0
        config.opportunisticGraftPeers = 2
        let router = makeRouter(configuration: config)
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Add low-score peers to mesh
        let meshPeer1 = makePeerID()
        let meshPeer2 = makePeerID()
        router.meshState.addToMesh(meshPeer1, for: topic)
        router.meshState.addToMesh(meshPeer2, for: topic)

        // Add high-score non-mesh peer that is subscribed
        let candidatePeer = makePeerID()
        let candidateState = PeerState(
            peerID: candidatePeer,
            version: .v11,
            direction: .outbound
        )
        router.peerState.addPeer(candidateState, stream: GossipSubMockStream())
        router.peerState.updatePeer(candidatePeer) { state in
            state.subscriptions.insert(topic)
        }
        // Give candidate peer a higher score via message deliveries
        for _ in 0..<10 {
            router.peerScorer.recordMessageDelivery(from: candidatePeer, isFirst: true)
        }

        let actions = router.opportunisticGraft()

        // Should have grafted the high-score candidate
        let graftedPeers = actions.map(\.peer)
        #expect(graftedPeers.contains(candidatePeer))
    }

    @Test("Opportunistic graft skips when mesh quality is high")
    func opportunisticGraftSkipsHighQualityMesh() throws {
        var config = GossipSubConfiguration.testing
        config.opportunisticGraftThreshold = 0.0  // Very low threshold
        config.opportunisticGraftPeers = 2
        let router = makeRouter(configuration: config)
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Add peers to mesh with positive scores
        let meshPeer1 = makePeerID()
        let meshPeer2 = makePeerID()
        router.meshState.addToMesh(meshPeer1, for: topic)
        router.meshState.addToMesh(meshPeer2, for: topic)

        // Give mesh peers good scores
        for peer in [meshPeer1, meshPeer2] {
            for _ in 0..<5 {
                router.peerScorer.recordMessageDelivery(from: peer, isFirst: true)
            }
        }

        let actions = router.opportunisticGraft()

        // Should not graft anyone - mesh quality is already high
        #expect(actions.isEmpty)
    }

    @Test("Opportunistic graft respects peer count limit")
    func opportunisticGraftRespectsLimit() throws {
        var config = GossipSubConfiguration.testing
        config.opportunisticGraftThreshold = 10.0  // High threshold to trigger
        config.opportunisticGraftPeers = 1  // Only graft 1
        let router = makeRouter(configuration: config)
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Add a peer to mesh (with default score 0, below threshold 10)
        let meshPeer = makePeerID()
        router.meshState.addToMesh(meshPeer, for: topic)

        // Add multiple high-score non-mesh candidates
        for _ in 0..<5 {
            let peer = makePeerID()
            let state = PeerState(peerID: peer, version: .v11, direction: .outbound)
            router.peerState.addPeer(state, stream: GossipSubMockStream())
            router.peerState.updatePeer(peer) { s in
                s.subscriptions.insert(topic)
            }
            for _ in 0..<10 {
                router.peerScorer.recordMessageDelivery(from: peer, isFirst: true)
            }
        }

        let actions = router.opportunisticGraft()

        // Should graft at most 1 peer
        #expect(actions.count <= 1)
    }

    @Test("Configuration defaults for opportunistic grafting")
    func configurationDefaults() {
        let config = GossipSubConfiguration()
        #expect(config.opportunisticGraftTicks == 60)
        #expect(config.opportunisticGraftPeers == 2)
        #expect(config.opportunisticGraftThreshold == 1.0)
    }
}
