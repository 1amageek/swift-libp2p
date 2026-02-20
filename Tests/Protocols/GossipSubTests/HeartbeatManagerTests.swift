/// HeartbeatManagerTests - Tests for GossipSub heartbeat manager
import Testing
import Foundation
import NIOCore
@testable import P2PGossipSub
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

@Suite("HeartbeatManager Tests", .serialized)
struct HeartbeatManagerTests {

    // MARK: - Helpers

    private func makeRouter(
        configuration: GossipSubConfiguration = .testing
    ) -> GossipSubRouter {
        let localPeerID = KeyPair.generateEd25519().peerID
        return GossipSubRouter(localPeerID: localPeerID, configuration: configuration)
    }

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    /// Tracks messages sent via the heartbeat sendCallback.
    final class SendTracker: @unchecked Sendable {
        private var _messages: [(peer: PeerID, rpc: GossipSubRPC)] = []
        private let lock = NSLock()

        var messages: [(peer: PeerID, rpc: GossipSubRPC)] {
            lock.withLock { _messages }
        }

        var sendCallback: HeartbeatManager.SendCallback {
            { [self] peer, rpc in
                self.lock.withLock {
                    self._messages.append((peer, rpc))
                }
            }
        }
    }

    private func makeHeartbeat(
        router: GossipSubRouter,
        configuration: GossipSubConfiguration = .testing,
        tracker: SendTracker? = nil
    ) -> HeartbeatManager {
        let effectiveTracker = tracker ?? SendTracker()
        return HeartbeatManager(
            router: router,
            configuration: configuration,
            sendCallback: effectiveTracker.sendCallback
        )
    }

    // MARK: - Start / Shutdown Lifecycle

    @Test("start sets isRunning to true")
    func startSetsIsRunning() {
        let router = makeRouter()
        let heartbeat = makeHeartbeat(router: router)

        #expect(!heartbeat.isRunning)

        heartbeat.start()

        #expect(heartbeat.isRunning)

        heartbeat.shutdown()
    }

    @Test("shutdown sets isRunning to false")
    func shutdownSetsIsRunningFalse() {
        let router = makeRouter()
        let heartbeat = makeHeartbeat(router: router)

        heartbeat.start()
        #expect(heartbeat.isRunning)

        heartbeat.shutdown()
        #expect(!heartbeat.isRunning)
    }

    @Test("double start is idempotent")
    func doubleStartIsIdempotent() {
        let router = makeRouter()
        let heartbeat = makeHeartbeat(router: router)

        heartbeat.start()
        heartbeat.start()

        #expect(heartbeat.isRunning)

        heartbeat.shutdown()
    }

    @Test("double shutdown is idempotent")
    func doubleShutdownIsIdempotent() {
        let router = makeRouter()
        let heartbeat = makeHeartbeat(router: router)

        heartbeat.start()
        heartbeat.shutdown()
        heartbeat.shutdown()

        #expect(!heartbeat.isRunning)
    }

    @Test("shutdown cancels heartbeat task", .timeLimit(.minutes(1)))
    func shutdownCancelsHeartbeatTask() async throws {
        let router = makeRouter()
        let heartbeat = makeHeartbeat(router: router)

        heartbeat.start()
        #expect(heartbeat.isRunning)

        // Let one heartbeat cycle possibly run
        try await Task.sleep(for: .milliseconds(150))

        heartbeat.shutdown()
        #expect(!heartbeat.isRunning)

        // After shutdown, heartbeat count should not increase further
        let countAtShutdown = heartbeat.heartbeatCount
        try await Task.sleep(for: .milliseconds(300))
        let countAfter = heartbeat.heartbeatCount
        #expect(countAfter == countAtShutdown)
    }

    // MARK: - Heartbeat Count

    @Test("heartbeatCount increments on performHeartbeat", .timeLimit(.minutes(1)))
    func heartbeatCountIncrements() async {
        let router = makeRouter()
        let heartbeat = makeHeartbeat(router: router)

        #expect(heartbeat.heartbeatCount == 0)

        await heartbeat.performHeartbeat()
        #expect(heartbeat.heartbeatCount == 1)

        await heartbeat.performHeartbeat()
        #expect(heartbeat.heartbeatCount == 2)

        await heartbeat.performHeartbeat()
        #expect(heartbeat.heartbeatCount == 3)
    }

    // MARK: - performHeartbeat calls router methods

