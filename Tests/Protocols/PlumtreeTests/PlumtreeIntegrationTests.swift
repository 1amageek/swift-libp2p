import Testing
import Foundation
@testable import P2PPlumtree
import P2PCore

@Suite("Plumtree Integration Tests", .serialized)
struct PlumtreeIntegrationTests {

    private func makePeer() -> PeerID {
        PeerID(publicKey: KeyPair.generateEd25519().publicKey)
    }

    private func makeRouter() -> PlumtreeRouter {
        PlumtreeRouter(
            localPeerID: makePeer(),
            configuration: .testing
        )
    }

    private func makeMessageID(source: PeerID, seq: UInt64 = 1) -> PlumtreeMessageID {
        PlumtreeMessageID.compute(source: source, sequenceNumber: seq)
    }

    private func makeGossip(source: PeerID, topic: String, seq: UInt64 = 1, data: Data = Data([0x01])) -> PlumtreeGossip {
        PlumtreeGossip(
            messageID: makeMessageID(source: source, seq: seq),
            topic: topic,
            data: data,
            source: source,
            hopCount: 0
        )
    }

    // MARK: - Full Tree Operation Scenarios

    @Test("Tree formation: subscribe adds connected peers as eager")
    func treeFormation() {
        let router = makeRouter()
        let peerA = makePeer()
        let peerB = makePeer()
        let peerC = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.handlePeerConnected(peerB)
        _ = router.handlePeerConnected(peerC)

        _ = router.subscribe(to: "topic1")

        let eager = router.eagerPeers(for: "topic1")
        #expect(eager.contains(peerA))
        #expect(eager.contains(peerB))
        #expect(eager.contains(peerC))
        #expect(router.lazyPeers(for: "topic1").isEmpty)
    }

    @Test("Duplicate gossip moves sender to lazy and triggers prune")
    func duplicateMovesToLazy() {
        let router = makeRouter()
        let source = makePeer()
        let peerA = makePeer()
        let peerB = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.handlePeerConnected(peerB)
        _ = router.subscribe(to: "t1")

        let gossip = makeGossip(source: source, topic: "t1")

        // First delivery from peerA - new message
        let result1 = router.handleGossip(gossip, from: peerA)
        #expect(result1.deliverToSubscribers != nil)

        // Duplicate from peerB - should trigger prune
        let result2 = router.handleGossip(gossip, from: peerB)
        #expect(result2.deliverToSubscribers == nil)
        #expect(result2.pruneSender)

        // peerB should now be in lazy set
        #expect(router.lazyPeers(for: "t1").contains(peerB))
        #expect(!router.eagerPeers(for: "t1").contains(peerB))
    }

    @Test("IHave timeout triggers graft to recover from lazy peer")
    func ihaveTimeoutGraft() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")

        // Receive a gossip from another peer first to mark it as seen
        let gossip1 = makeGossip(source: source, topic: "t1", seq: 1)
        _ = router.handleGossip(gossip1, from: makePeer())

        // Duplicate from peerA moves them to lazy
        _ = router.handleGossip(gossip1, from: peerA)
        #expect(router.lazyPeers(for: "t1").contains(peerA))

        // peerA sends IHave for a new message we haven't seen
        let newMsgID = makeMessageID(source: source, seq: 99)
        let ihaveEntries = [PlumtreeIHaveEntry(messageID: newMsgID, topic: "t1")]
        let ihaveResult = router.handleIHave(ihaveEntries, from: peerA)
        #expect(!ihaveResult.startTimers.isEmpty)

