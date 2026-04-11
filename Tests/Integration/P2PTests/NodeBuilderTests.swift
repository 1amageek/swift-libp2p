import Foundation
import Synchronization
import Testing
@testable import P2P
@testable import P2PCore
@testable import P2PDiscovery
@testable import P2PDiscoveryCYCLON
@testable import P2PDiscoveryPlumtree
@testable import P2PCircuitRelay
@testable import P2PDCUtR
@testable import P2PIdentify
@testable import P2PProtocols
@testable import P2PSecurityPlaintext
@testable import P2PTransportMemory

@Suite("NodeBuilder Tests", .serialized)
struct NodeBuilderTests {
    @Test("NodeBuilder composes service and discovery DSL", .timeLimit(.minutes(1)))
    func composesServicesAndDiscovery() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder")
        let keyPair = KeyPair.generateEd25519()
        let pingService = PingService()
        let mockDiscovery = MockDiscoverySource(localPeerID: keyPair.peerID)

        let builder = NodeBuilder(
            keyPair: keyPair,
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil,
            services: {
                pingComponent(pingService)
            },
            discovery: {
                discovery(mockDiscovery) { source in
                    source.markStarted()
                }
            }
        )

        let node = builder.build()

        try await node.start()

        let protocols = await node.supportedProtocols()
        #expect(protocols.contains(ProtocolID.ping))
        #expect(mockDiscovery.state().started)

        await node.shutdown()

