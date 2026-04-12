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

@Suite("Node DSL Tests", .serialized)
struct NodeDSLTests {
    private struct CompositeTestComponent: NodeComponent {
        let pingService: PingService
        let discoverySource: MockDiscoverySource

        var nodeGroup: NodeGroup {
            NodeGroup {
                Service(pingService)
                    .handlesInboundStreams()
                Discovery(discoverySource)
                    .onStart { source in
                        source.markStarted()
                    }
            }
        }
    }

    @Test("Node supports bare trailing-closure DSL", .timeLimit(.minutes(1)))
    func supportsBareTrailingClosureDSL() async throws {
        let node = Node {
            Ping()
        }

        try await node.start()

        #expect((await node.supportedProtocols()).contains(ProtocolID.ping))

        await node.shutdown()
    }

    @Test("Custom NodeComponent can compose primitive groups", .timeLimit(.minutes(1)))
    func customNodeComponentComposesPrimitiveGroups() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-component-group")
        let keyPair = KeyPair.generateEd25519()
        let pingService = PingService()
        let mockDiscovery = MockDiscoverySource(localPeerID: keyPair.peerID)

        let node = Node(
            keyPair: keyPair,
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            CompositeTestComponent(
                pingService: pingService,
                discoverySource: mockDiscovery
            )
        }

        try await node.start()

        #expect((await node.supportedProtocols()).contains(ProtocolID.ping))
        #expect(mockDiscovery.state().started)

        await node.shutdown()

