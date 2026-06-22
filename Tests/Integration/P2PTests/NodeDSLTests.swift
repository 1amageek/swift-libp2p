import Foundation
import Synchronization
import Testing
@testable import P2P
@testable import P2PCore
@testable import P2PDiscovery
@testable import P2PDiscoveryCYCLON
@testable import P2PDiscoveryMDNS
@testable import P2PDiscoveryPlumtree
@testable import P2PDiscoverySWIM
@testable import P2PCircuitRelay
@testable import P2PDCUtR
@testable import P2PIdentify
@testable import P2PProtocols
@testable import P2PSecurityPlaintext
@testable import P2PTransportMemory

private enum NodeDSLStartupError: Error {
    case startupFailed
}

@Suite("Node DSL Tests", .serialized)
struct NodeDSLTests {
    private struct CompositeTestComponent: NodeComponent {
        let pingService: PingService
        let discoverySource: MockDiscoverySource

        var body: some NodeComponent {
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

    private struct NestedNodeComponentLevel1: NodeComponent {
        let service: PingService

        var body: some NodeComponent {
            NestedNodeComponentLevel2(service: service)
        }
    }

    private struct NestedNodeComponentLevel2: NodeComponent {
        let service: PingService

        var body: some NodeComponent {
            NestedNodeComponentLevel3(service: service)
        }
    }

    private struct NestedNodeComponentLevel3: NodeComponent {
        let service: PingService

        var body: some NodeComponent {
            Service(service)
                .handlesInboundStreams()
        }
    }

    @Test("Node supports bare trailing-closure DSL", .timeLimit(.minutes(1)))
    func supportsBareTrailingClosureDSL() async throws {
        let node = try Node {
            Ping()
        }

        try await node.start()

        #expect((await node.supportedProtocols()).contains(ProtocolID.ping))

        try await node.shutdown()
    }

    @Test("Custom NodeComponent can compose primitive groups", .timeLimit(.minutes(1)))
    func customNodeComponentComposesPrimitiveGroups() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-component-group")
        let keyPair = KeyPair.generateEd25519()
        let pingService = PingService()
        let mockDiscovery = MockDiscoverySource(localPeerID: keyPair.peerID)

        let node = try Node(
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

        try await node.shutdown()

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

        let node = try Node(
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

        try await node.shutdown()

        #expect(mockDiscovery.state().shutdown)
        hub.reset()
    }

    @Test("Nested custom NodeComponents resolve through multiple body levels", .timeLimit(.minutes(1)))
    func nestedCustomNodeComponentsResolve() async throws {
        let node = try Node {
            NestedNodeComponentLevel1(service: PingService())
        }

        try await node.start()

        #expect((await node.supportedProtocols()).contains(ProtocolID.ping))

        try await node.shutdown()
    }

    @Test("Built-in service helpers derive runtime capabilities without attach", .timeLimit(.minutes(1)))
    func builtInServiceHelpersDeriveRuntimeCapabilities() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-factory-services")

        let node = try Node(
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

        try await node.shutdown()
        hub.reset()
    }

    @Test("ServicePipeline prefers stream-opening activation over attach plus activate", .timeLimit(.minutes(1)))
    func servicePipelinePrefersStreamOpeningActivation() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-stream-opening-activation")
        let mockService = MockStreamOpeningActivationService()

        let node = try Node(
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

        try await node.shutdown()
        hub.reset()
    }

    @Test("DCUtR helper installs protocol handler through post-start runtime hooks", .timeLimit(.minutes(1)))
    func dcutrHelperInstallsProtocolHandler() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-dcutr")

        let node = try Node(
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

        try await node.shutdown()
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

        let node = try Node(
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

        try await node.shutdown()
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

        let node = try Node(
            runtime: runtime,
            healthCheck: nil
        ) {
            Ping()
        }
        try await node.start()

        let listenAddresses = await node.listenAddresses()
        #expect(listenAddresses.contains(address))

        try await node.shutdown()
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
        // Development still enforces resource limits (no silent "unlimited") —
        // a real DefaultResourceManager, not nil/NullResourceManager.
        #expect(configuration.resourceManager is DefaultResourceManager)
    }

    @Test("Production validation reports disabled operational safeguards", .timeLimit(.minutes(1)))
    func productionValidationReportsDisabledOperationalSafeguards() async throws {
        // An explicit NullResourceManager is the deliberate "no limits" opt-out.
        // In production this is an ERROR (not a silent warning); a disabled
        // health check remains a warning.
        let configuration = NodeConfiguration(
            keyPair: .generateEd25519(),
            healthCheck: nil,
            resourceManager: NullResourceManager()
        )

        let report = configuration.validationReport(for: .production)

        #expect(report.errors.contains(.disabledResourceManagerInProduction))
        #expect(report.warnings.contains(.disabledHealthChecksInProduction))
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
            resourceManager: DefaultResourceManager()
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
            resourceManager: DefaultResourceManager()
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
            resourceManager: DefaultResourceManager()
        )

        #expect(report.errors.isEmpty)
        #expect(report.warnings.contains(.opaqueConnectionProvidersRequireManualSecurityAudit))
    }

    @Test("Strict production start validation rejects warning-only configurations", .timeLimit(.minutes(1)))
    func strictProductionStartValidationRejectsWarningOnlyConfigurations() async throws {
        // healthCheck: nil is a warning; an explicit NullResourceManager is an
        // error. Strict validation rejects on either.
        let node = try Node(
            keyPair: .generateEd25519(),
            healthCheck: nil,
            resourceManager: NullResourceManager()
        ) {
            Ping()
        }

        do {
            try await node.start(validating: .production, behavior: .strict)
            Issue.record("Expected strict production validation to fail before startup")
        } catch let error as NodeStartValidationError {
            #expect(error.profile == .production)
            #expect(error.validation.warnings.contains(.disabledHealthChecksInProduction))
            #expect(error.validation.errors.contains(.disabledResourceManagerInProduction))
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

        let server = try Node(
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

        let client = try Node(
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

        try await client.shutdown()
        try await server.shutdown()
        hub.reset()
    }

    @Test("Built-in discovery helpers register runtime stream roles", .timeLimit(.minutes(1)))
    func builtInDiscoveryHelpersRegisterRuntimeRoles() async throws {
        let hub = MemoryHub()
        let node = try Node(
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

        try await node.shutdown()
        hub.reset()
    }

    @Test("Built-in primitive initializers preserve service defaults", .timeLimit(.minutes(1)))
    func builtInPrimitiveInitializersPreserveServiceDefaults() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-primitive-service-defaults")

        let node = try Node(
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            Ping(servicePrimitive: Service(PingService()))
            DCUtR(servicePrimitive: Service(DCUtRService(configuration: .init())))
        }

        try await node.start()

        let protocols = await node.supportedProtocols()
        #expect(protocols.contains(ProtocolID.ping))
        #expect(protocols.contains(DCUtRProtocol.protocolID))

        try await node.shutdown()
        hub.reset()
    }

    @Test("Built-in primitive initializers preserve discovery defaults", .timeLimit(.minutes(1)))
    func builtInPrimitiveInitializersPreserveDiscoveryDefaults() async throws {
        let hub = MemoryHub()
        let node = try Node(
            listenAddresses: [Multiaddr.memory(id: "node-builder-primitive-discovery-defaults")],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            CYCLON(discoveryPrimitive: Discovery(weight: 1.0, makeSource: { localPeerID in
                CYCLONDiscovery(localPeerID: localPeerID, configuration: .default)
            }))
            PlumtreeDiscovery(discoveryPrimitive: Discovery(weight: 1.0, makeSource: { localPeerID in
                P2PDiscoveryPlumtree.PlumtreeDiscovery(localPeerID: localPeerID, configuration: .default)
            }))
        }

        try await node.start()

        let protocols = await node.supportedProtocols()
        #expect(protocols.contains(cyclonProtocolID))
        #expect(protocols.contains(ProtocolID.plumtree))

        try await node.shutdown()
        hub.reset()
    }

    @Test("Built-in MDNS startup failure propagates through Node.start", .timeLimit(.minutes(1)))
    func builtInMDNSStartupFailurePropagates() async throws {
        let hub = MemoryHub()
        let invalidServiceType = String(repeating: "a", count: 64)
        let node = try Node(
            listenAddresses: [Multiaddr.memory(id: "node-builder-mdns-startup-failure")],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            MDNS(configuration: MDNSConfiguration(serviceType: invalidServiceType))
        }

        do {
            try await node.start()
            Issue.record("Expected MDNS startup to fail for invalid service type")
        } catch {
        }

        do {
            try await node.start()
            Issue.record("Expected repeated MDNS startup to fail for invalid service type")
        } catch {
        }

        try await node.shutdown()
        hub.reset()
    }

    @Test("Built-in SWIM startup failure propagates through Node.start", .timeLimit(.minutes(1)))
    func builtInSWIMStartupFailurePropagates() async throws {
        let hub = MemoryHub()
        let node = try Node(
            listenAddresses: [Multiaddr.memory(id: "node-builder-swim-startup-failure")],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            SWIM(configuration: SWIMMembershipConfiguration(port: 7946, bindHost: "256.256.256.256"))
        }

        do {
            try await node.start()
            Issue.record("Expected SWIM startup to fail for invalid bind host")
        } catch {
        }

        do {
            try await node.start()
            Issue.record("Expected repeated SWIM startup to fail for invalid bind host")
        } catch {
        }

        try await node.shutdown()
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

        let node = try Node(
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

        try await node.shutdown()
        hub.reset()
    }

    @Test("Node surfaces discovery startup failures and can retry start", .timeLimit(.minutes(1)))
    func nodeSurfacesDiscoveryStartupFailuresAndCanRetryStart() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-builder-discovery-retry-start")
        let keyPair = KeyPair.generateEd25519()
        let discovery = MockDiscoverySource(localPeerID: keyPair.peerID)
        let startup = FlakyDiscoveryStartup()

        let node = try Node(
            keyPair: keyPair,
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            Discovery(discovery)
                .onStart { source in
                    source.markStarted()
                    try await startup.run()
                }
        }

        await #expect(throws: NodeDSLStartupError.self) {
            try await node.start()
        }

        #expect(discovery.state().started)

        try await node.start()

        let listenAddresses = await node.listenAddresses()
        #expect(listenAddresses.contains(address))

        try await node.shutdown()
        hub.reset()
    }

    @Test("Built-in service primitives mark defaults applied", .timeLimit(.minutes(1)))
    func builtInServicePrimitivesMarkDefaultsApplied() {
        #expect(Ping().servicePrimitive.defaultsApplied)
        #expect(Identify().servicePrimitive.defaultsApplied)
        #expect(DCUtR(servicePrimitive: Service(DCUtRService(configuration: .init()))).servicePrimitive.defaultsApplied)
    }

    @Test("Built-in discovery primitives mark defaults applied", .timeLimit(.minutes(1)))
    func builtInDiscoveryPrimitivesMarkDefaultsApplied() {
        #expect(MDNS().discoveryPrimitive.defaultsApplied)
        #expect(SWIM().discoveryPrimitive.defaultsApplied)
        #expect(CYCLON().discoveryPrimitive.defaultsApplied)
        #expect(PlumtreeDiscovery().discoveryPrimitive.defaultsApplied)
    }

    @Test("User modifiers preserve defaultsApplied on discovery primitives", .timeLimit(.minutes(1)))
    func userModifiersPreserveDefaultsAppliedFlag() {
        let tuned = MDNS().weight(3.0)
        #expect(tuned.discoveryPrimitive.defaultsApplied)

        let customized = CYCLON()
            .weight(2.5)
            .onStart { _ in }
        #expect(customized.discoveryPrimitive.defaultsApplied)
    }

    @Test("Re-wrapping a built-in primitive does not re-apply defaults", .timeLimit(.minutes(1)))
    func rewrappingPreservesDefaultsApplied() {
        let initial = MDNS().weight(4.0)
        #expect(initial.discoveryPrimitive.defaultsApplied)

        let rewrapped = MDNS(discoveryPrimitive: initial.discoveryPrimitive)
        #expect(rewrapped.discoveryPrimitive.defaultsApplied)

        let initialService = Ping().servicePrimitive
        #expect(initialService.defaultsApplied)
        let rewrappedService = Ping(servicePrimitive: initialService)
        #expect(rewrappedService.servicePrimitive.defaultsApplied)
    }

    @Test("Concurrent start() calls coalesce to a single startup", .timeLimit(.minutes(1)))
    func concurrentStartCallsCoalesce() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-concurrent-start-coalesce")
        let node = try Node(
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            healthCheck: nil
        ) {
            Ping()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await node.start()
                }
            }
            try await group.waitForAll()
        }

        let listenAddresses = await node.listenAddresses()
        #expect(listenAddresses.contains(address))
        #expect((await node.supportedProtocols()).contains(ProtocolID.ping))

        try await node.shutdown()
        hub.reset()
    }

    @Test("Start coalescing propagates failure uniformly to concurrent callers", .timeLimit(.minutes(1)))
    func startCoalescingPropagatesFailureUniformly() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "node-start-coalesce-failure")
        let baseProvider = ConnectionProviders.pipeline(
            transport: MemoryTransport(hub: hub),
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()]
        )
        let flakyProvider = FlakyListenConnectionProvider(delegate: baseProvider)

