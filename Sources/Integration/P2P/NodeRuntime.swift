import Foundation
import P2PCore
import P2PDiscovery
import P2PMux
import P2PProtocols

private let runtimeLogger = Logger(label: "p2p.node.runtime")

internal actor NodeRuntime {
    let configuration: NodeConfiguration

    private let swarm: Swarm
    nonisolated let pool: ConnectionPool
    nonisolated let dialBackoff: DialBackoff
    nonisolated let listenAddressStore: ListenAddressStore
    nonisolated let advertisedAddressStore: ListenAddressStore
    nonisolated let relayAddressStore = ListenAddressStore()

    private var healthMonitor: HealthMonitor?
    private let peerStore: any PeerStore
    private let addressBook: any AddressBook
    private let protoBook: any ProtoBook
    private let keyBook: any KeyBook
    private var bootstrap: (any BootstrapService)?

    private enum LifecycleState {
        case idle
        case starting
        case running
        case stopped
    }

    private var lifecycleState: LifecycleState = .idle
    private var startTask: Task<Void, any Error>?
    private var eventForwardingTask: Task<Void, Never>?
    private var activeServices: [any LifecycleService] = []
    private var activePeerObservers: [any PeerObserver] = []
    private var traversalCoordinator: TraversalCoordinator?
    private var discoveryController: NodeDiscoveryController?
    private var handlers: [String: ProtocolHandler] = [:]

    private nonisolated let channel = EventChannel<NodeEvent>()
    nonisolated var events: AsyncStream<NodeEvent> { channel.stream }

    init(
        configuration: NodeConfiguration,
        peerStore: any PeerStore,
        addressBook: any AddressBook,
        protoBook: any ProtoBook,
        keyBook: any KeyBook
    ) {
        let runtime = configuration.runtime
        let connectionResources = configuration.resourceManager.map { ResourceManagerConnectionAccounting(base: $0) }
        let streamResources = configuration.resourceManager.map { ResourceManagerStreamAccounting(base: $0) }
        let streamLifecycle = DefaultStreamLifecycleCoordinator(resources: streamResources)
        let reconnectPlanner = DefaultReconnectPlanner(policy: runtime.pool.reconnectionPolicy)
        let conflictResolver = DeterministicConnectionConflictResolver()
        self.configuration = configuration
        let swarm = Swarm(configuration: SwarmConfiguration(
            localIdentity: LocalIdentity(keyPair: runtime.keyPair),
            listenAddresses: runtime.listenAddresses,
            connectionProviders: runtime.connectionProviders,
            pool: runtime.pool,
            idleTimeout: runtime.pool.idleTimeout,
            reconnectionPolicy: runtime.pool.reconnectionPolicy,
            maxNegotiatingInboundStreams: runtime.maxNegotiatingInboundStreams,
            connectionGater: runtime.pool.gater,
            connectionResources: connectionResources,
            streamResources: streamResources,
            streamLifecycle: streamLifecycle,
            reconnectPlanner: reconnectPlanner,
            conflictResolver: conflictResolver
        ))
        self.swarm = swarm
        self.pool = swarm.pool
        self.dialBackoff = swarm.dialBackoff
        self.listenAddressStore = swarm.listenAddresses
        self.advertisedAddressStore = swarm.advertisedAddresses
        self.peerStore = peerStore
        self.addressBook = addressBook
        self.protoBook = protoBook
        self.keyBook = keyBook
    }

    func registerHandler(for protocolID: String, handler: @escaping ProtocolHandler) async {
        handlers[protocolID] = handler
        await swarm.registerHandler(for: protocolID, handler: handler)
    }

    func supportedProtocols() -> [String] {
        Array(handlers.keys)
    }

    func start(capabilities: any RuntimeCapabilitySource) async throws {
        switch lifecycleState {
        case .running: return
        case .starting:
            if let startTask {
                try await startTask.value
            }
            return
        case .stopped: throw NodeError.nodeNotRunning
        case .idle: break
        }
        lifecycleState = .starting
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performStart(capabilities: capabilities)
        }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    private func performStart(capabilities: any RuntimeCapabilitySource) async throws {
        do {
            let serviceContext = ServiceContext(
                localIdentity: capabilities,
                listenAddresses: capabilities,
                supportedProtocols: capabilities,
                peerStore: capabilities,
                streamOpener: capabilities,
                addressDialer: capabilities
            )
            let composition = RuntimeComposition.resolve(
                services: configuration.services,
                context: serviceContext,
                discovery: configuration.discovery
            )

            if let healthConfig = configuration.healthCheck {
                let monitor = HealthMonitor(
                    configuration: healthConfig,
                    pingProvider: NodePingProvider(runtime: self)
                )
                await monitor.setOnHealthCheckFailed { [weak self] peer in
                    await self?.handleHealthCheckFailed(peer: peer)
                }
                self.healthMonitor = monitor
            }

            activeServices = composition.services.lifecycleServices
            activePeerObservers = composition.services.peerObservers

            for (protocolID, handler) in handlers {
                await swarm.registerHandler(for: protocolID, handler: handler)
            }

            for streamService in composition.services.inboundHandlers {
                for protocolID in streamService.protocolIDs {
                    let handler: ProtocolHandler = { context in
                        await streamService.handleInboundStream(context)
                    }
                    handlers[protocolID] = handler
                    await swarm.registerHandler(for: protocolID, handler: handler)
                }
            }

            for action in composition.preStartActions {
                await action()
            }

            try await swarm.start()
            startEventForwarding()

            let relayStore = relayAddressStore
            for contributor in composition.services.listenAddressContributors {
                contributor.setListenAddressCallback { addresses in
                    relayStore.update(addresses)
                }
            }

            for action in composition.postStartActions {
                try await action()
            }

            let resolved = advertisedAddressStore.current
            let activeDiscoverySources = composition.discoverySources
            for discovery in activeDiscoverySources {
                if !resolved.isEmpty {
                    do {
                        try await discovery.announce(addresses: resolved)
                    } catch {
                        runtimeLogger.warning("[P2P] Discovery announce failed: \(error)")
                    }
                }
            }

            if configuration.discoveryConfig.autoConnect, !activeDiscoverySources.isEmpty {
                let controller = NodeDiscoveryController(
                    configuration: configuration.discoveryConfig,
                    localPeerID: configuration.keyPair.peerID,
                    peerStore: peerStore,
                    addressBook: addressBook,
                    pool: pool,
                    dialBackoff: dialBackoff,
                    connect: { [weak self] address in
                        guard let self else { throw NodeError.nodeNotRunning }
                        return try await self.dial(to: address)
                    }
                )
                await controller.start(sources: activeDiscoverySources)
                discoveryController = controller
            }

            if let traversalConfig = configuration.traversal {
                let coordinator = TraversalCoordinator(
                    configuration: traversalConfig,
                    localPeer: configuration.keyPair.peerID,
                    connectionProviders: configuration.connectionProviders
                )
                let addressStore = listenAddressStore
                let pool = self.pool
                await coordinator.start(
                    opener: self,
                    getLocalAddresses: {
                        addressStore.current
                    },
                    getPeers: {
                        pool.connectedPeers
                    },
                    isLimitedConnection: { peer in
                        pool.isLimitedConnection(to: peer)
                    },
                    dialAddress: { [weak self] addr in
                        guard let self else { throw NodeError.nodeNotRunning }
                        return try await self.dial(to: addr)
                    }
                )
                traversalCoordinator = coordinator
            }

            if let memoryStore = peerStore as? MemoryPeerStore {
                memoryStore.startGC()
            }

            if let bootstrapConfig = configuration.bootstrap, !bootstrapConfig.seeds.isEmpty {
                let connectionProvider = NodeConnectionProvider(runtime: self)
                let bootstrap = DefaultBootstrap(
                    configuration: bootstrapConfig,
                    connectionProvider: connectionProvider,
                    peerStore: peerStore
                )
                self.bootstrap = bootstrap

                _ = await bootstrap.bootstrap()

                if bootstrapConfig.automaticBootstrap {
                    await bootstrap.startAutoBootstrap()
                }
            }

            lifecycleState = .running
        } catch {
            await rollbackStartFailure()
            lifecycleState = .idle
            throw error
        }
    }

    func shutdown() async throws {
        guard lifecycleState != .stopped else { return }
        lifecycleState = .stopped

        var firstError: Error?

        do {
            try await traversalCoordinator?.shutdown()
        } catch {
            firstError = firstError ?? error
        }
        traversalCoordinator = nil

        if let memoryStore = peerStore as? MemoryPeerStore {
            memoryStore.shutdown()
        }

        await discoveryController?.shutdown()
        discoveryController = nil
        if let discovery = configuration.discovery {
            do {
                try await discovery.shutdown()
            } catch {
                firstError = firstError ?? error
            }
        }

        if let bootstrap {
            await bootstrap.stopAutoBootstrap()
        }
        bootstrap = nil

        await healthMonitor?.stopAll()

        for service in activeServices {
            do {
                try await service.shutdown()
            } catch {
                firstError = firstError ?? error
            }
        }
        activeServices = []
        activePeerObservers = []

        relayAddressStore.clear()

        eventForwardingTask?.cancel()
        do {
            try await swarm.shutdown()
        } catch {
            firstError = firstError ?? error
        }
        await eventForwardingTask?.value
        eventForwardingTask = nil
        healthMonitor = nil
        channel.finish()

        if let firstError {
            throw firstError
        }
    }

    func dial(to address: Multiaddr) async throws -> PeerID {
        guard lifecycleState == .running else { throw NodeError.nodeNotRunning }
        return try await swarm.dial(to: address)
    }

    func connect(to peer: PeerID) async throws -> PeerID {
        guard lifecycleState == .running else { throw NodeError.nodeNotRunning }

        if pool.isConnected(to: peer) { return peer }

        let addresses = await addressBook.sortedAddresses(for: peer)

        if let traversalCoordinator {
            let result = try await traversalCoordinator.connect(
                to: peer,
                knownAddresses: addresses
            )
            return result.connectedPeer
        }

        guard !addresses.isEmpty else {
            throw NodeError.noAddressesKnown(peer)
        }

        var lastError: any Error = NodeError.noSuitableTransport
        for addr in addresses {
            do {
                return try await dial(to: addr)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func closePeer(_ peer: PeerID) async {
        guard lifecycleState == .running else { return }
        await healthMonitor?.stopMonitoring(peer: peer)
        await swarm.closePeer(peer)
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        guard lifecycleState == .running else { throw NodeError.nodeNotRunning }
        return try await swarm.newStream(to: peer, protocol: protocolID)
    }

    func listenAddresses() -> [Multiaddr] {
        listenAddressStore.current + relayAddressStore.current
    }

    nonisolated func isLimitedConnection(to peer: PeerID) -> Bool {
        pool.isLimitedConnection(to: peer)
    }

    nonisolated func connection(to peer: PeerID) -> MuxedConnection? {
        pool.connection(to: peer)
    }

    nonisolated func connectionState(of peer: PeerID) -> ConnectionState? {
        pool.connectionState(of: peer)
    }

    nonisolated var connectedPeers: [PeerID] {
        pool.connectedPeers
    }

    nonisolated var advertisedAddresses: [Multiaddr] {
        advertisedAddressStore.current
    }

    nonisolated var connectionCount: Int {
        pool.connectionCount
    }

    nonisolated func connectionTrimReport() -> ConnectionTrimReport {
        pool.trimReport()
    }

    nonisolated func tag(_ peer: PeerID, with tag: String) {
        pool.tag(peer, with: tag)
    }

    nonisolated func untag(_ peer: PeerID, tag: String) {
        pool.untag(peer, tag: tag)
    }

    nonisolated func protect(_ peer: PeerID) {
        pool.protect(peer)
    }

    nonisolated func unprotect(_ peer: PeerID) {
        pool.unprotect(peer)
    }

    nonisolated func setKeepAlive(_ keepAlive: Bool, for peer: PeerID) {
        pool.setKeepAlive(keepAlive, for: peer)
    }

    private func startEventForwarding() {
        eventForwardingTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.swarm.events {
                guard !Task.isCancelled else { break }
                await self.handleSwarmEvent(event)
            }
        }
    }

    private func handleSwarmEvent(_ event: SwarmEvent) async {
        switch event {
        case .peerConnected(let peer):
            for observer in activePeerObservers {
                await observer.peerConnected(peer)
            }
            emit(.peerConnected(peer))
            Task { await healthMonitor?.startMonitoring(peer: peer) }
        case .peerDisconnected(let peer):
            for observer in activePeerObservers {
                await observer.peerDisconnected(peer)
            }
            emit(.peerDisconnected(peer))
            Task { await healthMonitor?.stopMonitoring(peer: peer) }
        case .connection(let connectionEvent):
            emit(.connection(connectionEvent))
        case .listenError(let addr, let error):
            emit(.listenError(addr, error))
        case .newListenAddr(let addr):
            emit(.newListenAddr(addr))
        case .expiredListenAddr(let addr):
            emit(.expiredListenAddr(addr))
        case .dialing(let peer):
            emit(.dialing(peer))
        case .outgoingConnectionError(let peer, let error):
            emit(.outgoingConnectionError(peer: peer, error: error))
        case .connectionError(let peer, let error):
            emit(.connectionError(peer, error))
        }
    }

    private func handleHealthCheckFailed(peer: PeerID) async {
        emit(.connection(.healthCheckFailed(peer: peer)))
        await closePeer(peer)
    }

    private func rollbackStartFailure() async {
        do {
            try await traversalCoordinator?.shutdown()
        } catch {
        }
        traversalCoordinator = nil

        await discoveryController?.shutdown()
        discoveryController = nil
        if let discovery = configuration.discovery {
            await discovery.resetAfterStartFailure()
        }

        if let bootstrap {
            await bootstrap.stopAutoBootstrap()
        }
        bootstrap = nil

        await healthMonitor?.stopAll()
        healthMonitor = nil

        for service in activeServices {
            do {
                try await service.shutdown()
            } catch {
            }
        }
        activeServices = []
        activePeerObservers = []

        relayAddressStore.clear()

        eventForwardingTask?.cancel()
        do {
            try await swarm.shutdown()
        } catch {
        }
        await eventForwardingTask?.value
        eventForwardingTask = nil
    }

    private func emit(_ event: NodeEvent) {
        channel.yield(event)
    }
}

extension NodeRuntime: StreamOpener {}
