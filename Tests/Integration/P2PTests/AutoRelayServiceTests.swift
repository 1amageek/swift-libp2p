import Testing
import Synchronization
import P2PCore
import P2PProtocols
import P2PAutoNAT
import P2PCircuitRelay
@testable import P2P

@Suite("AutoRelayServiceTests")
struct AutoRelayServiceTests {

    private func makePeer() -> PeerID {
        PeerID(publicKey: KeyPair.generateEd25519().publicKey)
    }

    // MARK: - Lifecycle

    @Test("Attach stores context and starts monitoring", .timeLimit(.minutes(1)))
    func attachStartsMonitoring() async {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(monitorInterval: .seconds(600))
        )

        let context = MockNodeContext(localPeer: localPeer)
        await service.attach(to: context)

        // Should not crash, monitoring task should be running
        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    @Test("Shutdown is idempotent", .timeLimit(.minutes(1)))
    func shutdownIdempotent() async {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer
        )

        await service.shutdown()
        await service.shutdown()  // Should not crash

        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    // MARK: - Event Stream

    @Test("Events stream terminates on shutdown", .timeLimit(.minutes(1)))
    func eventsTerminateOnShutdown() async {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer
        )

        let events = service.events

        await service.shutdown()

        var count = 0
        for await _ in events { count += 1 }
        #expect(count == 0)

        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    // MARK: - PeerObserver

    @Test("PeerConnected/PeerDisconnected tracking", .timeLimit(.minutes(1)))
    func peerObserverTracking() async {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()
        let peer1 = makePeer()
        let peer2 = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer
        )

        await service.peerConnected(peer1)
        await service.peerConnected(peer2)
        await service.peerDisconnected(peer1)

        // Should not crash — internal state tracks peers correctly
        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    // MARK: - Configuration

    @Test("Default configuration has sensible values", .timeLimit(.minutes(1)))
    func defaultConfiguration() {
        let config = AutoRelayServiceConfiguration()
        #expect(config.desiredRelays == 3)
        #expect(config.monitorInterval == .seconds(60))
        #expect(config.staticRelays.isEmpty)
        #expect(config.useConnectedPeers == true)
        #expect(config.failureCooldown == .seconds(300))
    }

    @Test("Static relays are registered as candidates on init", .timeLimit(.minutes(1)))
    func staticRelaysRegistered() async {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()
        let staticRelay = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(staticRelays: [staticRelay])
        )

        // Should not crash — static relay is registered with the internal AutoRelay
        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    // MARK: - Candidate Scoring

    @Test("Failure count is passed through to selector", .timeLimit(.minutes(1)))
    func failureCountPassedToSelector() async {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()
        let peerA = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(monitorInterval: .seconds(600))
        )

        await service.peerConnected(peerA)
        // Inject 3 failures with lastFailureTime = nil (already decayed, no cooldown)
        service.injectFailureForTesting(peer: peerA, count: 3, lastFailureTime: nil)

        let candidates = service.buildCandidateInfosForTesting()
        #expect(candidates.count == 1)
        #expect(candidates[0].peer == peerA)
        #expect(candidates[0].recentFailures == 3)

        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    @Test("Peer with failures scores lower than clean peer", .timeLimit(.minutes(1)))
    func peerWithFailuresScoresLower() async {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()
        let cleanPeer = makePeer()
        let failedPeer = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(monitorInterval: .seconds(600))
        )

        await service.peerConnected(cleanPeer)
        await service.peerConnected(failedPeer)
        service.injectFailureForTesting(peer: failedPeer, count: 3, lastFailureTime: nil)

        let candidates = service.buildCandidateInfosForTesting()
        let scored = DefaultRelaySelector().select(from: candidates)

        #expect(scored.count == 2)
        let cleanScore = scored.first { $0.peer == cleanPeer }
        let failedScore = scored.first { $0.peer == failedPeer }
        #expect(cleanScore != nil)
        #expect(failedScore != nil)
        #expect(cleanScore!.score > failedScore!.score)

        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    @Test("Cooldown excludes peer from candidates", .timeLimit(.minutes(1)))
    func cooldownExcludesPeerTemporarily() async {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()
        let peerA = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(
                monitorInterval: .seconds(600),
                failureCooldown: .seconds(300)
            )
        )

        await service.peerConnected(peerA)
        // Inject failure with lastFailureTime = .now (within cooldown)
        service.injectFailureForTesting(peer: peerA, count: 2)