        let node = try Node(
            keyPair: .generateEd25519(),
            listenAddresses: [address],
            connectionProviders: [flakyProvider],
            healthCheck: nil
        )

        let failureCount = Mutex(0)
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    do {
                        try await node.start()
                        return false
                    } catch {
                        return true
                    }
                }
            }
            for await failed in group {
                if failed { failureCount.withLock { $0 += 1 } }
            }
        }
        #expect(failureCount.withLock { $0 } >= 1)

        try await node.start()
        let listenAddresses = await node.listenAddresses()
        #expect(listenAddresses.contains(address))

        try await node.shutdown()
        hub.reset()
    }

    @Test("Concurrent DiscoveryPipeline.start() calls coalesce", .timeLimit(.minutes(1)))
    func concurrentDiscoveryPipelineStartCoalesces() async throws {
        let keyPair = KeyPair.generateEd25519()
        let source = MockDiscoverySource(localPeerID: keyPair.peerID)
        let startCounter = Mutex(0)
        let registration = DiscoveryRegistration(
            weight: 1.0,
            makeSource: { _ in source },
            startup: { _ in
                startCounter.withLock { $0 += 1 }
            }
        )
        let component = registration.component()
        let pipeline = DiscoveryPipeline(localPeerID: keyPair.peerID) {
            component
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await pipeline.start()
                }
            }
            try await group.waitForAll()
        }

        #expect(startCounter.withLock { $0 } == 1)
        try await pipeline.shutdown()
    }

    // MARK: - Cycle detection

    private struct DirectCycleComponent: NodeComponent {
        var body: some NodeComponent {
            DirectCycleComponent()
        }
    }

    private struct MutualCycleA: NodeComponent {
        var body: some NodeComponent {
            NodeGroup {
                MutualCycleB()
            }
        }
    }

    private struct MutualCycleB: NodeComponent {
        var body: some NodeComponent {
            NodeGroup {
                MutualCycleA()
            }
        }
    }

    private struct SharedHelper: NodeComponent {
        let service: PingService

        var body: some NodeComponent {
            Service(service).handlesInboundStreams()
        }
    }

    private struct RepeatsHelperInBody: NodeComponent {
        let first: PingService
        let second: PingService

        var body: some NodeComponent {
            NodeGroup {
                SharedHelper(service: first)
                SharedHelper(service: second)
            }
        }
    }

    @Test("Self-recursive NodeComponent throws recursionCycleDetected", .timeLimit(.minutes(1)))
    func directCycleThrowsRecursionError() {
        #expect(throws: NodeCompositionError.self) {
            _ = try Node {
                DirectCycleComponent()
            }
        }
    }

    @Test("Mutually-recursive NodeComponents throw recursionCycleDetected", .timeLimit(.minutes(1)))
    func mutualCycleThrowsRecursionError() {
        #expect(throws: NodeCompositionError.self) {
            _ = try Node {
                MutualCycleA()
            }
        }
    }

    @Test("Repeated sibling of the same type resolves without cycle error", .timeLimit(.minutes(1)))
    func repeatedSiblingsResolveSuccessfully() async throws {
        let node = try Node {
            NestedNodeComponentLevel1(service: PingService())
            NestedNodeComponentLevel1(service: PingService())
        }

        try await node.start()
        #expect((await node.supportedProtocols()).contains(ProtocolID.ping))
        try await node.shutdown()
    }

    @Test("Shared helper used twice within one body resolves successfully", .timeLimit(.minutes(1)))
    func sharedHelperInSameBodyResolvesSuccessfully() async throws {
        let node = try Node {
            RepeatsHelperInBody(
                first: PingService(),
                second: PingService()
            )
        }

        try await node.start()
        #expect((await node.supportedProtocols()).contains(ProtocolID.ping))
        try await node.shutdown()
    }

    @Test("Recursion error carries the offending component's type name", .timeLimit(.minutes(1)))
    func recursionErrorCarriesComponentTypeName() {
        do {
            _ = try Node {
                DirectCycleComponent()
            }
            Issue.record("expected recursionCycleDetected to be thrown")
        } catch let error as NodeCompositionError {
            switch error {
            case .recursionCycleDetected(let componentType):
                #expect(componentType.contains("DirectCycleComponent"))
            }
        } catch {
            Issue.record("expected NodeCompositionError, got \(error)")
        }
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

    func shutdown() async throws {
        currentState.withLock { $0.shutdown = true }
    }
}

private final class FlakyDiscoveryStartup: Sendable {
    private let state = Mutex(true)

    func run() async throws {
        let shouldFail = state.withLock { state -> Bool in
            if state {
                state = false
                return true
            }
            return false
        }
        if shouldFail {
            throw NodeDSLStartupError.startupFailed
        }
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

    func shutdown() async throws {
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

    func shutdown() async throws {}
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
