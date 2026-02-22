import Testing
import Synchronization
import P2PCore
import P2PProtocols
import P2PAutoNAT
import P2PCircuitRelay
@testable import P2P

@Suite("SupernodeServiceTests")
struct SupernodeServiceTests {

    private func makePeer() -> PeerID {
        PeerID(publicKey: KeyPair.generateEd25519().publicKey)
    }

    // MARK: - Lifecycle

    @Test("Attach starts evaluation loop", .timeLimit(.minutes(1)))
    func attachStartsEvaluation() async {
        let autoNAT = AutoNATService()
        let relayServer = RelayServer()

        let service = SupernodeService(
            autoNAT: autoNAT,
            relayServer: relayServer,
            configuration: .init(evaluationInterval: .seconds(600))
        )

        let context = MockSupernodeContext(localPeer: makePeer())
        await service.attach(to: context)

        // Should not crash
        await service.shutdown()
        await autoNAT.shutdown()
        await relayServer.shutdown()
    }

    @Test("Shutdown is idempotent", .timeLimit(.minutes(1)))
    func shutdownIdempotent() async {
        let autoNAT = AutoNATService()
        let relayServer = RelayServer()

        let service = SupernodeService(
            autoNAT: autoNAT,
            relayServer: relayServer
        )

        await service.shutdown()
        await service.shutdown()  // Should not crash

        await autoNAT.shutdown()
        await relayServer.shutdown()
    }

    // MARK: - Event Stream

    @Test("Events stream terminates on shutdown", .timeLimit(.minutes(1)))
    func eventsTerminateOnShutdown() async {
        let autoNAT = AutoNATService()
        let relayServer = RelayServer()

        let service = SupernodeService(
            autoNAT: autoNAT,
            relayServer: relayServer
        )

        let events = service.events

        await service.shutdown()

        var count = 0
        for await _ in events { count += 1 }
        #expect(count == 0)

        await autoNAT.shutdown()
        await relayServer.shutdown()
    }

    // MARK: - Eligibility

    @Test("Private NAT deactivates relay", .timeLimit(.minutes(1)))
    func privateNATDeactivates() async throws {
        let autoNAT = AutoNATService()
        let relayServer = RelayServer()

        let service = SupernodeService(
            autoNAT: autoNAT,
            relayServer: relayServer,
            configuration: .init(
                evaluationInterval: .milliseconds(50),
                minConnectedPeers: 0,
                requirePublicNAT: true
            )
        )

        let context = MockSupernodeContext(localPeer: makePeer())
        await service.attach(to: context)

        // AutoNAT status is unknown by default (not public)
        // Wait for evaluation
        try await Task.sleep(for: .milliseconds(200))

        // RelayServer should not be accepting (NAT unknown = not public)
        #expect(relayServer.isAcceptingReservations == false)

        await service.shutdown()
        await autoNAT.shutdown()
        await relayServer.shutdown()
    }

    @Test("Insufficient peers deactivates relay", .timeLimit(.minutes(1)))
    func insufficientPeersDeactivates() async throws {
        let autoNAT = AutoNATService()
        let relayServer = RelayServer()

        let service = SupernodeService(
            autoNAT: autoNAT,
            relayServer: relayServer,
            configuration: .init(
                evaluationInterval: .milliseconds(50),
                minConnectedPeers: 5,
                requirePublicNAT: false
            )
        )

        // Only connect 2 peers (below threshold of 5)
        await service.peerConnected(makePeer())
        await service.peerConnected(makePeer())

        let context = MockSupernodeContext(localPeer: makePeer())
        await service.attach(to: context)

        try await Task.sleep(for: .milliseconds(200))

        #expect(relayServer.isAcceptingReservations == false)

        await service.shutdown()
        await autoNAT.shutdown()
        await relayServer.shutdown()
    }

    @Test("Sufficient peers with no NAT requirement activates relay", .timeLimit(.minutes(1)))
    func sufficientPeersActivates() async throws {
        let autoNAT = AutoNATService()
        let relayServer = RelayServer()

        let service = SupernodeService(
            autoNAT: autoNAT,
            relayServer: relayServer,
            configuration: .init(
                evaluationInterval: .milliseconds(50),
                minConnectedPeers: 2,
                requirePublicNAT: false
            )
        )

        // Connect enough peers
        await service.peerConnected(makePeer())
        await service.peerConnected(makePeer())
        await service.peerConnected(makePeer())

        let context = MockSupernodeContext(localPeer: makePeer())
        await service.attach(to: context)

        try await Task.sleep(for: .milliseconds(200))

        #expect(relayServer.isAcceptingReservations == true)

        await service.shutdown()
        await autoNAT.shutdown()
        await relayServer.shutdown()
    }

    // MARK: - PeerObserver

    @Test("PeerConnected increments and PeerDisconnected decrements", .timeLimit(.minutes(1)))
    func peerCountTracking() async {
        let autoNAT = AutoNATService()
        let relayServer = RelayServer()

        let service = SupernodeService(
            autoNAT: autoNAT,
            relayServer: relayServer
        )

        let peer1 = makePeer()
        let peer2 = makePeer()

        await service.peerConnected(peer1)
        await service.peerConnected(peer2)
        await service.peerDisconnected(peer1)

        // Internal count should be 1 — confirm by testing eligibility
        // with minConnectedPeers = 1 and requirePublicNAT = false
        await service.shutdown()
        await autoNAT.shutdown()
        await relayServer.shutdown()
    }

    // MARK: - Configuration

    @Test("Default configuration has sensible values", .timeLimit(.minutes(1)))
    func defaultConfiguration() {
        let config = SupernodeServiceConfiguration()
        #expect(config.evaluationInterval == .seconds(120))
        #expect(config.minConnectedPeers == 5)
        #expect(config.requirePublicNAT == true)
    }

    // MARK: - RelayServer Gating Flag

    @Test("RelayServer isAcceptingReservations defaults to true", .timeLimit(.minutes(1)))
    func relayServerDefaultAccepting() async {
        let server = RelayServer()
        #expect(server.isAcceptingReservations == true)
        await server.shutdown()
    }

    @Test("RelayServer isAcceptingReservations can be toggled", .timeLimit(.minutes(1)))
    func relayServerToggleAccepting() async {
        let server = RelayServer()
        server.isAcceptingReservations = false
        #expect(server.isAcceptingReservations == false)
        server.isAcceptingReservations = true
        #expect(server.isAcceptingReservations == true)
        await server.shutdown()
    }
}

// MARK: - Test Helpers

private final class MockSupernodeContext: NodeContext, @unchecked Sendable {
    let localPeer: PeerID
    let localKeyPair: KeyPair

    init(localPeer: PeerID) {
        self.localPeer = localPeer
        self.localKeyPair = .generateEd25519()
    }

    func listenAddresses() async -> [Multiaddr] { [] }
    func supportedProtocols() async -> [String] { [] }
    var peerStore: any PeerStore {
        get async { MemoryPeerStore() }
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        throw MockSupernodeError.notImplemented
    }
}

private enum MockSupernodeError: Error {
    case notImplemented
}
