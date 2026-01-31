/// ExplicitPeeringTests - Tests for GossipSub v1.1 explicit/direct peering
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore
@testable import P2PMux

@Suite("Explicit Peering Tests", .serialized)
struct ExplicitPeeringTests {

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

    @Test("Direct peer is not pruned when mesh exceeds D_high")
    func directPeerNotPruned() throws {
        var config = GossipSubConfiguration.testing
        config.meshDegree = 4
        config.meshDegreeLow = 2
        config.meshDegreeHigh = 6
        let router = makeRouter(configuration: config)
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Add a direct peer and add it to mesh
        let directPeer = makePeerID()
        router.addDirectPeer(directPeer, for: topic)
        router.meshState.addToMesh(directPeer, for: topic)

        // Register the direct peer so it's known
        let directState = PeerState(peerID: directPeer, version: .v11, direction: .outbound)
        router.peerState.addPeer(directState, stream: GossipSubMockStream())
        router.peerState.updatePeer(directPeer) { s in
            s.subscriptions.insert(topic)
        }

        // Add enough peers to exceed D_high
        for _ in 0..<8 {
            let peer = makePeerID()
            let state = PeerState(peerID: peer, version: .v11, direction: .outbound)
            router.peerState.addPeer(state, stream: GossipSubMockStream())
            router.peerState.updatePeer(peer) { s in
                s.subscriptions.insert(topic)
            }
            router.meshState.addToMesh(peer, for: topic)
        }

        // Run mesh maintenance
        let actions = router.maintainMesh()

        // The direct peer should NOT be pruned
        let prunedPeers = actions.filter { $0.control.prunes.contains(where: { $0.topic == topic }) }
            .map(\.peer)
        #expect(!prunedPeers.contains(directPeer))

        // But the direct peer should still be in mesh
        #expect(router.meshState.meshPeers(for: topic).contains(directPeer))
    }

    @Test("Direct peer bypasses backoff enforcement on GRAFT")
    func directPeerBypassesBackoff() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        let directPeer = makePeerID()
        router.addDirectPeer(directPeer, for: topic)

        // Register the direct peer
        let ps = PeerState(peerID: directPeer, version: .v11, direction: .inbound)
        router.peerState.addPeer(ps, stream: GossipSubMockStream())
        router.peerState.updatePeer(directPeer) { s in
            s.subscriptions.insert(topic)
        }

        // Set backoff for the direct peer
        router.peerState.updatePeer(directPeer) { state in
            state.setBackoff(for: topic, duration: .seconds(60))
        }

        // Direct peer sends GRAFT via RPC - should be accepted despite backoff
        var control = ControlMessageBatch()
        control.grafts.append(ControlMessage.Graft(topic: topic))
        let rpc = GossipSubRPC(control: control)
        let result = await router.handleRPC(rpc, from: directPeer)

        // Should NOT get a PRUNE back (backoff bypassed)
        let responsePrunes = result.response?.control?.prunes.filter { $0.topic == topic } ?? []
        #expect(responsePrunes.isEmpty)

