import Foundation
import Testing
@testable import P2P
@testable import P2PCore
@testable import P2PDiscovery
@testable import P2PMux
@testable import P2PMuxYamux
@testable import P2PProtocols
@testable import P2PSecurityPlaintext
@testable import P2PTransportMemory

@Suite("Discovery Integration Tests", .serialized)
struct DiscoveryIntegrationTests {
    @Test("Node start/shutdown drives discovery lifecycle hooks", .timeLimit(.minutes(1)))
    func discoveryLifecycleHooks() async throws {
        let keyPair = KeyPair.generateEd25519()
        let discovery = MockNodeIntegratedDiscovery()
        let node = Node(configuration: NodeConfiguration(
            keyPair: keyPair,
            discovery: discovery
        ))

        try await node.start()
        await node.shutdown()

        let state = await discovery.currentState()
        #expect(state.registerHandlerCalls == 1)
        #expect(state.startCalls == 1)
        #expect(state.shutdownCalls == 1)
    }

    @Test("Node propagates peer stream lifecycle to discovery service", .timeLimit(.minutes(1)))
    func discoveryPeerStreamHooks() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "discovery-server")

        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let serverDiscovery = MockNodeIntegratedDiscovery()
        let clientDiscovery = MockNodeIntegratedDiscovery()

        let pool = PoolConfiguration(
            limits: .development,
            reconnectionPolicy: .disabled,
            idleTimeout: .seconds(300)
        )

        let server = Node(configuration: NodeConfiguration(
            keyPair: serverKeyPair,
            listenAddresses: [serverAddress],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: nil,
            discovery: serverDiscovery
        ))
        let client = Node(configuration: NodeConfiguration(
            keyPair: clientKeyPair,
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: nil,
            discovery: clientDiscovery
        ))

        try await server.start()
        try await client.start()

        _ = try await client.connect(to: serverAddress)

        let serverPeerID = serverKeyPair.peerID
        let clientPeerID = clientKeyPair.peerID

        try await waitUntil(timeout: .seconds(2)) {
            let serverState = await serverDiscovery.currentState()
            let clientState = await clientDiscovery.currentState()
            return serverState.connectedPeers.contains(clientPeerID)
                && clientState.connectedPeers.contains(serverPeerID)
        }

        await client.disconnect(from: serverPeerID)
        await server.disconnect(from: clientPeerID)

        let finalServerState = await serverDiscovery.currentState()
        let finalClientState = await clientDiscovery.currentState()
        #expect(finalServerState.disconnectedPeers.contains(clientPeerID))
        #expect(finalClientState.disconnectedPeers.contains(serverPeerID))

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }
}

private actor MockNodeIntegratedDiscovery: DiscoveryService, NodeDiscoveryHandlerRegistrable, NodeDiscoveryStartable, NodeDiscoveryPeerStreamService {
    struct State: Sendable {
        var startCalls: Int
        var shutdownCalls: Int
        var registerHandlerCalls: Int
        var connectedPeers: Set<PeerID>
        var disconnectedPeers: Set<PeerID>
    }

    nonisolated let discoveryProtocolID: String = "/test/discovery-integration/1.0.0"

    private var startCalls: Int = 0
    private var shutdownCalls: Int = 0
    private var registerHandlerCalls: Int = 0
    private var connectedPeers: Set<PeerID> = []
    private var disconnectedPeers: Set<PeerID> = []
    private var peerStreams: [PeerID: MuxedStream] = [:]

    func currentState() -> State {
        State(
            startCalls: startCalls,
            shutdownCalls: shutdownCalls,
            registerHandlerCalls: registerHandlerCalls,
            connectedPeers: connectedPeers,
            disconnectedPeers: disconnectedPeers
        )
    }

    func start() async {
        startCalls += 1
    }

    func registerHandler(registry: any HandlerRegistry) async {
        registerHandlerCalls += 1
        await registry.handle(discoveryProtocolID) { [weak self] context in
            await self?.handleInboundStream(context)
        }
    }

    private func handleInboundStream(_ context: StreamContext) async {
        do {
            try await context.stream.close()
        } catch {
            // Ignore close failures in tests.
        }
    }

    func handlePeerConnected(_ peerID: PeerID, stream: MuxedStream) async {
        connectedPeers.insert(peerID)
        peerStreams[peerID] = stream
    }

    func handlePeerDisconnected(_ peerID: PeerID) async {
        disconnectedPeers.insert(peerID)
        guard let stream = peerStreams.removeValue(forKey: peerID) else {
            return
        }
        do {
            try await stream.close()
        } catch {
            // Ignore close failures in tests.
        }
    }

    func announce(addresses: [Multiaddr]) async throws {
        _ = addresses
    }

    func find(peer: PeerID) async throws -> [ScoredCandidate] {
        _ = peer
        return []
    }

    func knownPeers() async -> [PeerID] {
        []
    }

    nonisolated var observations: AsyncStream<PeerObservation> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    nonisolated func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        _ = peer
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func shutdown() async {
        shutdownCalls += 1
        let streams = Array(peerStreams.values)
        peerStreams.removeAll()
        for stream in streams {
            do {
                try await stream.close()
            } catch {
                // Ignore close failures in tests.
            }
        }
    }
}

private enum WaitTimeoutError: Error {
    case timedOut
}

private func waitUntil(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if await condition() {
            return
        }
        try await Task.sleep(for: pollInterval)
    }
    throw WaitTimeoutError.timedOut
}
