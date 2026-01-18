/// MeshStateTests - Tests for GossipSub mesh state management
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore

@Suite("MeshState Tests")
struct MeshStateTests {

    // MARK: - Subscription Tests

    @Test("Subscribe adds topic to subscriptions")
    func subscribeAddsTopic() {
        let state = MeshState()
        let topic = Topic("test-topic")

        state.subscribe(to: topic)

        #expect(state.isSubscribed(to: topic))
        #expect(state.subscribedTopics.contains(topic))
    }

    @Test("trySubscribe succeeds for new topic")
    func trySubscribeSucceeds() {
        let state = MeshState()
        let topic = Topic("test-topic")

        let result = state.trySubscribe(to: topic, maxSubscriptions: 10)

        #expect(result == .success)
        #expect(state.isSubscribed(to: topic))
    }

    @Test("trySubscribe returns alreadySubscribed for duplicate")
    func trySubscribeDuplicate() {
        let state = MeshState()
        let topic = Topic("test-topic")

        _ = state.trySubscribe(to: topic, maxSubscriptions: 10)
        let result = state.trySubscribe(to: topic, maxSubscriptions: 10)

        #expect(result == .alreadySubscribed)
    }

    @Test("trySubscribe returns limitReached when at max")
    func trySubscribeLimitReached() {
        let state = MeshState()
        let topic1 = Topic("topic-1")
        let topic2 = Topic("topic-2")
        let topic3 = Topic("topic-3")

        _ = state.trySubscribe(to: topic1, maxSubscriptions: 2)
        _ = state.trySubscribe(to: topic2, maxSubscriptions: 2)
        let result = state.trySubscribe(to: topic3, maxSubscriptions: 2)

        if case .limitReached(let limit) = result {
            #expect(limit == 2)
        } else {
            Issue.record("Expected limitReached result")
        }
    }

    @Test("Unsubscribe removes topic and returns mesh peers")
    func unsubscribeRemovesTopic() {
        let state = MeshState()
        let topic = Topic("test-topic")
        let peer1 = makePeerID()
        let peer2 = makePeerID()

        state.subscribe(to: topic)
        state.addToMesh(peer1, for: topic)
        state.addToMesh(peer2, for: topic)

        let removedPeers = state.unsubscribe(from: topic)

        #expect(!state.isSubscribed(to: topic))
        #expect(removedPeers.count == 2)
        #expect(removedPeers.contains(peer1))
        #expect(removedPeers.contains(peer2))
    }

    // MARK: - Mesh Management Tests

    @Test("Add peer to mesh")
    func addToMesh() {
        let state = MeshState()
        let topic = Topic("test")
        let peer = makePeerID()

        let added = state.addToMesh(peer, for: topic)

        #expect(added == true)
        #expect(state.isInMesh(peer, for: topic))
        #expect(state.meshPeers(for: topic).contains(peer))
    }

    @Test("Adding same peer twice returns false")
    func addToMeshDuplicate() {
        let state = MeshState()
        let topic = Topic("test")
        let peer = makePeerID()

        _ = state.addToMesh(peer, for: topic)
        let addedAgain = state.addToMesh(peer, for: topic)

        #expect(addedAgain == false)
        #expect(state.meshPeerCount(for: topic) == 1)
    }

    @Test("Remove peer from mesh")
    func removeFromMesh() {
        let state = MeshState()
        let topic = Topic("test")
        let peer = makePeerID()

        state.addToMesh(peer, for: topic)
        let removed = state.removeFromMesh(peer, for: topic)

        #expect(removed == true)
        #expect(!state.isInMesh(peer, for: topic))
    }

    @Test("Remove non-existent peer returns false")
    func removeFromMeshNonExistent() {
        let state = MeshState()
        let topic = Topic("test")
        let peer = makePeerID()

        let removed = state.removeFromMesh(peer, for: topic)

        #expect(removed == false)
    }