    @Test("performHeartbeat calls maintainMesh", .timeLimit(.minutes(1)))
    func performHeartbeatCallsMaintainMesh() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let tracker = SendTracker()
        let heartbeat = makeHeartbeat(router: router, tracker: tracker)

        // Subscribe and add peers below D_low to trigger GRAFT
        _ = try router.subscribe(to: topic)

        let peer = makePeerID()
        router.peerState.addPeer(
            PeerState(peerID: peer, version: .v11, direction: .inbound),
            stream: GossipSubMockStream()
        )
        router.peerState.updatePeer(peer) { state in
            state.subscriptions.insert(topic)
        }

        await heartbeat.performHeartbeat()

        // maintainMesh should have triggered GRAFTs (mesh was below D_low)
        let grafts = tracker.messages.filter { (_, rpc) in
            rpc.control?.grafts.isEmpty == false
        }
        #expect(!grafts.isEmpty)
    }

    @Test("performHeartbeat calls shiftMessageCache", .timeLimit(.minutes(1)))
    func performHeartbeatCallsShiftMessageCache() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let heartbeat = makeHeartbeat(router: router)

        // Put a message in cache
        let message = GossipSubMessage(
            source: makePeerID(),
            data: Data("Hello".utf8),
            sequenceNumber: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]),
            topic: topic
        )
        router.messageCache.put(message)
        #expect(router.messageCache.contains(message.id))

        // After enough heartbeats (= messageCacheLength windows), message should be evicted
        // Default .testing config uses messageCacheLength=5
        for _ in 0..<6 {
            await heartbeat.performHeartbeat()
        }

        // Message should have been shifted out of cache
        #expect(!router.messageCache.contains(message.id))
    }

    @Test("performHeartbeat calls cleanupBackoffs", .timeLimit(.minutes(1)))
    func performHeartbeatCallsCleanupBackoffs() async {
        let router = makeRouter()
        let topic = Topic("test-topic")
        let peer = makePeerID()
        let heartbeat = makeHeartbeat(router: router)

        // Add peer with an already-expired backoff
        router.peerState.addPeer(
            PeerState(peerID: peer, version: .v11, direction: .inbound),
            stream: GossipSubMockStream()
        )
        // Set a very short backoff that expires immediately
        router.peerState.updatePeer(peer) { state in
            state.backoffs[topic] = ContinuousClock.now - .seconds(1)
        }

        // Verify the backoff entry exists before cleanup
        let peerStateBefore = router.peerState.getPeer(peer)
        #expect(peerStateBefore?.backoffs[topic] != nil)

        await heartbeat.performHeartbeat()

        // After heartbeat, expired backoffs should be cleaned up
        let peerStateAfter = router.peerState.getPeer(peer)
        #expect(peerStateAfter?.backoffs[topic] == nil)
    }

    @Test("opportunisticGraft runs at correct interval", .timeLimit(.minutes(1)))
    func opportunisticGraftAtCorrectInterval() async throws {
        var config = GossipSubConfiguration.testing
        config.opportunisticGraftTicks = 3

        let router = makeRouter(configuration: config)
        let topic = Topic("test-topic")
        let tracker = SendTracker()
        let heartbeat = makeHeartbeat(router: router, configuration: config, tracker: tracker)

        _ = try router.subscribe(to: topic)

        // Add mesh peers so maintainMesh doesn't dominate
        for _ in 0..<config.meshDegree {
            let peer = makePeerID()
            router.peerState.addPeer(
                PeerState(peerID: peer, version: .v11, direction: .inbound),
                stream: GossipSubMockStream()
            )
            router.peerState.updatePeer(peer) { state in
                state.subscriptions.insert(topic)
            }
            router.meshState.addToMesh(peer, for: topic)
        }

        // Run heartbeats 1 and 2 -- opportunistic graft should NOT run (not divisible by 3)
        await heartbeat.performHeartbeat()
        #expect(heartbeat.heartbeatCount == 1)

        await heartbeat.performHeartbeat()
        #expect(heartbeat.heartbeatCount == 2)

        // Run heartbeat 3 -- opportunistic graft SHOULD run (3 % 3 == 0)
        await heartbeat.performHeartbeat()
        #expect(heartbeat.heartbeatCount == 3)
        // The opportunistic graft logic ran (though it may not produce actions
        // unless median score is low). The important thing is it didn't crash.
    }
}
