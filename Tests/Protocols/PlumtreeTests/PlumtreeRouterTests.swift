import Testing
import Foundation
import P2PCore
@testable import P2PPlumtree

@Suite("Plumtree Router Tests")
struct PlumtreeRouterTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeRouter() -> PlumtreeRouter {
        PlumtreeRouter(
            localPeerID: makePeerID(),
            configuration: .testing
        )
    }

    private func makeGossip(source: PeerID? = nil, topic: String = "test", seq: UInt64 = 0) -> PlumtreeGossip {
        let src = source ?? makePeerID()
        return PlumtreeGossip(
            messageID: PlumtreeMessageID.compute(source: src, sequenceNumber: seq),
            topic: topic,
            data: Data("hello".utf8),
            source: src,
            hopCount: 0
        )
    }

    // MARK: - Subscription Tests

    @Test("Subscribe adds connected peers to eager set")
    func subscribeAddsPeers() {
        let router = makeRouter()
        let peer1 = makePeerID()
        let peer2 = makePeerID()

        _ = router.handlePeerConnected(peer1)
        _ = router.handlePeerConnected(peer2)

        let events = router.subscribe(to: "topic")

        #expect(router.isSubscribed(to: "topic"))
        #expect(router.eagerPeers(for: "topic").count == 2)
        #expect(router.eagerPeers(for: "topic").contains(peer1))
        #expect(router.eagerPeers(for: "topic").contains(peer2))
        #expect(events.contains(where: {
            if case .peerAddedToEager(let p, let t) = $0 { return p == peer1 && t == "topic" }
            return false
        }))
    }

    @Test("Unsubscribe clears topic peer sets")
    func unsubscribeClearsSets() {
        let router = makeRouter()
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)
        _ = router.subscribe(to: "topic")

        router.unsubscribe(from: "topic")
        #expect(!router.isSubscribed(to: "topic"))
        #expect(router.eagerPeers(for: "topic").isEmpty)
    }

    @Test("Duplicate subscribe is idempotent")
    func duplicateSubscribe() {
        let router = makeRouter()
        _ = router.subscribe(to: "topic")
        let events = router.subscribe(to: "topic")
        #expect(events.isEmpty)
    }

    // MARK: - Peer Management Tests

    @Test("New peer added to eager set for subscribed topics")
    func peerConnectedAddedToEager() {
        let router = makeRouter()
        _ = router.subscribe(to: "t1")
        _ = router.subscribe(to: "t2")

        let peer = makePeerID()
        let events = router.handlePeerConnected(peer)

        #expect(router.eagerPeers(for: "t1").contains(peer))
        #expect(router.eagerPeers(for: "t2").contains(peer))
        #expect(events.contains(where: {
            if case .peerConnected(let p) = $0 { return p == peer }
            return false
        }))
    }

    @Test("Disconnected peer removed from all sets")
    func peerDisconnectedRemovedFromSets() {
        let router = makeRouter()
        _ = router.subscribe(to: "topic")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)
        #expect(router.eagerPeers(for: "topic").contains(peer))

        _ = router.handlePeerDisconnected(peer)
        #expect(!router.eagerPeers(for: "topic").contains(peer))
        #expect(!router.connectedPeers.contains(peer))
    }

    // MARK: - Gossip Handling Tests

    @Test("New gossip is delivered and forwarded")
    func newGossipDelivered() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let sender = makePeerID()
        let other = makePeerID()
        _ = router.handlePeerConnected(sender)
        _ = router.handlePeerConnected(other)

        let gossip = makeGossip(topic: "test")
        let result = router.handleGossip(gossip, from: sender)

        #expect(result.deliverToSubscribers != nil)
        #expect(result.deliverToSubscribers?.messageID == gossip.messageID)
        #expect(result.forwardTo.contains(other))
        #expect(!result.forwardTo.contains(sender))
        #expect(result.pruneSender == false)
        #expect(router.hasSeen(gossip.messageID))
    }

    @Test("Duplicate gossip triggers prune")
    func duplicateGossipTriggersPrune() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let sender1 = makePeerID()
        let sender2 = makePeerID()
        _ = router.handlePeerConnected(sender1)
        _ = router.handlePeerConnected(sender2)

        let gossip = makeGossip(topic: "test")

        // First delivery from sender1
        _ = router.handleGossip(gossip, from: sender1)

        // Duplicate from sender2
        let result = router.handleGossip(gossip, from: sender2)

        #expect(result.deliverToSubscribers == nil)
        #expect(result.pruneSender == true)
        #expect(result.forwardTo.isEmpty)
        // sender2 should now be in lazy set
        #expect(router.lazyPeers(for: "test").contains(sender2))
        #expect(!router.eagerPeers(for: "test").contains(sender2))
    }

    @Test("Gossip for unsubscribed topic is not delivered")
    func gossipUnsubscribedNotDelivered() {
        let router = makeRouter()
        let sender = makePeerID()
        _ = router.handlePeerConnected(sender)

        let gossip = makeGossip(topic: "unknown")
        let result = router.handleGossip(gossip, from: sender)

        #expect(result.deliverToSubscribers == nil)
        #expect(result.forwardTo.isEmpty)
        // Should still be marked as seen (for dedup)
        #expect(router.hasSeen(gossip.messageID))
    }

    @Test("Gossip cancels pending IHave")
    func gossipCancelsPendingIHave() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)

        let source = makePeerID()
        let msgID = PlumtreeMessageID.compute(source: source, sequenceNumber: 1)

        // Register IHave
        let ihave = PlumtreeIHaveEntry(messageID: msgID, topic: "test")
        _ = router.handleIHave([ihave], from: peer)
        #expect(router.pendingIHaveCount == 1)

        // Receive the actual gossip
        let gossip = PlumtreeGossip(
            messageID: msgID,
            topic: "test",
            data: Data("data".utf8),
            source: source,
            hopCount: 1
        )
        _ = router.handleGossip(gossip, from: makePeerID())

        // Pending IHave should be cancelled
        #expect(router.pendingIHaveCount == 0)
    }

    // MARK: - IHave Handling Tests

    @Test("IHave for unseen message starts timer")
    func ihaveUnseenStartsTimer() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)

        let ihave = PlumtreeIHaveEntry(
            messageID: PlumtreeMessageID(bytes: Data([1, 2, 3])),
            topic: "test"
        )
        let result = router.handleIHave([ihave], from: peer)

        #expect(result.startTimers.count == 1)
        #expect(result.startTimers[0].peer == peer)
        #expect(router.pendingIHaveCount == 1)
    }

    @Test("IHave for already seen message is ignored")
    func ihaveSeenIgnored() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)

        // First, receive a gossip to mark as seen
        let gossip = makeGossip(topic: "test")
        _ = router.handleGossip(gossip, from: peer)

        // IHave for the same message should be ignored
        let ihave = PlumtreeIHaveEntry(messageID: gossip.messageID, topic: "test")
        let result = router.handleIHave([ihave], from: peer)
        #expect(result.startTimers.isEmpty)
    }

    @Test("IHave for unsubscribed topic is ignored")
    func ihaveUnsubscribedIgnored() {
        let router = makeRouter()
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)

        let ihave = PlumtreeIHaveEntry(
            messageID: PlumtreeMessageID(bytes: Data([1])),
            topic: "unknown"
        )
        let result = router.handleIHave([ihave], from: peer)
        #expect(result.startTimers.isEmpty)
    }

    // MARK: - IHave Timeout Tests

    @Test("IHave timeout grafts peer")
    func ihaveTimeoutGrafts() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)

        // Move peer to lazy first
        let gossip1 = makeGossip(topic: "test", seq: 1)
        _ = router.handleGossip(gossip1, from: makePeerID())
        let dup = router.handleGossip(gossip1, from: peer)
        #expect(dup.pruneSender)
        #expect(router.lazyPeers(for: "test").contains(peer))

        // Register IHave
        let msgID = PlumtreeMessageID(bytes: Data([99]))
        let ihave = PlumtreeIHaveEntry(messageID: msgID, topic: "test")
        _ = router.handleIHave([ihave], from: peer)

        // Simulate timeout
        let result = router.handleIHaveTimeout(msgID)
        #expect(result != nil)
        #expect(result?.graftPeer == peer)
        #expect(result?.graftMessageID == msgID)
        // Peer should now be in eager set
        #expect(router.eagerPeers(for: "test").contains(peer))
        #expect(!router.lazyPeers(for: "test").contains(peer))
    }

    @Test("IHave timeout returns nil if message already received")
    func ihaveTimeoutAfterReceive() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)

        let source = makePeerID()
        let msgID = PlumtreeMessageID.compute(source: source, sequenceNumber: 1)
        let ihave = PlumtreeIHaveEntry(messageID: msgID, topic: "test")
        _ = router.handleIHave([ihave], from: peer)

        // Receive the message before timeout
        let gossip = PlumtreeGossip(
            messageID: msgID, topic: "test",
            data: Data(), source: source, hopCount: 0
        )
        _ = router.handleGossip(gossip, from: makePeerID())

        // Timeout should return nil
        let result = router.handleIHaveTimeout(msgID)
        #expect(result == nil)
    }

    // MARK: - Graft Handling Tests

    @Test("Graft moves peer to eager and re-sends message")
    func graftMovesToEager() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)

        // Publish a message so it's stored
        let source = makePeerID()
        let gossip = makeGossip(source: source, topic: "test")
        _ = router.handleGossip(gossip, from: makePeerID())

        // Move peer to lazy via duplicate
        let dup = router.handleGossip(gossip, from: peer)
        #expect(dup.pruneSender)

        // Receive GRAFT with message ID
        let graft = PlumtreeGraftRequest(topic: "test", messageID: gossip.messageID)
        let result = router.handleGraft(graft, from: peer)

        #expect(router.eagerPeers(for: "test").contains(peer))
        #expect(result.reSendMessages.count == 1)
        #expect(result.reSendMessages[0].messageID == gossip.messageID)
    }

    @Test("Graft without message ID moves peer to eager")
    func graftWithoutMessageID() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)

        let graft = PlumtreeGraftRequest(topic: "test")
        let result = router.handleGraft(graft, from: peer)

        #expect(router.eagerPeers(for: "test").contains(peer))
        #expect(result.reSendMessages.isEmpty)
    }

    // MARK: - Prune Handling Tests

    @Test("Prune moves peer to lazy")
    func pruneMovesToLazy() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let peer = makePeerID()
        _ = router.handlePeerConnected(peer)
        #expect(router.eagerPeers(for: "test").contains(peer))

        let prune = PlumtreePruneRequest(topic: "test")
        let result = router.handlePrune(prune, from: peer)

        #expect(!router.eagerPeers(for: "test").contains(peer))
        #expect(router.lazyPeers(for: "test").contains(peer))
        #expect(result.events.contains(where: {
            if case .pruneReceived(let p, let t) = $0 { return p == peer && t == "test" }
            return false
        }))
    }

    // MARK: - Publishing Tests

    @Test("RegisterPublished stores message and returns peer sets")
    func registerPublished() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        let eager1 = makePeerID()
        let eager2 = makePeerID()
        _ = router.handlePeerConnected(eager1)
        _ = router.handlePeerConnected(eager2)

        // Move eager2 to lazy
        let gossip1 = makeGossip(topic: "test", seq: 1)
        _ = router.handleGossip(gossip1, from: makePeerID())
        _ = router.handleGossip(gossip1, from: eager2)

        let published = PlumtreeGossip(
            messageID: PlumtreeMessageID.compute(source: makePeerID(), sequenceNumber: 100),
            topic: "test",
            data: Data("pub".utf8),
            source: makePeerID(),
            hopCount: 0
        )

        let (eagerPeers, lazyPeers) = router.registerPublished(published)

        #expect(router.hasSeen(published.messageID))
        #expect(router.storedMessageCount > 0)
        #expect(eagerPeers.contains(eager1))
        #expect(lazyPeers.contains(eager2))
    }

    // MARK: - Cleanup Tests

    @Test("Shutdown clears all state")
    func shutdownClearsState() {
        let router = makeRouter()
        _ = router.subscribe(to: "test")
        _ = router.handlePeerConnected(makePeerID())
        let gossip = makeGossip(topic: "test")
        _ = router.handleGossip(gossip, from: makePeerID())

        router.shutdown()

        #expect(router.connectedPeers.isEmpty)
        #expect(router.subscribedTopics.isEmpty)
        #expect(router.seenMessageCount == 0)
        #expect(router.storedMessageCount == 0)
    }
}