        #expect(mockDiscovery.state().shutdown)
        hub.reset()
    }

    @Test("Built-in service helpers derive runtime capabilities without attach", .timeLimit(.minutes(1)))
    func builtInServiceHelpersDeriveRuntimeCapabilities() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-factory-services")

        let node = NodeBuilder(
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil,
            services: {
                identifyComponent()
                relayServerComponent()
            }
        ).build()

        try await node.start()

        let protocols = await node.supportedProtocols()
        #expect(protocols.contains(ProtocolID.identify))
        #expect(protocols.contains(CircuitRelayProtocol.hopProtocolID))
        #expect((await node.listenAddresses()).contains(address))

        await node.shutdown()
        hub.reset()
    }

    @Test("ServicePipeline prefers stream-opening activation over attach plus activate", .timeLimit(.minutes(1)))
    func servicePipelinePrefersStreamOpeningActivation() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-stream-opening-activation")
        let mockService = MockStreamOpeningActivationService()

        let node = NodeBuilder(
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil,
            services: {
                service(mockService) { component in
                    component.handlesInboundStreams()
                    component.activatesWithStreamOpening()
                }
            }
        ).build()

        try await node.start()

        let state = mockService.state()
        #expect(state.activateUsingCalled)
        #expect(!state.attachCalled)
        #expect(!state.activateCalled)

        await node.shutdown()
        hub.reset()
    }

    @Test("DCUtR helper installs protocol handler through post-start runtime hooks", .timeLimit(.minutes(1)))
    func dcutrHelperInstallsProtocolHandler() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-dcutr")

        let node = NodeBuilder(
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil,
            services: {
                dcutrComponent()
            }
        ).build()

        try await node.start()

        let protocols = await node.supportedProtocols()
        #expect(protocols.contains(DCUtRProtocol.protocolID))

        await node.shutdown()
        hub.reset()
    }

    @Test("NodeBuilder accepts direct connection providers", .timeLimit(.minutes(1)))
    func acceptsDirectConnectionProviders() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-provider")
        let keyPair = KeyPair.generateEd25519()

        let provider = ConnectionProviders.pipeline(
            transport: MemoryTransport(hub: hub),
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()]
        )

        let builder = NodeBuilder(
            keyPair: keyPair,
            listenAddresses: [address],
            connectionProviders: [provider],
            healthCheck: nil,
            services: {
                pingComponent(PingService())
            }
        )

        let node = builder.build()
        try await node.start()

        let protocols = await node.supportedProtocols()
        let listenAddresses = await node.listenAddresses()

        #expect(protocols.contains(ProtocolID.ping))
        #expect(listenAddresses.contains(address))

        await node.shutdown()
        hub.reset()
    }

    @Test("NodeBuilder accepts runtime configuration", .timeLimit(.minutes(1)))
    func acceptsRuntimeConfiguration() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-runtime")
        let runtime = RuntimeConfiguration(
            keyPair: .generateEd25519(),
            listenAddresses: [address],
            connectionProviders: [
                ConnectionProviders.pipeline(
                    transport: MemoryTransport(hub: hub),
                    security: [PlaintextUpgrader()],
                    muxers: [YamuxMuxer()]
                )
            ]
        )

        let builder = NodeBuilder(
            runtime: runtime,
            healthCheck: nil,
            services: {
                pingComponent(PingService())
            }
        )

        let node = builder.build()
        try await node.start()

        let listenAddresses = await node.listenAddresses()
        #expect(listenAddresses.contains(address))

        await node.shutdown()
        hub.reset()
    }

    @Test("Discovery DSL wires owned discovery roles into runtime", .timeLimit(.minutes(1)))
    func discoveryDSLWiresOwnedRoles() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-discovery-roles")
        let keyPair = KeyPair.generateEd25519()
        let mockDiscovery = OwnedDiscoveryRoleSource(localPeerID: keyPair.peerID)

        let server = NodeBuilder(
            keyPair: keyPair,
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil,
            discovery: {
                discovery(mockDiscovery, configure: { component in
                    component.handlesInboundStreams()
                    component.observesPeers()
                    component.activatesWithStreamOpening()
                })
            }
        ).build()

        let client = NodeBuilder(
            listenAddresses: [Multiaddr.memory(id: "node-builder-discovery-client")],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ).build()

        try await server.start()
        try await client.start()

        let protocols = await server.supportedProtocols()
        #expect(protocols.contains(OwnedDiscoveryRoleSource.mockProtocolID))

        let initialState = mockDiscovery.state()
        #expect(initialState.openerAttached)
        #expect(initialState.activated)

        _ = try await client.connect(to: address)

        var finalState = mockDiscovery.state()
        for _ in 0..<20 where finalState.peerConnectedCount == 0 {
            try await Task.sleep(for: .milliseconds(50))
            finalState = mockDiscovery.state()
        }
        #expect(finalState.peerConnectedCount == 1)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Built-in discovery helpers register runtime stream roles", .timeLimit(.minutes(1)))
    func builtInDiscoveryHelpersRegisterRuntimeRoles() async throws {
        let hub = MemoryHub()
        let node = NodeBuilder(
            listenAddresses: [Multiaddr.memory(id: "node-builder-real-discovery")],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil,
            discovery: {
                cyclon()
                plumtreeDiscovery()
            }
        ).build()

        try await node.start()

        let protocols = await node.supportedProtocols()
        #expect(protocols.contains(cyclonProtocolID))
        #expect(protocols.contains(ProtocolID.plumtree))

        await node.shutdown()
        hub.reset()
    }

    @Test("Node can retry start after initial listener failure", .timeLimit(.minutes(1)))
    func nodeCanRetryStartAfterInitialListenerFailure() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-retry-start")
        let baseProvider = ConnectionProviders.pipeline(
            transport: MemoryTransport(hub: hub),
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()]
        )
        let flakyProvider = FlakyListenConnectionProvider(delegate: baseProvider)

        let node = NodeBuilder(
            keyPair: .generateEd25519(),
            listenAddresses: [address],
            connectionProviders: [flakyProvider],
            healthCheck: nil
        ).build()

        do {
            try await node.start()
            Issue.record("Expected first start to fail")
        } catch {
            // Expected first listen attempt to fail.
        }

        try await node.start()

        let listenAddresses = await node.listenAddresses()
        #expect(listenAddresses.contains(address))

        await node.shutdown()
        hub.reset()
    }
}

private final class MockDiscoverySource: DiscoveryService, Sendable {
    struct State: Sendable {
        var started = false
        var shutdown = false
    }

    let localPeerID: PeerID
    private let currentState = Mutex(State())