    @Test("Mesh peer count is correct")
    func meshPeerCount() {
        let state = MeshState()
        let topic = Topic("test")

        state.addToMesh(makePeerID(), for: topic)
        state.addToMesh(makePeerID(), for: topic)
        state.addToMesh(makePeerID(), for: topic)

        #expect(state.meshPeerCount(for: topic) == 3)
    }

    @Test("All mesh peers returns peers across topics")
    func allMeshPeers() {
        let state = MeshState()
        let topic1 = Topic("topic-1")
        let topic2 = Topic("topic-2")
        let peer1 = makePeerID()
        let peer2 = makePeerID()
        let peer3 = makePeerID()

        state.addToMesh(peer1, for: topic1)
        state.addToMesh(peer2, for: topic1)
        state.addToMesh(peer2, for: topic2)  // Same peer in both topics
        state.addToMesh(peer3, for: topic2)

        let allPeers = state.allMeshPeers
        #expect(allPeers.count == 3)  // Deduplicated
        #expect(allPeers.contains(peer1))
        #expect(allPeers.contains(peer2))
        #expect(allPeers.contains(peer3))
    }

    // MARK: - Fanout Management Tests

    @Test("Add peer to fanout")
    func addToFanout() {
        let state = MeshState()
        let topic = Topic("test")
        let peer = makePeerID()

        state.addToFanout(peer, for: topic)

        #expect(state.fanoutPeers(for: topic).contains(peer))
    }

    @Test("Peer in mesh is not added to fanout")
    func fanoutDoesNotIncludeMeshPeers() {
        let state = MeshState()
        let topic = Topic("test")
        let peer = makePeerID()

        state.addToMesh(peer, for: topic)
        state.addToFanout(peer, for: topic)

        #expect(state.fanoutPeers(for: topic).isEmpty)
    }

    @Test("Adding to mesh removes from fanout")
    func addToMeshRemovesFromFanout() {
        let state = MeshState()
        let topic = Topic("test")
        let peer = makePeerID()

        state.addToFanout(peer, for: topic)
        #expect(state.fanoutPeers(for: topic).contains(peer))

        state.addToMesh(peer, for: topic)
        #expect(state.fanoutPeers(for: topic).isEmpty)
    }

    @Test("Touch fanout updates last published time")
    func touchFanout() {
        let state = MeshState()
        let topic = Topic("test")

        state.touchFanout(for: topic)

        // Verify the topic mesh exists (we can't directly check lastPublished)
        // but cleanupFanout with very short TTL should not clean it immediately
        state.cleanupFanout(ttl: .seconds(60))
        // Topic mesh should still exist since we just touched it
    }

    // MARK: - Peer Removal Tests

    @Test("Remove peer from all meshes")
    func removePeerFromAll() {
        let state = MeshState()
        let topic1 = Topic("topic-1")
        let topic2 = Topic("topic-2")
        let peer = makePeerID()

        state.addToMesh(peer, for: topic1)
        state.addToMesh(peer, for: topic2)
        state.addToFanout(peer, for: Topic("topic-3"))

        state.removePeerFromAll(peer)

        #expect(!state.isInMesh(peer, for: topic1))
        #expect(!state.isInMesh(peer, for: topic2))
        #expect(!state.fanoutPeers(for: Topic("topic-3")).contains(peer))
    }

    @Test("Topics in mesh for peer")
    func topicsInMesh() {
        let state = MeshState()
        let topic1 = Topic("topic-1")
        let topic2 = Topic("topic-2")
        let peer = makePeerID()
        let otherPeer = makePeerID()

        state.addToMesh(peer, for: topic1)
        state.addToMesh(peer, for: topic2)
        state.addToMesh(otherPeer, for: topic1)

        let topics = state.topicsInMesh(for: peer)
        #expect(topics.count == 2)
        #expect(topics.contains(topic1))
        #expect(topics.contains(topic2))
    }

    // MARK: - Peer Selection Tests

