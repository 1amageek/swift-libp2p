/// FloodSubCompatibilityTests - Tests for FloodSub backward compatibility
///
/// FloodSub (/floodsub/1.0.0) is the predecessor of GossipSub and should be
/// supported for backward compatibility. FloodSub peers:
/// - Do not participate in mesh management
/// - Do not process control messages (GRAFT/PRUNE/IHAVE/IWANT/IDONTWANT)
/// - Receive all messages for subscribed topics (flood-based routing)
/// - Should not receive control messages from GossipSub peers

import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore

@Suite("FloodSub Compatibility Tests", .serialized)
struct FloodSubCompatibilityTests {

    // MARK: - Test Helpers

    private func makeRouter(
        peerID: PeerID? = nil,
        configuration: GossipSubConfiguration = .testing
    ) -> GossipSubRouter {
        let localPeerID = peerID ?? KeyPair.generateEd25519().peerID
        return GossipSubRouter(localPeerID: localPeerID, configuration: configuration)
    }

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    // MARK: - FloodSub Version Detection Tests

    @Test("FloodSub version is correctly parsed from protocol ID")
    func floodsubVersionParsing() {
        let version = GossipSubVersion(protocolID: "/floodsub/1.0.0")
        #expect(version == .floodsub)
    }

    @Test("FloodSub version returns correct protocol ID")
    func floodsubProtocolID() {
        let version = GossipSubVersion.floodsub
        #expect(version.protocolID == "/floodsub/1.0.0")
    }

    @Test("FloodSub version is less than GossipSub versions")
    func floodsubVersionComparison() {
        #expect(GossipSubVersion.floodsub < .v10)
        #expect(GossipSubVersion.floodsub < .v11)
        #expect(GossipSubVersion.floodsub < .v12)
    }

    // MARK: - FloodSub Peer Connection Tests

    @Test("Adding FloodSub peer sets correct version")
    func addFloodSubPeer() {
        let router = makeRouter()
        let floodsubPeer = makePeerID()

        // Add peer with FloodSub protocol ID
        let peerState = PeerState(
            peerID: floodsubPeer,
            version: .floodsub,
            direction: .inbound
        )
        router.peerState.addPeer(peerState, stream: GossipSubMockStream())

        let state = router.peerState.getPeer(floodsubPeer)
        #expect(state?.version == .floodsub)
    }

    // MARK: - FloodSub Subscription Tests

    @Test("FloodSub peer subscription is tracked")
    func floodsubPeerSubscription() async {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let floodsubPeer = makePeerID()

        // Add FloodSub peer
        let peerState = PeerState(
            peerID: floodsubPeer,
            version: .floodsub,
            direction: .inbound
        )
        router.peerState.addPeer(peerState, stream: GossipSubMockStream())

        // Simulate subscription from FloodSub peer
        var rpc = GossipSubRPC()
        rpc.subscriptions.append(.subscribe(to: topic))

        _ = await router.handleRPC(rpc, from: floodsubPeer)

        // Verify peer is subscribed
        let state = router.peerState.getPeer(floodsubPeer)
        #expect(state?.subscriptions.contains(topic) == true)
    }

    // MARK: - FloodSub Message Forwarding Tests

    @Test("Messages are forwarded to FloodSub peers for subscribed topics")
    func messageForwardingToFloodSubPeer() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let floodsubPeer = makePeerID()
        let gossipsubPeer = makePeerID()

        // Subscribe locally
        _ = try router.subscribe(to: topic)

        // Add FloodSub peer
        let floodsubState = PeerState(
            peerID: floodsubPeer,
            version: .floodsub,
            direction: .inbound
        )
        router.peerState.addPeer(floodsubState, stream: GossipSubMockStream())

        // Subscribe FloodSub peer to topic
        var subRPC = GossipSubRPC()
        subRPC.subscriptions.append(.subscribe(to: topic))
        _ = await router.handleRPC(subRPC, from: floodsubPeer)

        // Add GossipSub peer
        let gossipsubState = PeerState(
            peerID: gossipsubPeer,
            version: .v11,
            direction: .inbound
        )
        router.peerState.addPeer(gossipsubState, stream: GossipSubMockStream())
        router.peerState.updatePeer(gossipsubPeer) { state in
            state.subscriptions.insert(topic)
        }
        router.meshState.addToMesh(gossipsubPeer, for: topic)

        // Create a message from another peer
        let senderPeer = makePeerID()
        let senderState = PeerState(
            peerID: senderPeer,
            version: .v11,
            direction: .inbound
        )
        router.peerState.addPeer(senderState, stream: GossipSubMockStream())
        router.meshState.addToMesh(senderPeer, for: topic)

        let message = GossipSubMessage(
            source: senderPeer,
            data: Data("test".utf8),
            sequenceNumber: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            topic: topic
        )

        var rpc = GossipSubRPC()
        rpc.messages.append(message)
        let result = await router.handleRPC(rpc, from: senderPeer)

        // Verify message is forwarded to FloodSub peer
        let forwardedToFloodSub = result.forwardMessages.contains { $0.peer == floodsubPeer }
        #expect(forwardedToFloodSub == true, "Message should be forwarded to FloodSub peer")