        // Timeout fires - should graft peerA back to eager
        let timeoutResult = router.handleIHaveTimeout(newMsgID)
        #expect(timeoutResult != nil)
        #expect(timeoutResult?.graftPeer == peerA)
        #expect(router.eagerPeers(for: "t1").contains(peerA))
    }

    @Test("Graft re-sends stored message to requesting peer")
    func graftResend() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")

        // Receive a gossip (stored in message store)
        let gossip = makeGossip(source: source, topic: "t1")
        _ = router.handleGossip(gossip, from: makePeer())

        // peerA sends GRAFT requesting this specific message
        let graftReq = PlumtreeGraftRequest(topic: "t1", messageID: gossip.messageID)
        let graftResult = router.handleGraft(graftReq, from: peerA)

        // Should return the stored message for re-sending
        #expect(graftResult.reSendMessages.count == 1)
        #expect(graftResult.reSendMessages[0].messageID == gossip.messageID)

        // peerA should be in eager set
        #expect(router.eagerPeers(for: "t1").contains(peerA))
    }

    @Test("Prune moves peer to lazy set")
    func pruneToLazy() {
        let router = makeRouter()
        let peerA = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")

        #expect(router.eagerPeers(for: "t1").contains(peerA))

        let pruneReq = PlumtreePruneRequest(topic: "t1")
        _ = router.handlePrune(pruneReq, from: peerA)

        #expect(!router.eagerPeers(for: "t1").contains(peerA))
        #expect(router.lazyPeers(for: "t1").contains(peerA))
    }

    // MARK: - Peer Lifecycle

    @Test("Peer disconnect removes from all topic sets")
    func peerDisconnect() {
        let router = makeRouter()
        let peerA = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")
        _ = router.subscribe(to: "t2")

        #expect(router.eagerPeers(for: "t1").contains(peerA))
        #expect(router.eagerPeers(for: "t2").contains(peerA))

        _ = router.handlePeerDisconnected(peerA)

        #expect(!router.eagerPeers(for: "t1").contains(peerA))
        #expect(!router.eagerPeers(for: "t2").contains(peerA))
        #expect(!router.lazyPeers(for: "t1").contains(peerA))
        #expect(!router.lazyPeers(for: "t2").contains(peerA))
    }

    @Test("New peer connected after subscribe gets added to eager")
    func lateJoinPeer() {
        let router = makeRouter()
        let peerA = makePeer()

        _ = router.subscribe(to: "t1")
        #expect(router.eagerPeers(for: "t1").isEmpty)

        _ = router.handlePeerConnected(peerA)
        // After connect, peer should be added to topics we're subscribed to
        #expect(router.eagerPeers(for: "t1").contains(peerA))
    }

    // MARK: - Multi-Topic Scenarios

    @Test("Messages in different topics are independent")
    func multiTopicIndependence() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")
        _ = router.subscribe(to: "t2")

        let gossip1 = makeGossip(source: source, topic: "t1", seq: 1)
        let gossip2 = makeGossip(source: source, topic: "t2", seq: 2)

        let r1 = router.handleGossip(gossip1, from: peerA)
        let r2 = router.handleGossip(gossip2, from: peerA)

        #expect(r1.deliverToSubscribers != nil)
        #expect(r2.deliverToSubscribers != nil)
        #expect(router.seenMessageCount >= 2)
    }

    @Test("Unsubscribe clears topic state but preserves others")
    func unsubscribePreservesOthers() {
        let router = makeRouter()
        let peerA = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")
        _ = router.subscribe(to: "t2")

        router.unsubscribe(from: "t1")

        #expect(router.eagerPeers(for: "t1").isEmpty)
        #expect(router.eagerPeers(for: "t2").contains(peerA))
    }

    // MARK: - Message Deduplication

    @Test("Seen messages from different peers are still deduplicated")
    func deduplicationAcrossPeers() {
        let router = makeRouter()
        let peerA = makePeer()
        let peerB = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.handlePeerConnected(peerB)
        _ = router.subscribe(to: "t1")

        let gossip = makeGossip(source: source, topic: "t1")

        let r1 = router.handleGossip(gossip, from: peerA)
        let r2 = router.handleGossip(gossip, from: peerB)

        #expect(r1.deliverToSubscribers != nil)
        #expect(r2.deliverToSubscribers == nil)
    }

    @Test("IHave for already-seen message is ignored")
    func ihaveSeenIgnored() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")

        let gossip = makeGossip(source: source, topic: "t1")
        _ = router.handleGossip(gossip, from: peerA)

        // IHave for already-seen message
        let ihaveEntries = [PlumtreeIHaveEntry(messageID: gossip.messageID, topic: "t1")]
        let result = router.handleIHave(ihaveEntries, from: peerA)
        #expect(result.startTimers.isEmpty)
    }

    // MARK: - Cleanup and Shutdown

    @Test("Cleanup does not crash with messages present")
    func cleanupDoesNotCrash() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")

        // Add many messages
        for i: UInt64 in 0..<5 {
            let gossip = makeGossip(source: source, topic: "t1", seq: i)
            _ = router.handleGossip(gossip, from: peerA)
        }

        #expect(router.seenMessageCount >= 5)
        #expect(router.storedMessageCount >= 0)

        // Cleanup should not fail
        router.cleanup()
    }

    @Test("Shutdown clears all state")
    func shutdownClearsAll() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")
        _ = router.handleGossip(makeGossip(source: source, topic: "t1"), from: peerA)

        router.shutdown()

        #expect(router.eagerPeers(for: "t1").isEmpty)
        #expect(router.lazyPeers(for: "t1").isEmpty)
        #expect(router.seenMessageCount == 0)
        #expect(router.storedMessageCount == 0)
        #expect(router.pendingIHaveCount == 0)
    }

    // MARK: - Gossip forwarding

    @Test("New gossip is forwarded to all eager peers except sender")
    func gossipForwardedExceptSender() {
        let router = makeRouter()
        let peerA = makePeer()
        let peerB = makePeer()
        let peerC = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.handlePeerConnected(peerB)
        _ = router.handlePeerConnected(peerC)
        _ = router.subscribe(to: "t1")

        let gossip = makeGossip(source: source, topic: "t1")
        let result = router.handleGossip(gossip, from: peerA)

        #expect(result.deliverToSubscribers != nil)
        // Should forward to peerB and peerC but NOT peerA (the sender)
        #expect(!result.forwardTo.contains(peerA))
        #expect(result.forwardTo.contains(peerB))
        #expect(result.forwardTo.contains(peerC))
    }

    @Test("IHave for unsubscribed topic is ignored")
    func ihaveUnsubscribedIgnored() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        // NOT subscribed to "t1"

        let ihaveEntries = [PlumtreeIHaveEntry(messageID: makeMessageID(source: source), topic: "t1")]
        let result = router.handleIHave(ihaveEntries, from: peerA)
        #expect(result.startTimers.isEmpty)
    }

    @Test("Published message is stored and peers are returned")
    func publishStoresAndReturnsPeers() {
        let router = makeRouter()
        let peerA = makePeer()
        let peerB = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.handlePeerConnected(peerB)
        _ = router.subscribe(to: "t1")

        // Move peerB to lazy
        let pruneReq = PlumtreePruneRequest(topic: "t1")
        _ = router.handlePrune(pruneReq, from: peerB)

        let gossip = makeGossip(source: source, topic: "t1")
        let result = router.registerPublished(gossip)

        // peerA should be in eager, peerB in lazy
        #expect(result.eagerPeers.contains(peerA))
        #expect(result.lazyPeers.contains(peerB))

        // Message should be stored
        #expect(router.hasSeen(gossip.messageID))
    }

    // MARK: - Complex Scenarios

    @Test("Full cycle: publish, gossip, duplicate, prune, IHave, graft")
    func fullProtocolCycle() {
        let router = makeRouter()
        let peerA = makePeer()
        let peerB = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.handlePeerConnected(peerB)
        _ = router.subscribe(to: "t1")

        // Both peers start as eager
        #expect(router.eagerPeers(for: "t1").count == 2)

        // 1. Receive gossip from peerA
        let gossip1 = makeGossip(source: source, topic: "t1", seq: 1)
        let r1 = router.handleGossip(gossip1, from: peerA)
        #expect(r1.deliverToSubscribers != nil)
        #expect(r1.forwardTo.contains(peerB))

        // 2. Duplicate from peerB -> peerB gets pruned to lazy
        let r2 = router.handleGossip(gossip1, from: peerB)
        #expect(r2.pruneSender)
        #expect(router.lazyPeers(for: "t1").contains(peerB))

        // 3. peerB sends IHave for a new message
        let newMsgID = makeMessageID(source: source, seq: 42)
        let ihaveResult = router.handleIHave(
            [PlumtreeIHaveEntry(messageID: newMsgID, topic: "t1")],
            from: peerB
        )
        #expect(ihaveResult.startTimers.count == 1)

        // 4. IHave timeout fires -> graft peerB back to eager
        let timeoutResult = router.handleIHaveTimeout(newMsgID)
        #expect(timeoutResult != nil)
        #expect(timeoutResult?.graftPeer == peerB)
        #expect(router.eagerPeers(for: "t1").contains(peerB))
        #expect(!router.lazyPeers(for: "t1").contains(peerB))
    }

    @Test("Gossip for unsubscribed topic is seen but not delivered")
    func gossipUnsubscribedTopicSeen() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        // NOT subscribed to "unknown"

        let gossip = makeGossip(source: source, topic: "unknown")
        let result = router.handleGossip(gossip, from: peerA)

        // Not delivered to subscribers
        #expect(result.deliverToSubscribers == nil)
        // But still marked as seen for dedup
        #expect(router.hasSeen(gossip.messageID))
    }

    @Test("Disconnect removes pending IHaves from that peer")
    func disconnectRemovesPendingIHaves() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")

        // Register an IHave from peerA
        let msgID = makeMessageID(source: source, seq: 77)
        _ = router.handleIHave(
            [PlumtreeIHaveEntry(messageID: msgID, topic: "t1")],
            from: peerA
        )
        #expect(router.pendingIHaveCount == 1)

        // Disconnect peerA - pending IHave should be cleaned up
        _ = router.handlePeerDisconnected(peerA)
        #expect(router.pendingIHaveCount == 0)
    }

    @Test("Graft without messageID only moves peer to eager")
    func graftWithoutMessageID() {
        let router = makeRouter()
        let peerA = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")

        // Move peerA to lazy
        _ = router.handlePrune(PlumtreePruneRequest(topic: "t1"), from: peerA)
        #expect(router.lazyPeers(for: "t1").contains(peerA))

        // Graft without specific message
        let graftReq = PlumtreeGraftRequest(topic: "t1")
        let result = router.handleGraft(graftReq, from: peerA)

        #expect(result.reSendMessages.isEmpty)
        #expect(router.eagerPeers(for: "t1").contains(peerA))
        #expect(!router.lazyPeers(for: "t1").contains(peerA))
    }

    @Test("Multiple IHave entries processed in single call")
    func multipleIHaveEntries() {
        let router = makeRouter()
        let peerA = makePeer()
        let source = makePeer()

        _ = router.handlePeerConnected(peerA)
        _ = router.subscribe(to: "t1")

        let entries = (1...3).map { seq in
            PlumtreeIHaveEntry(
                messageID: makeMessageID(source: source, seq: UInt64(seq)),
                topic: "t1"
            )
        }

        let result = router.handleIHave(entries, from: peerA)
        #expect(result.startTimers.count == 3)
        #expect(router.pendingIHaveCount == 3)
    }
}