        // Direct peer should be in mesh
        #expect(router.meshState.meshPeers(for: topic).contains(directPeer))
    }

    @Test("Direct peer always receives published messages")
    func directPeerAlwaysReceivesMessages() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        let directPeer = makePeerID()
        router.addDirectPeer(directPeer, for: topic)

        // Register the direct peer but DON'T add to mesh
        let peerState = PeerState(peerID: directPeer, version: .v11, direction: .outbound)
        router.peerState.addPeer(peerState, stream: GossipSubMockStream())
        router.peerState.updatePeer(directPeer) { s in
            s.subscriptions.insert(topic)
        }

        // Get publish targets
        let peers = router.peersForPublish(topic: topic)

        // Direct peer should be included even though not in mesh
        #expect(peers.contains(directPeer))
    }

    @Test("Direct peer add and remove works correctly")
    func directPeerAddRemove() {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        // Add
        router.addDirectPeer(peer, for: topic)
        #expect(router.isDirectPeer(peer))
        #expect(router.directPeers(for: topic).contains(peer))

        // Remove
        router.removeDirectPeer(peer, from: topic)
        #expect(!router.isDirectPeer(peer))
        #expect(!router.directPeers(for: topic).contains(peer))
    }

    @Test("Configuration with initial direct peers")
    func configurationWithDirectPeers() {
        let peer1 = makePeerID()
        let peer2 = makePeerID()
        let topic = Topic("test-topic")

        var config = GossipSubConfiguration.testing
        config.directPeers = [topic: [peer1, peer2]]

        let router = makeRouter(configuration: config)

        #expect(router.directPeers(for: topic).count == 2)
        #expect(router.isDirectPeer(peer1))
        #expect(router.isDirectPeer(peer2))
    }

    // MARK: - Scoring Exemption Tests (F-1)

    @Test("Direct peer is exempt from scoring penalties")
    func directPeerExemptFromScoring() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        let directPeer = makePeerID()
        router.addDirectPeer(directPeer, for: topic)

        // Apply many penalties
        router.peerScorer.recordInvalidMessage(from: directPeer)
        router.peerScorer.recordDuplicateMessage(from: directPeer)
        router.peerScorer.recordGraftDuringBackoff(from: directPeer)
        router.peerScorer.recordBrokenPromise(from: directPeer)
        router.peerScorer.recordExcessiveIWant(from: directPeer)
        router.peerScorer.recordTopicMismatch(from: directPeer)
        router.peerScorer.recordInvalidMessageDelivery(from: directPeer, topic: topic)
        router.peerScorer.recordMeshFailure(peer: directPeer, topic: topic)

        // Score should remain 0 (protected)
        let score = router.peerScorer.score(for: directPeer)
        #expect(score == 0.0)

        let computedScore = router.peerScorer.computeScore(for: directPeer)
        #expect(computedScore == 0.0)
    }

    @Test("Direct peer is never graylisted")
    func directPeerNeverGraylisted() {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let directPeer = makePeerID()

        router.addDirectPeer(directPeer, for: topic)

        // Even with aggressive penalties from external applyPenalty,
        // isGraylisted should return false for protected peers
        #expect(!router.peerScorer.isGraylisted(directPeer))
    }

    @Test("Non-direct peer is subject to scoring penalties")
    func nonDirectPeerSubjectToScoring() {
        let router = makeRouter()
        let normalPeer = makePeerID()

        // Apply penalty to non-direct peer
        router.peerScorer.recordInvalidMessage(from: normalPeer)

        // Score should be negative
        let score = router.peerScorer.score(for: normalPeer)
        #expect(score < 0)
    }

    @Test("Removing direct peer from last topic removes protection")
    func removeDirectPeerRemovesProtection() {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        router.addDirectPeer(peer, for: topic)
        #expect(router.peerScorer.isProtected(peer))

        router.removeDirectPeer(peer, from: topic)
        #expect(!router.peerScorer.isProtected(peer))

        // Now penalties should apply
        router.peerScorer.recordInvalidMessage(from: peer)
        let score = router.peerScorer.score(for: peer)
        #expect(score < 0)
    }

    @Test("Multi-topic direct peer keeps protection until removed from all topics")
    func multiTopicDirectPeerProtection() {
        let router = makeRouter()
        let topic1 = Topic("topic-1")
        let topic2 = Topic("topic-2")
        let peer = makePeerID()

        router.addDirectPeer(peer, for: topic1)
        router.addDirectPeer(peer, for: topic2)
        #expect(router.peerScorer.isProtected(peer))

        // Remove from first topic - still protected via second
        router.removeDirectPeer(peer, from: topic1)
        #expect(router.peerScorer.isProtected(peer))

        // Remove from second topic - no longer protected
        router.removeDirectPeer(peer, from: topic2)
        #expect(!router.peerScorer.isProtected(peer))
    }

    @Test("Initial config direct peers are protected from start")
    func initialConfigDirectPeersProtected() {
        let peer1 = makePeerID()
        let peer2 = makePeerID()
        let topic = Topic("test-topic")

        var config = GossipSubConfiguration.testing
        config.directPeers = [topic: [peer1, peer2]]

        let router = makeRouter(configuration: config)

        #expect(router.peerScorer.isProtected(peer1))
        #expect(router.peerScorer.isProtected(peer2))

        // Penalties should be no-ops
        router.peerScorer.recordInvalidMessage(from: peer1)
        #expect(router.peerScorer.score(for: peer1) == 0.0)
    }

    @Test("Non-direct peer is still subject to backoff")
    func nonDirectPeerSubjectToBackoff() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        let normalPeer = makePeerID()

        // Register the peer
        let ps = PeerState(peerID: normalPeer, version: .v11, direction: .inbound)
        router.peerState.addPeer(ps, stream: GossipSubMockStream())
        router.peerState.updatePeer(normalPeer) { s in
            s.subscriptions.insert(topic)
        }

        // Set backoff
        router.peerState.updatePeer(normalPeer) { state in
            state.setBackoff(for: topic, duration: .seconds(60))
        }

        // Normal peer sends GRAFT via RPC - should be rejected due to backoff
        var control = ControlMessageBatch()
        control.grafts.append(ControlMessage.Graft(topic: topic))
        let rpc = GossipSubRPC(control: control)
        let result = await router.handleRPC(rpc, from: normalPeer)

        // Should get a PRUNE back
        let responsePrunes = result.response?.control?.prunes.filter { $0.topic == topic } ?? []
        #expect(!responsePrunes.isEmpty)
    }
}