        // Verify message is forwarded to GossipSub mesh peer
        let forwardedToGossipSub = result.forwardMessages.contains { $0.peer == gossipsubPeer }
        #expect(forwardedToGossipSub == true, "Message should be forwarded to GossipSub mesh peer")
    }

    @Test("Messages are not forwarded to FloodSub peers for unsubscribed topics")
    func noForwardingToUnsubscribedFloodSubPeer() async throws {
        let router = makeRouter()
        let topic1 = Topic("topic-1")
        let topic2 = Topic("topic-2")
        let floodsubPeer = makePeerID()

        // Subscribe locally to topic1
        _ = try router.subscribe(to: topic1)

        // Add FloodSub peer subscribed to topic2 only
        let floodsubState = PeerState(
            peerID: floodsubPeer,
            version: .floodsub,
            direction: .inbound
        )
        router.peerState.addPeer(floodsubState, stream: GossipSubMockStream())
        var subRPC = GossipSubRPC()
        subRPC.subscriptions.append(.subscribe(to: topic2))
        _ = await router.handleRPC(subRPC, from: floodsubPeer)

        // Create a message to topic1
        let senderPeer = makePeerID()
        let senderState = PeerState(
            peerID: senderPeer,
            version: .v11,
            direction: .inbound
        )
        router.peerState.addPeer(senderState, stream: GossipSubMockStream())

        let message = GossipSubMessage(
            source: senderPeer,
            data: Data("test".utf8),
            sequenceNumber: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            topic: topic1
        )

        var rpc = GossipSubRPC()
        rpc.messages.append(message)
        let result = await router.handleRPC(rpc, from: senderPeer)

        // Verify message is NOT forwarded to FloodSub peer (wrong topic)
        let forwardedToFloodSub = result.forwardMessages.contains { $0.peer == floodsubPeer }
        #expect(forwardedToFloodSub == false, "Message should not be forwarded to FloodSub peer subscribed to different topic")
    }

    // MARK: - FloodSub Control Message Tests

    @Test("FloodSub peers do not receive control messages")
    func noControlMessagesToFloodSubPeer() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let floodsubPeer = makePeerID()

        // Subscribe locally
        _ = try router.subscribe(to: topic)

        // Add FloodSub peer
        let floodsubState = PeerState(
            peerID: floodsubPeer,
            version: .floodsub,
            direction: .inbound
        )
        router.peerState.addPeer(floodsubState, stream: GossipSubMockStream())
        var subRPC = GossipSubRPC()
        subRPC.subscriptions.append(.subscribe(to: topic))
        _ = await router.handleRPC(subRPC, from: floodsubPeer)

        // FloodSub peer should not be in mesh
        let meshPeers = router.meshState.meshPeers(for: topic)
        #expect(!meshPeers.contains(floodsubPeer), "FloodSub peer should not be in mesh")
    }

    @Test("FloodSub peers ignore incoming control messages")
    func floodsubPeerIgnoresControlMessages() async {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let floodsubPeer = makePeerID()

        // Add FloodSub peer
        let floodsubState = PeerState(
            peerID: floodsubPeer,
            version: .floodsub,
            direction: .inbound
        )
        router.peerState.addPeer(floodsubState, stream: GossipSubMockStream())

        // Send RPC with control messages from FloodSub peer
        var control = ControlMessageBatch()
        control.grafts = [ControlMessage.Graft(topic: topic)]
        control.prunes = [ControlMessage.Prune(topic: topic, peers: [], backoff: nil)]
        control.ihaves = [ControlMessage.IHave(topic: topic, messageIDs: [])]
        control.iwants = [ControlMessage.IWant(messageIDs: [])]

        var rpc = GossipSubRPC()
        rpc.control = control

        let result = await router.handleRPC(rpc, from: floodsubPeer)

        // Response should not contain control messages for FloodSub peer
        #expect(result.response?.control == nil, "Should not send control response to FloodSub peer")
    }

    // MARK: - FloodSub Mesh Management Tests

    @Test("FloodSub peers are never added to mesh")
    func floodsubPeerNeverInMesh() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let floodsubPeer = makePeerID()

        // Subscribe locally
        _ = try router.subscribe(to: topic)

        // Add FloodSub peer subscribed to topic
        let floodsubState = PeerState(
            peerID: floodsubPeer,
            version: .floodsub,
            direction: .inbound
        )
        router.peerState.addPeer(floodsubState, stream: GossipSubMockStream())
        var subRPC = GossipSubRPC()
        subRPC.subscriptions.append(.subscribe(to: topic))
        _ = await router.handleRPC(subRPC, from: floodsubPeer)

        // FloodSub peer should never be in mesh
        let meshPeers = router.meshState.meshPeers(for: topic)
        #expect(!meshPeers.contains(floodsubPeer), "FloodSub peer should never be added to mesh")
    }

    @Test("FloodSub and GossipSub peers coexist")
    func mixedFloodSubAndGossipSubPeers() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        // Subscribe locally
        _ = try router.subscribe(to: topic)

        // Add multiple FloodSub peers
        var floodsubPeers: [PeerID] = []
        for _ in 0..<3 {
            let peer = makePeerID()
            let state = PeerState(
                peerID: peer,
                version: .floodsub,
                direction: .inbound
            )
            router.peerState.addPeer(state, stream: GossipSubMockStream())
            var subRPC = GossipSubRPC()
            subRPC.subscriptions.append(.subscribe(to: topic))
            _ = await router.handleRPC(subRPC, from: peer)
            floodsubPeers.append(peer)
        }

        // Add multiple GossipSub peers
        var gossipsubPeers: [PeerID] = []
        for _ in 0..<3 {
            let peer = makePeerID()
            let state = PeerState(
                peerID: peer,
                version: .v11,
                direction: .inbound
            )
            router.peerState.addPeer(state, stream: GossipSubMockStream())
            router.peerState.updatePeer(peer) { s in
                s.subscriptions.insert(topic)
            }
            gossipsubPeers.append(peer)
        }

        let meshPeers = router.meshState.meshPeers(for: topic)

        // Verify only GossipSub peers are in mesh
        for floodsubPeer in floodsubPeers {
            #expect(!meshPeers.contains(floodsubPeer), "FloodSub peer should not be in mesh")
        }
    }
}