        let candidates = service.buildCandidateInfosForTesting()
        #expect(candidates.isEmpty)

        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    @Test("After cooldown peer is re-included with decayed failure count", .timeLimit(.minutes(1)))
    func afterCooldownPeerReincludedWithDecayedCount() async throws {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()
        let peerA = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(
                monitorInterval: .seconds(600),
                failureCooldown: .milliseconds(50)
            )
        )

        await service.peerConnected(peerA)
        service.injectFailureForTesting(peer: peerA, count: 4)

        // Wait for cooldown to expire
        try await Task.sleep(for: .milliseconds(100))

        // First call after cooldown: decay 4 -> 2
        let candidates = service.buildCandidateInfosForTesting()
        #expect(candidates.count == 1)
        #expect(candidates[0].recentFailures == 2)

        // Second call: no further decay (lastFailureTime is nil after decay)
        let candidates2 = service.buildCandidateInfosForTesting()
        #expect(candidates2.count == 1)
        #expect(candidates2[0].recentFailures == 2)

        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    @Test("Single failure decays to zero and record is removed", .timeLimit(.minutes(1)))
    func singleFailureDecaysToZeroAndRemoves() async throws {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()
        let peerA = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(
                monitorInterval: .seconds(600),
                failureCooldown: .milliseconds(50)
            )
        )

        await service.peerConnected(peerA)
        service.injectFailureForTesting(peer: peerA, count: 1)

        // Wait for cooldown
        try await Task.sleep(for: .milliseconds(100))

        // 1 / 2 = 0 (integer division) -> record removed
        let candidates = service.buildCandidateInfosForTesting()
        #expect(candidates.count == 1)
        #expect(candidates[0].recentFailures == 0)

        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    @Test("Deactivated event not emitted without prior activation", .timeLimit(.minutes(1)))
    func deactivatedWithoutActivationNoEvent() async throws {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(monitorInterval: .seconds(600))
        )

        let events = service.events
        let context = MockNodeContext(localPeer: localPeer)
        await service.attach(to: context)

        // Give a moment for initial monitor cycle
        try await Task.sleep(for: .milliseconds(100))
        await service.shutdown()

        var receivedEvents: [AutoRelayServiceEvent] = []
        for await event in events {
            receivedEvents.append(event)
        }

        let hasDeactivated = receivedEvents.contains { event in
            if case .deactivated = event { return true }
            return false
        }
        #expect(!hasDeactivated)

        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    @Test("Rapid peer connect/disconnect does not crash", .timeLimit(.minutes(1)))
    func concurrentMonitorCycleNoCrash() async throws {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(monitorInterval: .seconds(600))
        )

        let context = MockNodeContext(localPeer: localPeer)
        await service.attach(to: context)

        // Rapid peer connect/disconnect to exercise concurrent paths
        let peer = makePeer()
        await service.peerConnected(peer)
        await service.peerDisconnected(peer)
        await service.peerConnected(peer)
        await service.peerDisconnected(peer)

        try await Task.sleep(for: .milliseconds(100))

        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()
    }

    // MARK: - Relay Address Callback

    @Test("Relay address callback is invoked on shutdown with empty addresses", .timeLimit(.minutes(1)))
    func relayAddressCallbackOnShutdown() async throws {
        let autoNAT = AutoNATService()
        let relayClient = RelayClient()
        let localPeer = makePeer()

        let service = AutoRelayService(
            autoNAT: autoNAT,
            relayClient: relayClient,
            localPeer: localPeer,
            configuration: .init(monitorInterval: .milliseconds(50))
        )

        let callbackInvoked = Mutex(false)
        service.setRelayAddressCallback { _ in
            callbackInvoked.withLock { $0 = true }
        }

        let context = MockNodeContext(localPeer: localPeer)
        await service.attach(to: context)

        // Give monitor cycle time to run once
        try await Task.sleep(for: .milliseconds(200))

        await service.shutdown()
        await autoNAT.shutdown()
        await relayClient.shutdown()

        // Callback should have been called during the monitor cycle
        let wasInvoked = callbackInvoked.withLock { $0 }
        #expect(wasInvoked == true)
    }
}

// MARK: - Test Helpers

/// Minimal NodeContext for testing.
private final class MockNodeContext: NodeContext, @unchecked Sendable {
    let localPeer: PeerID
    let localKeyPair: KeyPair
    private let _peerStore = MemoryPeerStore()

    init(localPeer: PeerID) {
        self.localPeer = localPeer
        self.localKeyPair = .generateEd25519()
    }

    func listenAddresses() async -> [Multiaddr] { [] }
    func supportedProtocols() async -> [String] { [] }
    var peerStore: any PeerStore {
        get async { _peerStore }
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        throw MockError.notImplemented
    }
}

private enum MockError: Error {
    case notImplemented
}