        #expect(mockDiscovery.state().shutdown)
        hub.reset()
    }

    @Test("Node composes service and discovery DSL", .timeLimit(.minutes(1)))
    func composesServicesAndDiscovery() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder")
        let keyPair = KeyPair.generateEd25519()
        let pingService = PingService()
        let mockDiscovery = MockDiscoverySource(localPeerID: keyPair.peerID)

        let node = Node(
            keyPair: keyPair,
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            Ping(pingService)
            Discovery(mockDiscovery)
                .onStart { source in
                    source.markStarted()
                }
        }

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

        let node = Node(
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            Identify()
            RelayServer()
        }

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

        let node = Node(
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            Service(mockService)
                .handlesInboundStreams()
                .activatesWithStreamOpening()
        }

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

        let node = Node(
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            DCUtR()
        }

        try await node.start()

        let protocols = await node.supportedProtocols()
        #expect(protocols.contains(DCUtRProtocol.protocolID))

        await node.shutdown()
        hub.reset()
    }

    @Test("Node accepts direct connection providers", .timeLimit(.minutes(1)))
    func acceptsDirectConnectionProviders() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-provider")
        let keyPair = KeyPair.generateEd25519()

        let provider = ConnectionProviders.pipeline(
            transport: MemoryTransport(hub: hub),
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()]
        )

        let node = Node(
            keyPair: keyPair,
            listenAddresses: [address],
            connectionProviders: [provider],
            healthCheck: nil
        ) {
            Ping()
        }
        try await node.start()

        let protocols = await node.supportedProtocols()
        let listenAddresses = await node.listenAddresses()

        #expect(protocols.contains(ProtocolID.ping))
        #expect(listenAddresses.contains(address))

        await node.shutdown()
        hub.reset()
    }

    @Test("Node accepts runtime configuration", .timeLimit(.minutes(1)))
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

        let node = Node(
            runtime: runtime,
            healthCheck: nil
        ) {
            Ping()
        }
        try await node.start()

        let listenAddresses = await node.listenAddresses()
        #expect(listenAddresses.contains(address))

        await node.shutdown()
        hub.reset()
    }

    @Test("Production profile applies production-oriented defaults", .timeLimit(.minutes(1)))
    func productionProfileAppliesProductionDefaults() async throws {
        let configuration = NodeConfiguration(
            profile: .production,
            connectionProviders: [],
            transports: [],
            security: [],
            muxers: []
        )

        #expect(configuration.runtime.pool == .production)
        #expect(configuration.healthCheck == .production)
        #expect(configuration.resourceManager != nil)
    }

    @Test("Development profile applies development-oriented defaults", .timeLimit(.minutes(1)))
    func developmentProfileAppliesDevelopmentDefaults() async throws {
        let configuration = NodeConfiguration(
            profile: .development,
            connectionProviders: [],
            transports: [],
            security: [],
            muxers: []
        )

        #expect(configuration.runtime.pool == .development)
        #expect(configuration.healthCheck == .development)
        #expect(configuration.resourceManager == nil)
    }

    @Test("Production validation reports disabled operational safeguards", .timeLimit(.minutes(1)))
    func productionValidationReportsDisabledOperationalSafeguards() async throws {
        let configuration = NodeConfiguration(
            keyPair: .generateEd25519(),
            healthCheck: nil,
            resourceManager: nil
        )

        let report = configuration.validationReport(for: .production)

        #expect(report.errors.isEmpty)
        #expect(report.warnings.contains(.disabledHealthChecksInProduction))
        #expect(report.warnings.contains(.disabledResourceManagerInProduction))
    }

    @Test("Production input validation rejects plaintext security", .timeLimit(.minutes(1)))
    func productionInputValidationRejectsPlaintextSecurity() async throws {
        let hub = MemoryHub()
        let report = NodeConfiguration.validateProfileInputs(
            profile: .production,
            connectionProviderAuditMode: .transparentComposition,
            connectionProviders: [],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            healthCheck: .production,
            resourceManager: NullResourceManager()
        )

        #expect(report.errors.contains(.plaintextSecurityInProduction))
    }

    @Test("Production validation treats opaque providers as errors under strict audit", .timeLimit(.minutes(1)))
    func productionValidationTreatsOpaqueProvidersAsErrorsUnderStrictAudit() async throws {
        let report = NodeConfiguration.validateProfileInputs(
            profile: .production,
            connectionProviderAuditMode: .opaqueProviders,
            auditPolicy: .strict,
            connectionProviders: [],
            transports: [],
            security: [],
            healthCheck: .production,
            resourceManager: NullResourceManager()
        )

        #expect(report.errors.contains(.opaqueConnectionProvidersRequireManualSecurityAudit))
    }

    @Test("Production validation treats opaque providers as warnings under permissive audit", .timeLimit(.minutes(1)))
    func productionValidationTreatsOpaqueProvidersAsWarningsUnderPermissiveAudit() async throws {
        let report = NodeConfiguration.validateProfileInputs(
            profile: .production,
            connectionProviderAuditMode: .opaqueProviders,
            auditPolicy: .permissive,
            connectionProviders: [],
            transports: [],
            security: [],
            healthCheck: .production,
            resourceManager: NullResourceManager()
        )

        #expect(report.errors.isEmpty)
        #expect(report.warnings.contains(.opaqueConnectionProvidersRequireManualSecurityAudit))
    }

    @Test("Strict production start validation rejects warning-only configurations", .timeLimit(.minutes(1)))
    func strictProductionStartValidationRejectsWarningOnlyConfigurations() async throws {
        let node = Node(
            keyPair: .generateEd25519(),
            healthCheck: nil,
            resourceManager: nil
        ) {
            Ping()
        }

        do {
            try await node.start(validating: .production, behavior: .strict)
            Issue.record("Expected strict production validation to fail before startup")
        } catch let error as NodeStartValidationError {
            #expect(error.profile == .production)
            #expect(error.validation.warnings.contains(.disabledHealthChecksInProduction))
            #expect(error.validation.warnings.contains(.disabledResourceManagerInProduction))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Discovery DSL wires owned discovery roles into runtime", .timeLimit(.minutes(1)))
    func discoveryDSLWiresOwnedRoles() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-discovery-roles")
        let keyPair = KeyPair.generateEd25519()
        let mockDiscovery = OwnedDiscoveryRoleSource(localPeerID: keyPair.peerID)

        let server = Node(
            keyPair: keyPair,
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            Discovery(mockDiscovery)
                .handlesInboundStreams()
                .observesPeers()
                .receivesStreamOpening()
                .activatesOnStart()
        }

        let client = Node(
            listenAddresses: [Multiaddr.memory(id: "node-builder-discovery-client")],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        )

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
        let node = Node(
            listenAddresses: [Multiaddr.memory(id: "node-builder-real-discovery")],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            CYCLON()
            PlumtreeDiscovery()
        }

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

        let node = Node(
            keyPair: .generateEd25519(),
            listenAddresses: [address],
            connectionProviders: [flakyProvider],
            healthCheck: nil
        )

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
