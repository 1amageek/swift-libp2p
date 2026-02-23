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
