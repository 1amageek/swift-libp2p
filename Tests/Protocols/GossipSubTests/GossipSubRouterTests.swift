/// GossipSubRouterTests - Tests for GossipSub router
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

@Suite("GossipSubRouter Tests", .serialized)
struct GossipSubRouterTests {

    // MARK: - Setup

    private func makeRouter(
        peerID: PeerID? = nil,
        configuration: GossipSubConfiguration = .testing
    ) -> GossipSubRouter {
        let localPeerID = peerID ?? KeyPair.generateEd25519().peerID
        return GossipSubRouter(localPeerID: localPeerID, configuration: configuration)
    }

    // MARK: - Subscription Tests

    @Test("Subscribe creates subscription for topic")
    func subscribeCreatesSubscription() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        let subscription = try router.subscribe(to: topic)

        #expect(subscription.topic == topic)
        #expect(router.meshState.isSubscribed(to: topic))
    }

    @Test("Subscribe to same topic twice throws error")
    func subscribeTwiceThrows() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        #expect(throws: GossipSubError.self) {
            _ = try router.subscribe(to: topic)
        }
    }

    @Test("Subscribe respects max subscriptions limit")
    func subscribeRespectsLimit() throws {
        let config = GossipSubConfiguration()
        var modifiedConfig = config
        modifiedConfig.maxSubscriptions = 2

        let router = makeRouter(configuration: modifiedConfig)

        _ = try router.subscribe(to: Topic("topic-1"))
        _ = try router.subscribe(to: Topic("topic-2"))

        #expect(throws: GossipSubError.self) {
            _ = try router.subscribe(to: Topic("topic-3"))
        }
    }

    @Test("Unsubscribe returns mesh peers")
    func unsubscribeReturnsMeshPeers() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer1 = makePeerID()
        let peer2 = makePeerID()

        _ = try router.subscribe(to: topic)
        router.meshState.addToMesh(peer1, for: topic)
        router.meshState.addToMesh(peer2, for: topic)

        let meshPeers = router.unsubscribe(from: topic)

        #expect(meshPeers.count == 2)
        #expect(meshPeers.contains(peer1))
        #expect(meshPeers.contains(peer2))
    }

    @Test("Unsubscribe from non-subscribed topic returns empty set")
    func unsubscribeNonSubscribedReturnsEmpty() {
        let router = makeRouter()
        let topic = Topic("not-subscribed")

        let meshPeers = router.unsubscribe(from: topic)

        #expect(meshPeers.isEmpty)
    }

    // MARK: - RPC Handling Tests

    @Test("Handle subscription from peer")
    func handleSubscription() async {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        // First add peer to peer state (required before handling RPC)
        router.peerState.addPeer(
            PeerState(peerID: peer, version: .v11, direction: .inbound),
            stream: GossipSubMockStream()
        )

        var rpc = GossipSubRPC()
        rpc.subscriptions.append(.subscribe(to: topic))

        _ = await router.handleRPC(rpc, from: peer)

        // Verify peer's subscription is tracked
        let subscribedPeers = router.peerState.peersSubscribedTo(topic)
        #expect(subscribedPeers.contains(peer))
    }

    @Test("Handle unsubscription removes peer from mesh")
    func handleUnsubscription() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        // Subscribe and add peer to mesh
        _ = try router.subscribe(to: topic)
        router.meshState.addToMesh(peer, for: topic)

        // Receive unsubscription
        var rpc = GossipSubRPC()
        rpc.subscriptions.append(.unsubscribe(from: topic))

        _ = await router.handleRPC(rpc, from: peer)

        #expect(!router.meshState.isInMesh(peer, for: topic))
    }

    @Test("Handle message caches and forwards")
    func handleMessageCachesAndForwards() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let sender = makePeerID()
        let meshPeer = makePeerID()

        // Subscribe and add mesh peer
        _ = try router.subscribe(to: topic)
        router.meshState.addToMesh(meshPeer, for: topic)

        // Create message
        let message = GossipSubMessage(
            source: sender,
            data: Data("Hello".utf8),
            sequenceNumber: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            topic: topic
        )

        var rpc = GossipSubRPC()
        rpc.messages.append(message)

        let result = await router.handleRPC(rpc, from: sender)

        // Message should be cached
        #expect(router.messageCache.contains(message.id))
        #expect(router.seenCache.contains(message.id))

        // Message should be forwarded to mesh peer (not sender)
        #expect(result.forwardMessages.count == 1)
        #expect(result.forwardMessages[0].peer == meshPeer)
    }

    @Test("Handle duplicate message is not forwarded")
    func handleDuplicateMessage() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let sender = makePeerID()
        let meshPeer = makePeerID()

        _ = try router.subscribe(to: topic)
        router.meshState.addToMesh(meshPeer, for: topic)

        let message = GossipSubMessage(
            source: sender,
            data: Data("Hello".utf8),
            sequenceNumber: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            topic: topic
        )

        var rpc = GossipSubRPC()
        rpc.messages.append(message)

        // First message
        let result1 = await router.handleRPC(rpc, from: sender)
        #expect(result1.forwardMessages.count == 1)

        // Duplicate message (same seqno)
        let result2 = await router.handleRPC(rpc, from: sender)
        #expect(result2.forwardMessages.isEmpty)
    }

    // MARK: - Control Message Tests

    @Test("Handle IHAVE generates IWANT for missing messages")
    func handleIHaveGeneratesIWant() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        _ = try router.subscribe(to: topic)

        // Peer sends IHAVE for messages we don't have
        let msgID1 = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let msgID2 = MessageID(bytes: Data([0x04, 0x05, 0x06]))

        var control = ControlMessageBatch()
        control.ihaves.append(ControlMessage.IHave(topic: topic, messageIDs: [msgID1, msgID2]))

        var rpc = GossipSubRPC()
        rpc.control = control

        let result = await router.handleRPC(rpc, from: peer)

        // Should respond with IWANT
        #expect(result.response?.control?.iwants.isEmpty == false)
        let iwant = result.response?.control?.iwants.first
        #expect(iwant?.messageIDs.contains(msgID1) == true)
        #expect(iwant?.messageIDs.contains(msgID2) == true)
    }

    @Test("Handle IHAVE does not request already seen messages")
    func handleIHaveDoesNotRequestSeen() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        _ = try router.subscribe(to: topic)

        // Mark a message as already seen
        let seenMsgID = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        router.seenCache.add(seenMsgID)

        let newMsgID = MessageID(bytes: Data([0x04, 0x05, 0x06]))

        var control = ControlMessageBatch()
        control.ihaves.append(ControlMessage.IHave(topic: topic, messageIDs: [seenMsgID, newMsgID]))

        var rpc = GossipSubRPC()
        rpc.control = control

        let result = await router.handleRPC(rpc, from: peer)

        // Should only request the new message
        let iwant = result.response?.control?.iwants.first
        #expect(iwant?.messageIDs.contains(newMsgID) == true)
        #expect(iwant?.messageIDs.contains(seenMsgID) == false)
    }

    @Test("Handle IWANT returns cached messages")
    func handleIWantReturnsCached() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        // Put a message in cache
        let message = GossipSubMessage(
            source: makePeerID(),
            data: Data("Hello".utf8),
            sequenceNumber: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            topic: topic
        )
        router.messageCache.put(message)

        // Peer requests the message
        var control = ControlMessageBatch()
        control.iwants.append(ControlMessage.IWant(messageIDs: [message.id]))

        var rpc = GossipSubRPC()
        rpc.control = control

        let result = await router.handleRPC(rpc, from: peer)

        // Response should contain the message
        #expect(result.response?.messages.count == 1)
        #expect(result.response?.messages.first?.id == message.id)
    }

    @Test("Handle GRAFT adds peer to mesh")
    func handleGraftAddsPeerToMesh() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        _ = try router.subscribe(to: topic)

        var control = ControlMessageBatch()
        control.grafts.append(ControlMessage.Graft(topic: topic))

        var rpc = GossipSubRPC()
        rpc.control = control

        _ = await router.handleRPC(rpc, from: peer)

        #expect(router.meshState.isInMesh(peer, for: topic))
    }

    @Test("Handle GRAFT for unsubscribed topic sends PRUNE")
    func handleGraftUnsubscribedSendsPrune() async {
        let router = makeRouter()
        let topic = Topic("not-subscribed")
        let peer = makePeerID()

        var control = ControlMessageBatch()
        control.grafts.append(ControlMessage.Graft(topic: topic))

        var rpc = GossipSubRPC()
        rpc.control = control

        let result = await router.handleRPC(rpc, from: peer)

        // Should respond with PRUNE
        #expect(result.response?.control?.prunes.isEmpty == false)
        #expect(result.response?.control?.prunes.first?.topic == topic)
    }

    @Test("Handle PRUNE removes peer from mesh")
    func handlePruneRemovesPeer() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()

        _ = try router.subscribe(to: topic)
        router.meshState.addToMesh(peer, for: topic)

        var control = ControlMessageBatch()
        control.prunes.append(ControlMessage.Prune(topic: topic))

        var rpc = GossipSubRPC()
        rpc.control = control

        _ = await router.handleRPC(rpc, from: peer)

        #expect(!router.meshState.isInMesh(peer, for: topic))
    }

    // MARK: - Publishing Tests

    @Test("Publish creates valid message")
    func publishCreatesMessage() throws {
        let localKeyPair = KeyPair.generateEd25519()
        let router = makeRouter(peerID: localKeyPair.peerID)
        let topic = Topic("test-topic")

        let message = try router.publish(Data("Hello".utf8), to: topic)

        #expect(message.topic == topic)
        #expect(message.data == Data("Hello".utf8))
        #expect(message.source == localKeyPair.peerID)
        #expect(!message.sequenceNumber.isEmpty)
    }

    @Test("Publish marks message as seen")
    func publishMarksAsSeen() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        let message = try router.publish(Data("Hello".utf8), to: topic)

        #expect(router.seenCache.contains(message.id))
    }

    @Test("Publish caches message")
    func publishCachesMessage() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        let message = try router.publish(Data("Hello".utf8), to: topic)

        #expect(router.messageCache.contains(message.id))
    }

    @Test("Peers for publish returns mesh peers when subscribed")
    func peersForPublishReturnsSubscribed() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer1 = makePeerID()
        let peer2 = makePeerID()

        _ = try router.subscribe(to: topic)
        router.meshState.addToMesh(peer1, for: topic)
        router.meshState.addToMesh(peer2, for: topic)

        let peers = router.peersForPublish(topic: topic)

        #expect(peers.count == 2)
        #expect(peers.contains(peer1))
        #expect(peers.contains(peer2))
    }

    @Test("Peers for publish returns fanout peers when not subscribed")
    func peersForPublishReturnsFanout() {
        let router = makeRouter()
        let topic = Topic("unsubscribed-topic")
        let peer = makePeerID()

        router.meshState.addToFanout(peer, for: topic)

        let peers = router.peersForPublish(topic: topic)

        #expect(peers.contains(peer))
    }

    // MARK: - Gossip Generation Tests

    @Test("Generate gossip creates IHAVE for cached messages")
    func generateGossipCreatesIHave() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let meshPeer = makePeerID()
        let gossipPeer = makePeerID()

        _ = try router.subscribe(to: topic)

        // Add mesh peer
        router.meshState.addToMesh(meshPeer, for: topic)

        // Track gossip peer as subscribed but not in mesh
        router.peerState.addPeer(
            PeerState(peerID: gossipPeer, version: .v11, direction: .inbound),
            stream: GossipSubMockStream()
        )
        router.peerState.updatePeer(gossipPeer) { state in
            state.subscriptions.insert(topic)
        }

        // Put message in cache
        let message = GossipSubMessage(
            source: makePeerID(),
            data: Data("Hello".utf8),
            sequenceNumber: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            topic: topic
        )
        router.messageCache.put(message)

        let gossip = router.generateGossip()

        // Should generate IHAVE for gossip peer (not mesh peer)
        let ihavesForGossipPeer = gossip.filter { $0.peer == gossipPeer }
        #expect(!ihavesForGossipPeer.isEmpty)
        #expect(ihavesForGossipPeer.first?.ihave.messageIDs.contains(message.id) == true)
    }

    // MARK: - Mesh Maintenance Tests

    @Test("Maintain mesh grafts peers when below low threshold")
    func maintainMeshGrafts() throws {
        var config = GossipSubConfiguration()
        config.meshDegreeLow = 3
        config.meshDegree = 6

        let router = makeRouter(configuration: config)
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Only 1 peer in mesh (below threshold of 3)
        let meshPeer = makePeerID()
        router.meshState.addToMesh(meshPeer, for: topic)

        // Add candidates
        let candidate1 = makePeerID()
        let candidate2 = makePeerID()
        for peer in [candidate1, candidate2] {
            router.peerState.addPeer(
                PeerState(peerID: peer, version: .v11, direction: .inbound),
                stream: GossipSubMockStream()
            )
            router.peerState.updatePeer(peer) { state in
                state.subscriptions.insert(topic)
            }
        }

        let toSend = router.maintainMesh()

        // Should send GRAFTs to candidates
        let grafts = toSend.filter { !$0.control.grafts.isEmpty }
        #expect(!grafts.isEmpty)
    }

    // MARK: - Shutdown Tests

    @Test("Shutdown clears all state")
    func shutdownClearsState() throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)
        router.meshState.addToMesh(makePeerID(), for: topic)
        router.messageCache.put(GossipSubMessage(
            source: makePeerID(),
            data: Data("Hello".utf8),
            sequenceNumber: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            topic: topic
        ))

        router.shutdown()

        #expect(router.meshState.subscribedTopics.isEmpty)
        #expect(router.meshState.allMeshPeers.isEmpty)
    }

    // MARK: - Helpers

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeMockStream() -> MuxedStream {
        GossipSubMockStream()
    }
}

// MARK: - Mock Stream

final class GossipSubMockStream: MuxedStream, Sendable {
    let id: UInt64
    let protocolID: String?

    init(id: UInt64 = 0, protocolID: String? = nil) {
        self.id = id
        self.protocolID = protocolID
    }

    func read() async throws -> Data {
        Data()
    }

    func write(_ data: Data) async throws {}

    func closeWrite() async throws {}

    func close() async throws {}

    func reset() async throws {}
}