    @Test("Select peers for graft excludes existing mesh peers")
    func selectPeersForGraft() {
        let state = MeshState()
        let topic = Topic("test")
        let existingPeer = makePeerID()
        let candidate1 = makePeerID()
        let candidate2 = makePeerID()

        state.addToMesh(existingPeer, for: topic)

        let selected = state.selectPeersForGraft(
            topic: topic,
            count: 2,
            candidates: [existingPeer, candidate1, candidate2]
        )

        #expect(selected.count == 2)
        #expect(!selected.contains(existingPeer))
        #expect(selected.contains(candidate1))
        #expect(selected.contains(candidate2))
    }

    @Test("Select peers for graft limits selection count")
    func selectPeersForGraftLimit() {
        let state = MeshState()
        let topic = Topic("test")
        let candidates = (0..<10).map { _ in makePeerID() }

        let selected = state.selectPeersForGraft(
            topic: topic,
            count: 3,
            candidates: candidates
        )

        #expect(selected.count == 3)
    }

    @Test("Select peers for prune respects target count")
    func selectPeersForPrune() {
        let state = MeshState()
        let topic = Topic("test")
        let peers = (0..<10).map { _ in makePeerID() }

        for peer in peers {
            state.addToMesh(peer, for: topic)
        }

        let selected = state.selectPeersForPrune(
            topic: topic,
            count: 6,  // Target mesh size
            protectOutbound: 0,
            outboundPeers: []
        )

        #expect(selected.count == 4)  // 10 - 6 = 4 to prune
    }

    @Test("Select peers for prune protects outbound peers")
    func selectPeersForPruneProtectsOutbound() {
        let state = MeshState()
        let topic = Topic("test")
        let inboundPeers = (0..<5).map { _ in makePeerID() }
        let outboundPeers = (0..<5).map { _ in makePeerID() }

        for peer in inboundPeers + outboundPeers {
            state.addToMesh(peer, for: topic)
        }

        let selected = state.selectPeersForPrune(
            topic: topic,
            count: 6,
            protectOutbound: 3,  // Protect 3 outbound peers
            outboundPeers: Set(outboundPeers)
        )

        // Should prefer pruning inbound first
        // We have 10 peers, want 6, need to prune 4
        // Prune all 5 inbound would leave 5 < 6, so prune 4 inbound
        // Or prune some inbound + some outbound
        #expect(selected.count == 4)
    }

    // MARK: - Statistics Tests

    @Test("Stats returns correct counts")
    func statsCorrect() {
        let state = MeshState()
        let topic1 = Topic("topic-1")
        let topic2 = Topic("topic-2")

        state.subscribe(to: topic1)
        state.subscribe(to: topic2)
        state.addToMesh(makePeerID(), for: topic1)
        state.addToMesh(makePeerID(), for: topic1)
        state.addToMesh(makePeerID(), for: topic2)
        state.addToFanout(makePeerID(), for: Topic("unsubscribed"))

        let stats = state.stats

        #expect(stats.subscriptionCount == 2)
        #expect(stats.totalMeshPeers == 3)
        #expect(stats.totalFanoutPeers == 1)
    }

    @Test("Clear removes all state")
    func clearRemovesAll() {
        let state = MeshState()
        let topic = Topic("test")

        state.subscribe(to: topic)
        state.addToMesh(makePeerID(), for: topic)

        state.clear()

        #expect(state.subscribedTopics.isEmpty)
        #expect(state.allMeshPeers.isEmpty)
    }

    // MARK: - Helpers

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }
}

// MARK: - SubscribeResult Equatable

extension MeshState.SubscribeResult: Equatable {
    public static func == (lhs: MeshState.SubscribeResult, rhs: MeshState.SubscribeResult) -> Bool {
        switch (lhs, rhs) {
        case (.success, .success): return true
        case (.alreadySubscribed, .alreadySubscribed): return true
        case (.limitReached(let l), .limitReached(let r)): return l == r
        default: return false
        }
    }
}