    init(localPeerID: PeerID) {
        self.localPeerID = localPeerID
    }

    func markStarted() {
        currentState.withLock { $0.started = true }
    }

    func state() -> State {
        currentState.withLock { $0 }
    }

    func announce(addresses: [Multiaddr]) async throws {}

    func find(peer: PeerID) async throws -> [ScoredCandidate] {
        []
    }

    func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func collectKnownPeers() async -> [PeerID] {
        []
    }

    nonisolated var observations: AsyncStream<PeerObservation> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func shutdown() async {
        currentState.withLock { $0.shutdown = true }
    }
}

private final class OwnedDiscoveryRoleSource:
    DiscoveryService,
    StreamService,
    PeerObserver,
    StreamOpeningActivatable
{
    static let mockProtocolID = "/test/discovery/roles/1.0.0"

    struct State: Sendable {
        var openerAttached = false
        var activated = false
        var peerConnectedCount = 0
    }

    let localPeerID: PeerID
    let protocolIDs: [String] = [mockProtocolID]
    private let currentState = Mutex(State())

    init(localPeerID: PeerID) {
        self.localPeerID = localPeerID
    }

    func state() -> State {
        currentState.withLock { $0 }
    }

    func activate(using opener: any StreamOpener) async {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        currentState.withLock { state in
            state.openerAttached = true
            state.activated = true
        }
    }

    func peerConnected(_ peer: PeerID) async {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        currentState.withLock { $0.peerConnectedCount += 1 }
    }

    func peerDisconnected(_ peer: PeerID) async {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
    }

    func handleInboundStream(_ context: StreamContext) async {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
    }

    func announce(addresses: [Multiaddr]) async throws {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
    }

    func find(peer: PeerID) async throws -> [ScoredCandidate] {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        return []
    }

    func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func collectKnownPeers() async -> [PeerID] {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        return []
    }

    var observations: AsyncStream<PeerObservation> {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    func shutdown() async {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
    }
}

private final class MockStreamOpeningActivationService:
    LifecycleService,
    StreamService,
    StreamOpeningConsumer,
    ActivatableService,
    StreamOpeningActivatable,
    Sendable
{
    struct State: Sendable {
        var attachCalled = false
        var activateCalled = false
        var activateUsingCalled = false
    }

    let protocolIDs = ["/test/service/stream-opening-activation/1.0.0"]
    private let currentState = Mutex(State())

    func state() -> State {
        currentState.withLock { $0 }
    }

    func handleInboundStream(_ context: StreamContext) async {}

    func attachStreamOpening(_ opener: any StreamOpener) async {
        currentState.withLock { $0.attachCalled = true }
    }

    func activate() async {
        currentState.withLock { $0.activateCalled = true }
    }

    func activate(using opener: any StreamOpener) async {
        currentState.withLock { $0.activateUsingCalled = true }
    }

    func shutdown() async {}
}

private final class FlakyListenConnectionProvider: ConnectionProvider, Sendable {
    private struct State: Sendable {
        var listenAttempts = 0
    }

    private let delegate: any ConnectionProvider
    private let state = Mutex(State())

    init(delegate: any ConnectionProvider) {
        self.delegate = delegate
    }

    var pathKind: TransportPathKind {
        delegate.pathKind
    }

    func canDial(_ address: Multiaddr) -> Bool {
        delegate.canDial(address)
    }

    func canListen(_ address: Multiaddr) -> Bool {
        delegate.canListen(address)
    }

    func dial(_ address: Multiaddr, identity: LocalIdentity) async throws -> any StreamSession {
        try await delegate.dial(address, identity: identity)
    }

    func listen(_ address: Multiaddr, identity: LocalIdentity) async throws -> any ConnectionAcceptor {
        let shouldFail = state.withLock { state in
            state.listenAttempts += 1
            return state.listenAttempts == 1
        }
        if shouldFail {
            throw FlakyListenError.failedFirstListen
        }
        return try await delegate.listen(address, identity: identity)
    }
}

private enum FlakyListenError: Error {
    case failedFirstListen
}
