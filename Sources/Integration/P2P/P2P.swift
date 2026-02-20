/// P2P - Unified entry point for swift-libp2p
///
/// Provides a high-level API for building P2P applications.

import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
// Protocol abstractions
@_exported import P2PCore
@_exported import P2PTransport
@_exported import P2PSecurity
@_exported import P2PMux
@_exported import P2PNegotiation
@_exported import P2PDiscovery
@_exported import P2PProtocols
// Default implementations (batteries-included)
@_exported import P2PTransportTCP
@_exported import P2PSecurityNoise
@_exported import P2PSecurityPlaintext
@_exported import P2PMuxYamux
@_exported import P2PPing
@_exported import P2PGossipSub
@_exported import NIOCore
// Internal
import P2PIdentify

/// Logger for P2P operations.
private let logger = Logger(label: "p2p.node")

private func runBestEffort(_ context: String, _ operation: () async throws -> Void) async {
    do {
        try await operation()
    } catch is CancellationError {
        logger.debug("Best-effort operation cancelled: \(context)")
    } catch {
        logger.warning("Best-effort operation failed (\(context)): \(error)")
    }
}

private func sleepUnlessCancelled(for duration: Duration, context: String) async -> Bool {
    do {
        try await Task.sleep(for: duration)
        return true
    } catch is CancellationError {
        logger.debug("Sleep cancelled: \(context)")
        return false
    } catch {
        logger.warning("Sleep failed (\(context)): \(error)")
        return false
    }
}

/// Thread-safe store for listen addresses, usable from @Sendable closures.
/// Wraps Mutex (which is ~Copyable) in a Sendable reference type.
private final class ListenAddressStore: Sendable {
    private let _addresses: Mutex<[Multiaddr]> = Mutex([])

    var current: [Multiaddr] {
        _addresses.withLock { $0 }
    }

    func update(_ addresses: [Multiaddr]) {
        _addresses.withLock { $0 = addresses }
    }

    func clear() {
        _addresses.withLock { $0 = [] }
    }
}

// MARK: - Configuration

/// Configuration for peer discovery and auto-connection.
public struct DiscoveryConfiguration: Sendable {

    /// Enable auto-connect to discovered peers.
    public var autoConnect: Bool

    /// Maximum peers to auto-connect.
    public var maxAutoConnectPeers: Int

    /// Minimum score threshold for auto-connect.
    public var autoConnectMinScore: Double

    /// Cooldown between connection attempts to same peer.
    public var reconnectCooldown: Duration

    public init(
        autoConnect: Bool = false,
        maxAutoConnectPeers: Int = 10,
        autoConnectMinScore: Double = 0.5,
        reconnectCooldown: Duration = .seconds(30)
    ) {
        self.autoConnect = autoConnect
        self.maxAutoConnectPeers = maxAutoConnectPeers
        self.autoConnectMinScore = autoConnectMinScore
        self.reconnectCooldown = reconnectCooldown
    }

    /// Default configuration with auto-connect disabled.
    public static let `default` = DiscoveryConfiguration()

    /// Configuration with auto-connect enabled.
    public static let autoConnectEnabled = DiscoveryConfiguration(
        autoConnect: true,
        maxAutoConnectPeers: 10,
        autoConnectMinScore: 0.5
    )
}

/// Configuration for a P2P node.
public struct NodeConfiguration: Sendable {

    /// The key pair for this node.
    public let keyPair: KeyPair

    /// Addresses to listen on.
    public let listenAddresses: [Multiaddr]

    /// Transports to use (in priority order for dialing).
    public let transports: [any Transport]

    /// Security upgraders (in priority order for negotiation).
    public let security: [any SecurityUpgrader]

    /// Muxers (in priority order for negotiation).
    public let muxers: [any Muxer]

    /// Connection pool configuration.
    public let pool: PoolConfiguration

    /// Health check configuration (nil to disable).
    public let healthCheck: HealthMonitorConfiguration?

    /// Discovery service (nil to disable).
    public let discovery: (any DiscoveryService)?

    /// Discovery configuration for auto-connect behavior.
    public let discoveryConfig: DiscoveryConfiguration

    /// Peer store for managing peer addresses (nil for default MemoryPeerStore).
    public let peerStore: (any PeerStore)?

    /// Address book configuration (nil for default).
    public let addressBookConfig: AddressBookConfiguration?

    /// Bootstrap configuration (nil to disable bootstrap).
    public let bootstrap: BootstrapConfiguration?

    /// ProtoBook for per-peer protocol tracking (nil for default MemoryProtoBook).
    public let protoBook: (any ProtoBook)?

    /// KeyBook for per-peer public key storage (nil for default MemoryKeyBook).
    public let keyBook: (any KeyBook)?

    /// Resource manager for system-wide resource accounting (nil for no limits).
    public let resourceManager: (any ResourceManager)?

    /// Identify service for peer information exchange and auto-push (nil to disable).
    public let identifyService: IdentifyService?

    /// Traversal configuration (nil to disable traversal orchestration).
    public let traversal: TraversalConfiguration?

    public init(
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        transports: [any Transport] = [],
        security: [any SecurityUpgrader] = [],
        muxers: [any Muxer] = [],
        pool: PoolConfiguration = .init(),
        healthCheck: HealthMonitorConfiguration? = .default,
        discovery: (any DiscoveryService)? = nil,
        discoveryConfig: DiscoveryConfiguration = .default,
        peerStore: (any PeerStore)? = nil,
        addressBookConfig: AddressBookConfiguration? = nil,
        bootstrap: BootstrapConfiguration? = nil,
        protoBook: (any ProtoBook)? = nil,
        keyBook: (any KeyBook)? = nil,
        resourceManager: (any ResourceManager)? = nil,
        identifyService: IdentifyService? = nil,
        traversal: TraversalConfiguration? = nil
    ) {
        self.keyPair = keyPair
        self.listenAddresses = listenAddresses
        self.transports = transports
        self.security = security
        self.muxers = muxers
        self.pool = pool
        self.healthCheck = healthCheck
        self.discovery = discovery
        self.discoveryConfig = discoveryConfig
        self.peerStore = peerStore
        self.addressBookConfig = addressBookConfig
        self.bootstrap = bootstrap
        self.protoBook = protoBook
        self.keyBook = keyBook
        self.resourceManager = resourceManager
        self.identifyService = identifyService
        self.traversal = traversal
    }
}

// MARK: - Events

/// Events emitted by the node.
public enum NodeEvent: Sendable {
    /// A peer connected.
    case peerConnected(PeerID)

    /// A peer disconnected.
    case peerDisconnected(PeerID)

    /// An error occurred while listening.
    case listenError(Multiaddr, any Error)

    /// An error occurred with a connection.
    case connectionError(PeerID?, any Error)

    /// A connection event occurred.
    case connection(ConnectionEvent)
}

// MARK: - Node

/// A P2P network node.
///
/// ## Responsibilities
/// - Public API (connect, disconnect, newStream, etc.)
/// - Event emission
/// - Delegates connection state management to ConnectionPool
///
/// ## State Management
/// Node does not directly manage connection state. All connection
/// tracking is handled by the internal ConnectionPool.
public actor Node: StreamOpener, HandlerRegistry {

    /// The configuration for this node.
    public let configuration: NodeConfiguration

    /// The peer ID of this node.
    public var peerID: PeerID {
        configuration.keyPair.peerID
    }

    // Internal components
    private let upgrader: ConnectionUpgrader
    private let pool: ConnectionPool
    private var healthMonitor: HealthMonitor?

    // Discovery components
    private let _peerStore: any PeerStore
    private let _addressBook: any AddressBook
    private let _protoBook: any ProtoBook
    private let _keyBook: any KeyBook
    private var _bootstrap: (any BootstrapService)?

    /// The peer store for this node.
    public var peerStore: any PeerStore { _peerStore }

    /// The address book for this node.
    public var addressBook: any AddressBook { _addressBook }

    /// The protocol book for this node.
    public var protoBook: any ProtoBook { _protoBook }

    /// The key book for this node.
    public var keyBook: any KeyBook { _keyBook }

    // Listeners
    private var listeners: [any Listener] = []
    private var securedListeners: [any SecuredListener] = []

    // Protocol handlers
    private var handlers: [String: ProtocolHandler] = [:]

    // State
    private var isRunning = false

    // Background tasks
    private var idleCheckTask: Task<Void, Never>?
    private var trimTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var acceptTasks: [Task<Void, Never>] = []

    // Dial coordination
    private nonisolated let dialBackoff = DialBackoff()
    private var discoveryAttachedPeers: Set<PeerID> = []
    private var peerConnectedEmitted: Set<PeerID> = []

    // Traversal orchestration
    private var traversalCoordinator: TraversalCoordinator?
    /// Current listen addresses, accessible synchronously from @Sendable closures.
    private nonisolated let _currentListenAddresses = ListenAddressStore()
    /// Resolved addresses for external advertisement (0.0.0.0 → actual interface IPs).
    private nonisolated let _advertisedAddresses = ListenAddressStore()

    // Events
    private var eventContinuation: AsyncStream<NodeEvent>.Continuation?
    private var _events: AsyncStream<NodeEvent>?

    /// Event stream for monitoring node state changes.
    public var events: AsyncStream<NodeEvent> {
        if let existing = _events {
            return existing
        }
        let (stream, continuation) = AsyncStream<NodeEvent>.makeStream()
        self._events = stream
        self.eventContinuation = continuation
        return stream
    }

    /// Creates a new node with the given configuration.
    public init(configuration: NodeConfiguration) {
        self.configuration = configuration
        self.upgrader = NegotiatingUpgrader(
            security: configuration.security,
            muxers: configuration.muxers
        )
        self.pool = ConnectionPool(configuration: configuration.pool)

        // Initialize peer store and address book
        let peerStore = configuration.peerStore ?? MemoryPeerStore()
        self._peerStore = peerStore
        self._addressBook = DefaultAddressBook(
            peerStore: peerStore,
            configuration: configuration.addressBookConfig ?? .default
        )
        self._protoBook = configuration.protoBook ?? MemoryProtoBook()
        self._keyBook = configuration.keyBook ?? MemoryKeyBook()
    }

    // MARK: - Protocol Handlers

    /// Registers a protocol handler.
    ///
    /// - Parameters:
    ///   - protocolID: The protocol identifier (e.g., "/chat/1.0.0")
    ///   - handler: The handler function for incoming streams
    public func handle(
        _ protocolID: String,
        handler: @escaping ProtocolHandler
    ) {
        handlers[protocolID] = handler
    }

    /// Registers a simple protocol handler that only needs the stream.
    ///
    /// - Parameters:
    ///   - protocolID: The protocol identifier (e.g., "/chat/1.0.0")
    ///   - handler: The handler function for incoming streams
    public func handleStream(
        _ protocolID: String,
        handler: @escaping @Sendable (MuxedStream) async -> Void
    ) {
        handlers[protocolID] = { context in
            await handler(context.stream)
        }
    }

    /// Returns the list of supported protocols.
    public var supportedProtocols: [String] {
        Array(handlers.keys)
    }

    // MARK: - Lifecycle

    /// Starts the node.
    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // Initialize health monitor if configured
        if let healthConfig = configuration.healthCheck {
            let monitor = HealthMonitor(
                configuration: healthConfig,
                pingProvider: NodePingProvider(node: self)
            )
            await monitor.setOnHealthCheckFailed { [weak self] peer in
                await self?.handleHealthCheckFailed(peer: peer)
            }
            self.healthMonitor = monitor
        }

        startIdleCheckTask()

        // Start listeners BEFORE discovery so we can accept inbound connections
        // when peers discover us
        for address in configuration.listenAddresses {
            for transport in configuration.transports {
                if transport.canListen(address) {
                    do {
                        // SecuredTransport (e.g., QUIC) uses a different listener type
                        if let securedTransport = transport as? SecuredTransport {
                            let listener = try await securedTransport.listenSecured(
                                address,
                                localKeyPair: configuration.keyPair
                            )
                            securedListeners.append(listener)

                            // Start secured accept loop
                            let acceptTask = Task { [weak self] in
                                guard let self else { return }
                                await self.securedAcceptLoop(listener: listener, address: listener.localAddress)
                            }
                            acceptTasks.append(acceptTask)
                        } else {
                            // Standard transport
                            let listener = try await transport.listen(address)
                            listeners.append(listener)

                            // Start accept loop
                            let acceptTask = Task { [weak self] in
                                guard let self else { return }
                                await self.acceptLoop(listener: listener, address: address)
                            }
                            acceptTasks.append(acceptTask)
                        }
                    } catch {
                        emit(.listenError(address, error))
                    }
                }
            }
        }

        // Fail if no listeners could bind and we had addresses to listen on
        if listeners.isEmpty && securedListeners.isEmpty && !configuration.listenAddresses.isEmpty {
            throw NodeError.noListenersBound
        }

        // Update current listen addresses for synchronous access
        let boundAddresses = listeners.map(\.localAddress) + securedListeners.map(\.localAddress)
        _currentListenAddresses.update(boundAddresses)

        // Resolve unspecified addresses (0.0.0.0 / ::) to actual interface IPs
        let resolved = Self.resolveUnspecifiedAddresses(boundAddresses)
        _advertisedAddresses.update(resolved)

        // Start discovery AFTER listeners are ready, so announce() has resolved addresses
        // and we can accept inbound connections from discovered peers
        if let discovery = configuration.discovery {
            try await setupDiscoveryIntegration(discovery)

            // Announce resolved addresses to discovery service
            if !resolved.isEmpty {
                do {
                    try await discovery.announce(addresses: resolved)
                } catch {
                    logger.warning("[P2P] Discovery announce failed: \(error)")
                }
            }

            // Start discovery auto-connect task (reactive via observations stream)
            if configuration.discoveryConfig.autoConnect {
                startDiscoveryTask(discovery: discovery)
            }
        }

        // Initialize traversal orchestration if configured
        if let traversalConfig = configuration.traversal {
            let coordinator = TraversalCoordinator(
                configuration: traversalConfig,
                localPeer: peerID,
                transports: configuration.transports
            )
            let addressStore = _currentListenAddresses
            await coordinator.start(
                opener: self,
                registry: self,
                getLocalAddresses: {
                    addressStore.current
                },
                getPeers: { [pool] in
                    pool.connectedPeers
                },
                isLimitedConnection: { [pool] peer in
                    pool.isLimitedConnection(to: peer)
                },
                dialAddress: { [weak self] (addr: Multiaddr) in
                    guard let self else { throw NodeError.nodeNotRunning }
                    return try await self.connect(to: addr)
                }
            )
            self.traversalCoordinator = coordinator
        }

        // Register IdentifyService handlers if configured
        if let identify = configuration.identifyService {
            await identify.registerHandlers(
                registry: self,
                localKeyPair: configuration.keyPair,
                getListenAddresses: { [weak self] in
                    guard let self else { return [] }
                    return await self.listenAddresses
                },
                getSupportedProtocols: { [weak self] in
                    guard let self else { return [] }
                    return await self.supportedProtocols
                },
                opener: self
            )
            identify.startMaintenance()
        }

        // Start PeerStore GC if using MemoryPeerStore
        if let memoryStore = _peerStore as? MemoryPeerStore {
            memoryStore.startGC()
        }

        // Initialize and start bootstrap if configured
        if let bootstrapConfig = configuration.bootstrap, !bootstrapConfig.seeds.isEmpty {
            let connectionProvider = NodeConnectionProvider(node: self)
            let bootstrap = DefaultBootstrap(
                configuration: bootstrapConfig,
                connectionProvider: connectionProvider,
                peerStore: _peerStore
            )
            self._bootstrap = bootstrap

            // Perform initial bootstrap
            _ = await bootstrap.bootstrap()

            // Start automatic bootstrap if enabled
            if bootstrapConfig.automaticBootstrap {
                await bootstrap.startAutoBootstrap()
            }
        }
    }

    /// Shuts down the node.
    public func shutdown() async {
        isRunning = false

        // Shutdown traversal coordinator first so event stream is finished promptly.
        traversalCoordinator?.shutdown()
        traversalCoordinator = nil
        _currentListenAddresses.clear()
        _advertisedAddresses.clear()

        // Shutdown PeerStore if using MemoryPeerStore (stops GC + releases events)
        if let memoryStore = _peerStore as? MemoryPeerStore {
            memoryStore.shutdown()
        }

        // Cancel accept loops first so listeners can close cleanly
        for task in acceptTasks { task.cancel() }
        acceptTasks.removeAll()

        // Cancel background tasks
        idleCheckTask?.cancel()
        idleCheckTask = nil
        trimTask?.cancel()
        trimTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil

        // Stop bootstrap
        if let bootstrap = _bootstrap {
            await bootstrap.stopAutoBootstrap()
        }
        _bootstrap = nil

        // Cancel pending dials
        pool.cancelAllPendingDials()

        // Stop health monitor
        await healthMonitor?.stopAll()

        // Close all listeners
        for listener in listeners {
            do {
                try await listener.close()
            } catch {
                logger.debug("Failed to close listener: \(error)")
            }
        }
        listeners.removeAll()

        // Close all secured listeners (QUIC, etc.)
        for listener in securedListeners {
            do {
                try await listener.close()
            } catch {
                logger.debug("Failed to close secured listener: \(error)")
            }
        }
        securedListeners.removeAll()

        // Close all connections
        for peer in pool.connectedPeers {
            let removed = pool.remove(forPeer: peer)
            for managed in removed {
                do {
                    try await managed.connection?.close()
                } catch {
                    logger.debug("Failed to close connection to \(peer): \(error)")
                }
                // Release connection resource only for entries with active reservations.
                // Entries in .disconnected/.failed were already released by handleConnectionClosed.
                if managed.state.isConnected {
                    configuration.resourceManager?.releaseConnection(peer: peer, direction: managed.direction)
                }
            }
            await onPeerDisconnected(peer)
        }

        // Clear tracking state
        dialBackoff.clear()
        discoveryAttachedPeers.removeAll()
        peerConnectedEmitted.removeAll()

        if let discovery = configuration.discovery {
            await discovery.shutdown()
        }

        // Shutdown IdentifyService
        configuration.identifyService?.shutdown()

        // Finish event stream
        eventContinuation?.finish()
        eventContinuation = nil
        _events = nil
    }

    // MARK: - Connections

    /// Connects to a peer at the given address.
    ///
    /// If a dial to the same peer is already in progress, this call
    /// will join that dial and return the same result.
    ///
    /// - Parameter address: The multiaddr to connect to
    /// - Returns: The remote peer ID
    @discardableResult
    public func connect(to address: Multiaddr) async throws -> PeerID {
        // 0. Self-connection guard — never dial ourselves
        let localPeerID = configuration.keyPair.peerID
        if let targetPeer = address.peerID, targetPeer == localPeerID {
            throw NodeError.selfDialNotAllowed
        }

        // 1. Gating check (dial)
        if let gater = configuration.pool.gater {
            if !gater.interceptDial(peer: address.peerID, address: address) {
                emitConnectionEvent(.gated(peer: address.peerID, address: address, stage: .dial))
                throw NodeError.connectionGated(stage: .dial)
            }
        }

        // 2. Check for pending dial to same peer (join existing)
        if let peerID = address.peerID, let pendingTask = pool.pendingDial(to: peerID) {
            return try await pendingTask.value
        }

        // 3. Check outbound limits
        if !pool.canDialOutbound() {
            throw NodeError.connectionLimitReached
        }

        // 4. Start new dial
        let dialTask = Task { [weak self] () throws -> PeerID in
            guard let self = self else { throw NodeError.nodeNotRunning }
            return try await self.performDial(to: address)
        }

        // Register pending dial if peer ID is known
        if let peerID = address.peerID {
            pool.registerPendingDial(dialTask, for: peerID)
        }

        do {
            let result = try await dialTask.value
            if let peerID = address.peerID {
                pool.removePendingDial(for: peerID)
            }
            return result
        } catch {
            if let peerID = address.peerID {
                pool.removePendingDial(for: peerID)
            }
            throw error
        }
    }

    /// Performs the actual dial operation.
    private func performDial(to address: Multiaddr) async throws -> PeerID {
        // Find a transport that can dial
        guard let transport = configuration.transports.first(where: { $0.canDial(address) }) else {
            throw NodeError.noSuitableTransport
        }

        let isRelay = transport.pathKind == .relay

        // SecuredTransport (e.g., QUIC) bypasses the upgrade pipeline
        if let securedTransport = transport as? SecuredTransport {
            return try await performSecuredDial(to: address, using: securedTransport, isLimited: isRelay)
        }

        // Track connecting state if peer ID is known from address
        let connectingID: ConnectionID?
        if let peerID = address.peerID {
            connectingID = pool.addConnecting(for: peerID, address: address, direction: .outbound, isLimited: isRelay)
        } else {
            connectingID = nil
        }

        // Clean up connecting entry on any failure path
        var didConnect = false
        defer {
            if !didConnect, let id = connectingID {
                pool.remove(id)
            }
        }

        // Standard transport: dial then upgrade
        let rawConnection = try await transport.dial(address)

        // Upgrade connection (security + muxer negotiation)
        let result: UpgradeResult
        do {
            result = try await upgrader.upgrade(
                rawConnection,
                localKeyPair: configuration.keyPair,
                role: .initiator,
                expectedPeer: address.peerID
            )
        } catch {
            await runBestEffort("close raw connection after upgrade failure") {
                try await rawConnection.close()
            }
            throw error
        }

        let remotePeer = result.connection.remotePeer

        // Self-connection guard (post-handshake, for addresses without embedded PeerID)
        if remotePeer == configuration.keyPair.peerID {
            await runBestEffort("close self-connection after handshake") {
                try await result.connection.close()
            }
            throw NodeError.selfDialNotAllowed
        }

        // Gating check (secured)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                await runBestEffort("close upgraded connection rejected by secured gater") {
                    try await result.connection.close()
                }
                emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                throw NodeError.connectionGated(stage: .secured)
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            await runBestEffort("close upgraded connection rejected by per-peer limit") {
                try await result.connection.close()
            }
            throw NodeError.connectionLimitReached
        }

        // Reserve outbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveOutboundConnection(to: remotePeer)
            } catch let error as ResourceError {
                await runBestEffort("close upgraded connection after outbound resource reservation failure") {
                    try await result.connection.close()
                }
                switch error {
                case .limitExceeded(let scope, let resource):
                    throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                }
            }
        }

        // Transition connecting entry to connected, or create new entry
        let connID: ConnectionID
        if let cid = connectingID {
            pool.updateConnection(cid, connection: result.connection)
            connID = cid
        } else {
            connID = pool.add(
                result.connection,
                for: remotePeer,
                address: address,
                direction: .outbound,
                isLimited: isRelay
            )
        }
        didConnect = true

        // Clear dial backoff on successful connection
        dialBackoff.recordSuccess(for: remotePeer)

        // Enable auto-reconnect if policy allows
        if configuration.pool.reconnectionPolicy.enabled {
            pool.enableAutoReconnect(for: remotePeer, address: address)
        }

        // Resolve simultaneous connect before emitting events.
        // This may close the duplicate connection if both peers dialed each other.
        await resolveSimultaneousConnect(for: remotePeer)

        // Start handling inbound streams BEFORE onPeerConnected.
        // onPeerConnected may open new streams (e.g., discovery), which require
        // the remote side's inbound handler to be running for protocol negotiation.
        Task { [weak self] in
            await self?.handleInboundStreams(connection: result.connection)
            await self?.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        // Emit events (guarded: only fires for first connection to this peer)
        await onPeerConnected(remotePeer, address: address, isLimited: isRelay)
        emitConnectionEvent(.connected(peer: remotePeer, address: address, direction: .outbound))

        // Start health monitoring
        await healthMonitor?.startMonitoring(peer: remotePeer)

        return remotePeer
    }

    /// Performs dial operation for SecuredTransport (e.g., QUIC).
    ///
    /// SecuredTransport provides built-in security and multiplexing,
    /// so we bypass the standard upgrade pipeline and get a MuxedConnection directly.
    private func performSecuredDial(
        to address: Multiaddr,
        using transport: SecuredTransport,
        isLimited: Bool = false
    ) async throws -> PeerID {
        // Track connecting state if peer ID is known from address
        let connectingID: ConnectionID?
        if let peerID = address.peerID {
            connectingID = pool.addConnecting(for: peerID, address: address, direction: .outbound, isLimited: isLimited)
        } else {
            connectingID = nil
        }

        // Clean up connecting entry on any failure path
        var didConnect = false
        defer {
            if !didConnect, let id = connectingID {
                pool.remove(id)
            }
        }

        // SecuredTransport returns MuxedConnection directly
        let muxedConnection = try await transport.dialSecured(
            address,
            localKeyPair: configuration.keyPair
        )

        let remotePeer = muxedConnection.remotePeer

        // Self-connection guard (post-handshake)
        if remotePeer == configuration.keyPair.peerID {
            await runBestEffort("close self-connection after secured handshake") {
                try await muxedConnection.close()
            }
            throw NodeError.selfDialNotAllowed
        }

        // Gating check (secured stage)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                await runBestEffort("close secured dial connection rejected by secured gater") {
                    try await muxedConnection.close()
                }
                emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                throw NodeError.connectionGated(stage: .secured)
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            await runBestEffort("close secured dial connection rejected by per-peer limit") {
                try await muxedConnection.close()
            }
            throw NodeError.connectionLimitReached
        }

        // Reserve outbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveOutboundConnection(to: remotePeer)
            } catch let error as ResourceError {
                await runBestEffort("close secured dial connection after outbound resource reservation failure") {
                    try await muxedConnection.close()
                }
                switch error {
                case .limitExceeded(let scope, let resource):
                    throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                }
            }
        }

        // Transition connecting entry to connected, or create new entry
        let connID: ConnectionID
        if let cid = connectingID {
            pool.updateConnection(cid, connection: muxedConnection)
            connID = cid
        } else {
            connID = pool.add(
                muxedConnection,
                for: remotePeer,
                address: address,
                direction: .outbound,
                isLimited: isLimited
            )
        }
        didConnect = true

        // Clear dial backoff on successful connection
        dialBackoff.recordSuccess(for: remotePeer)

        // Enable auto-reconnect if policy allows
        if configuration.pool.reconnectionPolicy.enabled {
            pool.enableAutoReconnect(for: remotePeer, address: address)
        }

        // Resolve simultaneous connect before emitting events.
        await resolveSimultaneousConnect(for: remotePeer)

        // Start handling inbound streams BEFORE onPeerConnected.
        Task { [weak self] in
            await self?.handleInboundStreams(connection: muxedConnection)
            await self?.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        // Emit events (guarded: only fires for first connection to this peer)
        await onPeerConnected(remotePeer, address: address, isLimited: isLimited)
        emitConnectionEvent(.connected(peer: remotePeer, address: address, direction: .outbound))

        // Start health monitoring
        await healthMonitor?.startMonitoring(peer: remotePeer)

        return remotePeer
    }

    /// Connects to a peer using known addresses and traversal orchestration.
    ///
    /// - Parameter peer: The peer to connect to.
    /// - Returns: The connected peer ID.
    @discardableResult
    public func connect(to peer: PeerID) async throws -> PeerID {
        // Already connected?
        if pool.isConnected(to: peer) { return peer }

        // Collect addresses from address book.
        // Relay addresses for the remote peer are included if they were
        // learned via Identify (stored in the address book with /p2p-circuit).
        let addresses = await _addressBook.sortedAddresses(for: peer)

        // Use traversal coordinator if configured
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

        // Fallback: sequential dial
        var lastError: any Error = NodeError.noSuitableTransport
        for addr in addresses {
            do {
                return try await connect(to: addr)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Returns whether the connection to a peer is limited (relay).
    ///
    /// - Parameter peer: The peer to check.
    /// - Returns: true if the connection is limited.
    public func isLimitedConnection(to peer: PeerID) -> Bool {
        pool.isLimitedConnection(to: peer)
    }

    /// Disconnects from a peer.
    ///
    /// - Parameter peer: The peer to disconnect from
    public func disconnect(from peer: PeerID) async {
        // Disable auto-reconnect
        pool.disableAutoReconnect(for: peer)

        // Stop health monitoring
        await healthMonitor?.stopMonitoring(peer: peer)

        // Remove and close connection
        let removed = pool.remove(forPeer: peer)
        for managed in removed {
            if let connection = managed.connection {
                await runBestEffort("close removed connection during disconnect") {
                    try await connection.close()
                }
            }
            // Release connection resource only for entries with active reservations.
            // Entries in .disconnected/.failed were already released by handleConnectionClosed.
            if managed.state.isConnected {
                configuration.resourceManager?.releaseConnection(peer: peer, direction: managed.direction)
            }
        }

        if !removed.isEmpty {
            await onPeerDisconnected(peer)
            emitConnectionEvent(.disconnected(peer: peer, reason: .localClose))
        }
    }

    /// Opens a stream to a peer with the given protocol.
    ///
    /// - Parameters:
    ///   - peer: The peer to open a stream to
    ///   - protocolID: The protocol to negotiate
    /// - Returns: The negotiated stream
    public func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        // connection(to:) atomically retrieves and records activity
        guard let connection = pool.connection(to: peer) else {
            throw NodeError.notConnected(peer)
        }

        // Reserve outbound stream resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveOutboundStream(to: peer)
            } catch let error as ResourceError {
                switch error {
                case .limitExceeded(let scope, let resource):
                    throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                }
            }
        }

        let stream: MuxedStream
        do {
            stream = try await connection.newStream()
        } catch {
            // Release on failure
            configuration.resourceManager?.releaseStream(peer: peer, direction: .outbound)
            throw error
        }

        // Negotiate protocol using multistream-select
        let reader = BufferedStreamReader(stream: stream)
        let result: NegotiationResult
        do {
            result = try await MultistreamSelect.negotiate(
                protocols: [protocolID],
                read: { try await reader.readMessage() },
                write: { try await stream.write(ByteBuffer(bytes: $0)) }
            )
        } catch {
            configuration.resourceManager?.releaseStream(peer: peer, direction: .outbound)
            await runBestEffort("close outbound stream after protocol negotiation failure") {
                try await stream.close()
            }
            throw error
        }

        if result.protocolID != protocolID {
            configuration.resourceManager?.releaseStream(peer: peer, direction: .outbound)
            await runBestEffort("close outbound stream after protocol mismatch") {
                try await stream.close()
            }
            throw NodeError.protocolNegotiationFailed
        }

        // Preserve bytes that were read ahead during protocol negotiation.
        let bufferedRemainder = reader.drainRemainder()
        let negotiationRemainder = result.remainder + bufferedRemainder
        let negotiatedStream: MuxedStream
        if negotiationRemainder.isEmpty {
            negotiatedStream = stream
        } else {
            negotiatedStream = BufferedMuxedStream(stream: stream, initialBuffer: negotiationRemainder)
        }

        // Wrap stream with resource tracking if resource manager is configured
        if let rm = configuration.resourceManager {
            return ResourceTrackedStream(
                stream: negotiatedStream,
                peer: peer,
                direction: .outbound,
                resourceManager: rm
            )
        }
        return negotiatedStream
    }

    /// Returns the connection to a peer if connected.
    public func connection(to peer: PeerID) -> MuxedConnection? {
        pool.connection(to: peer)
    }

    /// Returns the connection state for a peer.
    public func connectionState(of peer: PeerID) -> ConnectionState? {
        pool.connectionState(of: peer)
    }

    /// Returns all connected peers.
    public var connectedPeers: [PeerID] {
        pool.connectedPeers
    }

    /// Returns the actual listen addresses from active listeners.
    public var listenAddresses: [Multiaddr] {
        listeners.map(\.localAddress) + securedListeners.map(\.localAddress)
    }

    /// Returns the resolved addresses suitable for external advertisement.
    ///
    /// Unspecified addresses (0.0.0.0, ::) are resolved to actual interface IPs.
    /// Only includes addresses where the listener bound successfully.
    public nonisolated var advertisedAddresses: [Multiaddr] {
        _advertisedAddresses.current
    }

    /// Returns the number of active connections.
    public var connectionCount: Int {
        pool.connectionCount
    }

    /// Returns a point-in-time report of connection trim decisions.
    ///
    /// Useful for diagnostics when tuning pool limits.
    public func connectionTrimReport() -> ConnectionTrimReport {
        pool.trimReport()
    }

    // MARK: - Tagging & Protection

    /// Adds a tag to a peer's connections.
    ///
    /// Tags affect trim priority - more tags = less likely to be trimmed.
    ///
    /// - Parameters:
    ///   - peer: The peer to tag
    ///   - tag: The tag to add
    public func tag(_ peer: PeerID, with tag: String) {
        pool.tag(peer, with: tag)
    }

    /// Removes a tag from a peer's connections.
    ///
    /// - Parameters:
    ///   - peer: The peer to untag
    ///   - tag: The tag to remove
    public func untag(_ peer: PeerID, tag: String) {
        pool.untag(peer, tag: tag)
    }

    /// Protects a peer's connections from trimming.
    ///
    /// Protected connections will not be trimmed regardless of limits.
    ///
    /// - Parameter peer: The peer to protect
    public func protect(_ peer: PeerID) {
        pool.protect(peer)
    }

    /// Removes protection from a peer's connections.
    ///
    /// - Parameter peer: The peer to unprotect
    public func unprotect(_ peer: PeerID) {
        pool.unprotect(peer)
    }

    // MARK: - Address Resolution

    /// Resolves unspecified addresses (0.0.0.0 / ::) to actual network interface IPs.
    ///
    /// For each bound address:
    /// - If the IP is unspecified (0.0.0.0 or ::), expand it to all matching interface addresses
    /// - If the IP is already specific, keep it as-is
    ///
    /// This implements the equivalent of go-libp2p's `manet.ResolveUnspecifiedAddress`.
    static func resolveUnspecifiedAddresses(_ boundAddresses: [Multiaddr]) -> [Multiaddr] {
        var result: [Multiaddr] = []
        let interfaceIPs = getInterfaceAddresses()

        for addr in boundAddresses {
            guard addr.isUnspecifiedIP else {
                result.append(addr)
                continue
            }

            // Determine if we need IPv4 or IPv6 interfaces
            let isIPv6 = addr.protocols.contains { if case .ip6 = $0 { return true }; return false }

            let matchingIPs = interfaceIPs.filter { ip in
                if isIPv6 {
                    return ip.contains(":")
                } else {
                    return !ip.contains(":")
                }
            }

            for ip in matchingIPs {
                result.append(addr.replacingIPAddress(ip))
            }
        }

        return result
    }

    /// Returns all non-loopback IPv4 and loopback addresses from network interfaces.
    private static func getInterfaceAddresses() -> [String] {
        var addresses: [String] = []
        var hasNonLoopback = false

        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let firstAddr = ifaddrs else {
            return ["127.0.0.1"]
        }
        defer { freeifaddrs(firstAddr) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = current {
            let interface = addr.pointee
            let family = interface.ifa_addr.pointee.sa_family

            if family == sa_family_t(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                #if canImport(Darwin)
                let addrLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                #else
                let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif
                getnameinfo(
                    interface.ifa_addr, addrLen,
                    &hostname, socklen_t(hostname.count),
                    nil, 0, NI_NUMERICHOST
                )
                let ip: String = hostname.withUnsafeBufferPointer { buf in
                    let len = buf.firstIndex(of: 0) ?? buf.count
                    return String(decoding: buf[..<len].lazy.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }

                // Include loopback and non-loopback
                if ip == "127.0.0.1" {
                    addresses.append(ip)
                } else if !ip.isEmpty {
                    // Non-loopback addresses go first
                    addresses.insert(ip, at: hasNonLoopback ? 1 : 0)
                    hasNonLoopback = true
                }
            }

            current = interface.ifa_next
        }

        if addresses.isEmpty {
            addresses.append("127.0.0.1")
        }
        return addresses
    }

    // MARK: - Private Helpers

    private func emit(_ event: NodeEvent) {
        eventContinuation?.yield(event)
    }

    private func emitConnectionEvent(_ event: ConnectionEvent) {
        eventContinuation?.yield(.connection(event))
    }

    private func setupDiscoveryIntegration(_ discovery: any DiscoveryService) async throws {
        if let registrable = discovery as? any NodeDiscoveryHandlerRegistrable {
            await registrable.registerHandler(registry: self)
        }
        if let startableWithOpener = discovery as? any NodeDiscoveryStartableWithOpener {
            await startableWithOpener.start(using: self)
        } else if let startable = discovery as? any NodeDiscoveryStartable {
            try await startable.start()
        }
    }

    private func onPeerConnected(_ peer: PeerID, address: Multiaddr? = nil, isLimited: Bool = false) async {
        // Only emit peerConnected once per unique peer.
        // Subsequent connections to the same peer (e.g., simultaneous connect)
        // are resolved by resolveSimultaneousConnect without re-emitting.
        guard !peerConnectedEmitted.contains(peer) else { return }
        peerConnectedEmitted.insert(peer)

        emit(.peerConnected(peer))
        configuration.identifyService?.peerConnected(peer)
        await attachDiscoveryStreamIfNeeded(for: peer)
        _ = address
        _ = isLimited
    }

    private func onPeerDisconnected(_ peer: PeerID) async {
        // Only emit peerDisconnected when no connections remain for this peer.
        // If another connection is still active (e.g., after closing a duplicate),
        // the peer is still connected and we should not emit.
        guard !pool.isConnected(to: peer) else { return }
        peerConnectedEmitted.remove(peer)

        emit(.peerDisconnected(peer))
        configuration.identifyService?.peerDisconnected(peer)
        await detachDiscoveryStreamIfNeeded(for: peer)
    }

    /// Resolves simultaneous connect by closing the duplicate connection.
    ///
    /// When two peers dial each other at the same time, both connections succeed
    /// and the pool ends up with two entries. This method deterministically
    /// closes one based on PeerID comparison (go-libp2p compatible):
    /// the peer with the smaller PeerID keeps its outbound (initiator) connection.
    private func resolveSimultaneousConnect(for peer: PeerID) async {
        let connections = pool.connectedManagedConnections(for: peer)
        guard connections.count >= 2 else { return }

        let localPeerID = configuration.keyPair.peerID
        // Peer with smaller ID should be the initiator (outbound).
        let winningDirection: ConnectionDirection = localPeerID < peer ? .outbound : .inbound

        // Separate winners and losers
        var winner: ManagedConnection?
        var losers: [ManagedConnection] = []

        for conn in connections {
            if conn.direction == winningDirection && winner == nil {
                winner = conn
            } else {
                losers.append(conn)
            }
        }

        // If no clear winner (all same direction), keep the oldest
        if winner == nil, !losers.isEmpty {
            losers.sort { ($0.connectedAt ?? .now) < ($1.connectedAt ?? .now) }
            _ = losers.removeFirst() // oldest becomes de facto winner
        }

        // Close and remove losers
        for loser in losers {
            _ = pool.remove(loser.id)
            if let conn = loser.connection {
                await runBestEffort("close duplicate connection in simultaneous connect resolution") {
                    try await conn.close()
                }
            }
        }
    }

    private func attachDiscoveryStreamIfNeeded(for peer: PeerID) async {
        guard let discovery = configuration.discovery as? any NodeDiscoveryPeerStreamService else {
            return
        }
        guard !discoveryAttachedPeers.contains(peer) else {
            return
        }
        discoveryAttachedPeers.insert(peer)

        do {
            let stream = try await newStream(to: peer, protocol: discovery.discoveryProtocolID)
            await discovery.handlePeerConnected(peer, stream: stream)
        } catch {
            discoveryAttachedPeers.remove(peer)
            logger.debug("Discovery stream setup failed for \(peer): \(error)")
        }
    }

    private func detachDiscoveryStreamIfNeeded(for peer: PeerID) async {
        guard discoveryAttachedPeers.remove(peer) != nil else {
            return
        }
        guard let discovery = configuration.discovery as? any NodeDiscoveryPeerStreamService else {
            return
        }
        await discovery.handlePeerDisconnected(peer)
    }

    /// Checks if an address is a circuit relay address.
    private static func isCircuitRelayAddress(_ addr: Multiaddr) -> Bool {
        addr.protocols.contains { if case .p2pCircuit = $0 { return true }; return false }
    }

    private func handleConnectionClosed(id: ConnectionID, peer: PeerID) async {
        // If the entry was already removed (e.g., by resolveSimultaneousConnect),
        // there is nothing to do.
        guard let managed = pool.managedConnection(id) else { return }
        let wasConnected = managed.state.isConnected

        // Don't overwrite reconnecting state - let the reconnection logic handle it
        if case .reconnecting = managed.state {
            return
        }

        // Release connection resource
        configuration.resourceManager?.releaseConnection(peer: peer, direction: managed.direction)

        // Update state
        pool.updateState(id, to: .disconnected(reason: .remoteClose))

        // Only emit disconnect, stop health monitoring, and trigger reconnection
        // when this is the last connection to the peer.
        if wasConnected && !pool.isConnected(to: peer) {
            await healthMonitor?.stopMonitoring(peer: peer)
            await onPeerDisconnected(peer)
            emitConnectionEvent(.disconnected(peer: peer, reason: .remoteClose))

            // Reset retry count if connection was stable (prevents retry accumulation
            // from transient disconnections after long-lived connections)
            pool.resetRetryCountIfStable(id)

            // Check if we should reconnect.
            // Only the peer with the smaller PeerID initiates reconnection.
            // This prevents both sides from reconnecting simultaneously,
            // which would create duplicate connections and trigger
            // simultaneous connect resolution in a loop.
            // The larger PeerID side relies on Discovery auto-connect
            // (with DialBackoff) as a fallback.
            let localPeerID = configuration.keyPair.peerID
            if let address = pool.reconnectAddress(for: peer), localPeerID < peer {
                let retryCount = pool.managedConnection(id)?.retryCount ?? 0
                let policy = configuration.pool.reconnectionPolicy

                if policy.shouldReconnect(attempt: retryCount, reason: .remoteClose) {
                    await scheduleReconnect(id: id, peer: peer, address: address, attempt: retryCount + 1)
                } else if retryCount >= policy.maxRetries {
                    pool.updateState(id, to: .failed(reason: .remoteClose))
                    emitConnectionEvent(.reconnectionFailed(peer: peer, attempts: retryCount))
                }
            }
        }
    }

    private func scheduleReconnect(id: ConnectionID, peer: PeerID, address: Multiaddr, attempt: Int) async {
        let delay = configuration.pool.reconnectionPolicy.delay(for: attempt - 1)
        let nextAttempt = ContinuousClock.now + delay

        pool.updateState(id, to: .reconnecting(attempt: attempt, nextAttempt: nextAttempt))
        pool.incrementRetryCount(id)
        emitConnectionEvent(.reconnecting(peer: peer, attempt: attempt, nextDelay: delay))

        Task { [weak self] in
            let slept = await sleepUnlessCancelled(
                for: delay,
                context: "reconnect backoff for peer \(peer)"
            )
            guard slept else { return }
            await self?.performReconnect(id: id, peer: peer, address: address, attempt: attempt)
        }
    }

    private func performReconnect(id: ConnectionID, peer: PeerID, address: Multiaddr, attempt: Int) async {
        guard isRunning else { return }
        guard pool.reconnectAddress(for: peer) != nil else { return }

        // Skip if already connected (another path may have succeeded)
        guard !pool.isConnected(to: peer) else { return }

        do {
            guard let transport = configuration.transports.first(where: { $0.canDial(address) }) else {
                throw NodeError.noSuitableTransport
            }

            // SecuredTransport (e.g., QUIC) bypasses the upgrade pipeline
            if let securedTransport = transport as? SecuredTransport {
                let muxedConnection = try await securedTransport.dialSecured(
                    address,
                    localKeyPair: configuration.keyPair
                )

                let remotePeer = muxedConnection.remotePeer

                guard remotePeer == peer else {
                    await runBestEffort("close reconnected secured connection after peer mismatch") {
                        try await muxedConnection.close()
                    }
                    throw NodeError.notConnected(peer)
                }

                if let gater = configuration.pool.gater {
                    if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                        await runBestEffort("close reconnected secured connection rejected by secured gater") {
                            try await muxedConnection.close()
                        }
                        emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                        throw NodeError.connectionGated(stage: .secured)
                    }
                }

                // Reserve outbound connection resource for the reconnected connection
                if let rm = configuration.resourceManager {
                    do {
                        try rm.reserveOutboundConnection(to: peer)
                    } catch let error as ResourceError {
                        await runBestEffort("close reconnected secured connection after outbound resource reservation failure") {
                            try await muxedConnection.close()
                        }
                        switch error {
                        case .limitExceeded(let scope, let resource):
                            throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                        }
                    }
                }

                pool.updateConnection(id, connection: muxedConnection)
                pool.resetRetryCount(id)

                // Clear dial backoff on successful reconnection
                dialBackoff.recordSuccess(for: remotePeer)

                // Resolve simultaneous connect before emitting events.
                await resolveSimultaneousConnect(for: remotePeer)

                // Start handling inbound streams BEFORE onPeerConnected.
                Task { [weak self] in
                    await self?.handleInboundStreams(connection: muxedConnection)
                    await self?.handleConnectionClosed(id: id, peer: remotePeer)
                }

                let isRelay = transport.pathKind == .relay
                await onPeerConnected(remotePeer, address: address, isLimited: isRelay)
                emitConnectionEvent(.reconnected(peer: peer, attempt: attempt))

                await healthMonitor?.startMonitoring(peer: remotePeer)
                return
            }

            // Standard transport: dial then upgrade
            let rawConnection = try await transport.dial(address)

            let result: UpgradeResult
            do {
                result = try await upgrader.upgrade(
                    rawConnection,
                    localKeyPair: configuration.keyPair,
                    role: .initiator,
                    expectedPeer: peer
                )
            } catch {
                await runBestEffort("close raw connection after reconnect upgrade failure") {
                    try await rawConnection.close()
                }
                throw error
            }

            let remotePeer = result.connection.remotePeer

            // Verify it's the same peer
            guard remotePeer == peer else {
                await runBestEffort("close reconnected upgraded connection after peer mismatch") {
                    try await result.connection.close()
                }
                throw NodeError.notConnected(peer)
            }

            // Gating check (secured)
            if let gater = configuration.pool.gater {
                if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                    await runBestEffort("close reconnected upgraded connection rejected by secured gater") {
                        try await result.connection.close()
                    }
                    emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                    throw NodeError.connectionGated(stage: .secured)
                }
            }

            // Reserve outbound connection resource for the reconnected connection
            if let rm = configuration.resourceManager {
                do {
                    try rm.reserveOutboundConnection(to: peer)
                } catch let error as ResourceError {
                    await runBestEffort("close reconnected upgraded connection after outbound resource reservation failure") {
                        try await result.connection.close()
                    }
                    switch error {
                    case .limitExceeded(let scope, let resource):
                        throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                    }
                }
            }

            // Update existing entry instead of creating new one
            pool.updateConnection(id, connection: result.connection)
            pool.resetRetryCount(id)

            // Clear dial backoff on successful reconnection
            dialBackoff.recordSuccess(for: remotePeer)

            // Resolve simultaneous connect before emitting events.
            await resolveSimultaneousConnect(for: remotePeer)

            // Start handling inbound streams BEFORE onPeerConnected.
            Task { [weak self] in
                await self?.handleInboundStreams(connection: result.connection)
                await self?.handleConnectionClosed(id: id, peer: remotePeer)
            }

            // Emit events
            let isRelay = transport.pathKind == .relay
            await onPeerConnected(remotePeer, address: address, isLimited: isRelay)
            emitConnectionEvent(.reconnected(peer: peer, attempt: attempt))

            // Start health monitoring
            await healthMonitor?.startMonitoring(peer: remotePeer)

        } catch {
            // Record failure in centralized backoff
            dialBackoff.recordFailure(for: peer)

            // Classify the error for reconnection decisions
            let errorCode: DisconnectErrorCode = if error is NegotiationError {
                .protocolError
            } else {
                .transportError
            }
            let reason: DisconnectReason = .error(code: errorCode, message: error.localizedDescription)

            // Check if we should retry again
            let retryCount = pool.managedConnection(id)?.retryCount ?? attempt
            let policy = configuration.pool.reconnectionPolicy

            if policy.shouldReconnect(attempt: retryCount, reason: reason) {
                await scheduleReconnect(id: id, peer: peer, address: address, attempt: retryCount + 1)
            } else {
                pool.updateState(id, to: .failed(reason: reason))
                emitConnectionEvent(.reconnectionFailed(peer: peer, attempts: retryCount))
            }
        }
    }

    private func handleHealthCheckFailed(peer: PeerID) async {
        emitConnectionEvent(.healthCheckFailed(peer: peer))

        // Disconnect the unhealthy peer
        await disconnect(from: peer)
    }

    private func startIdleCheckTask() {
        let idleTimeout = configuration.pool.idleTimeout
        guard idleTimeout > .zero else { return }

        idleCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                let slept = await sleepUnlessCancelled(
                    for: idleTimeout / 2,
                    context: "idle check interval"
                )
                guard slept else { break }
                await self?.performIdleCheck()
            }
        }
    }

    private func startDiscoveryTask(discovery: any DiscoveryService) {
        let config = configuration.discoveryConfig
        let localPeerID = configuration.keyPair.peerID

        discoveryTask = Task { [weak self, localPeerID] in
            // Process initial known peers
            let peers = await discovery.knownPeers()
            for peer in peers {
                guard !Task.isCancelled else { return }
                guard peer != localPeerID else { continue }
                await self?.tryAutoConnect(to: peer, hints: [], config: config)
            }

            // Then reactively listen to discovery observations
            for await observation in discovery.observations {
                guard !Task.isCancelled else { return }
                guard let self = self else { return }

                // Skip observations about ourselves
                guard observation.subject != localPeerID else { continue }

                // Check connection limits
                let connectionCount = await self.connectionCount
                guard connectionCount < config.maxAutoConnectPeers else { continue }

                switch observation.kind {
                case .announcement, .reachable:
                    // Store addresses in peer store
                    await self._peerStore.addObservation(observation)

                    // Try to auto-connect
                    await self.tryAutoConnect(
                        to: observation.subject,
                        hints: observation.hints,
                        config: config
                    )

                case .unreachable:
                    // Optionally disconnect unreachable peers
                    // For now, just let the health monitor handle it
                    break
                }
            }
        }
    }

    private func tryAutoConnect(
        to peer: PeerID,
        hints: [Multiaddr],
        config: DiscoveryConfiguration
    ) async {
        // Centralized dial backoff — prevents rapid retries after failures
        guard !dialBackoff.shouldBackOff(from: peer) else { return }

        // Already connected?
        guard !pool.isConnected(to: peer) else { return }

        // Defer to ReconnectionPolicy if it's already handling this peer
        guard !pool.hasReconnecting(for: peer) else { return }

        // Already dialing?
        guard !pool.hasPendingDial(to: peer) else { return }

        // Add hints to peer store if provided
        if !hints.isEmpty {
            await _peerStore.addAddresses(hints, for: peer)
        }

        // Get best address from address book
        guard let address = await _addressBook.bestAddress(for: peer) else {
            return
        }

        // Try to connect
        do {
            try await connect(to: address)
            // Record success (also recorded in performDial, but belt-and-suspenders)
            await _addressBook.recordSuccess(address: address, for: peer)
        } catch {
            // Record failure in centralized backoff
            dialBackoff.recordFailure(for: peer)
            await _addressBook.recordFailure(address: address, for: peer)
        }
    }

    private func performIdleCheck() async {
        let idleTimeout = configuration.pool.idleTimeout

        // 1. Close idle connections
        let idleConnections = pool.idleConnections(threshold: idleTimeout)
        for managed in idleConnections {
            configuration.resourceManager?.releaseConnection(peer: managed.peer, direction: managed.direction)
            if let connection = managed.connection {
                await runBestEffort("close idle connection during idle check") {
                    try await connection.close()
                }
            }
            _ = pool.remove(managed.id)
            // Only emit disconnect when this was the last connection to the peer
            if !pool.isConnected(to: managed.peer) {
                await onPeerDisconnected(managed.peer)
                emitConnectionEvent(.disconnected(peer: managed.peer, reason: .idleTimeout))
            }
        }

        // 2. Trim if over limits
        let trimReport = pool.trimReport()
        if trimReport.requiresTrim && trimReport.selectedCount < trimReport.targetTrimCount {
            emitConnectionEvent(
                .trimConstrained(
                    target: trimReport.targetTrimCount,
                    selected: trimReport.selectedCount,
                    trimmable: trimReport.trimmableCount,
                    active: trimReport.activeConnectionCount
                )
            )
            logger.warning(
                """
                Connection trim constrained: target=\(trimReport.targetTrimCount), \
                selected=\(trimReport.selectedCount), trimmable=\(trimReport.trimmableCount), \
                active=\(trimReport.activeConnectionCount)
                """
            )
        }
        let trimContextsByID: [ConnectionID: ConnectionTrimmedContext] = Dictionary(
            uniqueKeysWithValues: trimReport.candidates.compactMap { candidate -> (ConnectionID, ConnectionTrimmedContext)? in
                guard candidate.selectedForTrim else { return nil }
                return (candidate.id, Self.trimContext(for: candidate))
            }
        )

        let trimmed = pool.trimIfNeeded()
        for managed in trimmed {
            configuration.resourceManager?.releaseConnection(peer: managed.peer, direction: managed.direction)
            if let connection = managed.connection {
                await runBestEffort("close trimmed connection during idle check") {
                    try await connection.close()
                }
            }
            // Only emit disconnect when this was the last connection to the peer
            if !pool.isConnected(to: managed.peer) {
                await onPeerDisconnected(managed.peer)
                if let context = trimContextsByID[managed.id] {
                    emitConnectionEvent(.trimmedWithContext(peer: managed.peer, context: context))
                } else {
                    emitConnectionEvent(.trimmed(peer: managed.peer, reason: "Connection limit exceeded"))
                }
            }
        }

        // 3. Cleanup stale entries (failed, old disconnected)
        _ = pool.cleanupStaleEntries(disconnectedThreshold: idleTimeout)

        // 4. Cleanup expired dial backoff entries
        dialBackoff.cleanup()
    }

    private static func trimContext(for candidate: ConnectionTrimReport.Candidate) -> ConnectionTrimmedContext {
        ConnectionTrimmedContext(
            rank: candidate.trimRank,
            tagCount: candidate.tagCount,
            idleDuration: candidate.idleDuration,
            direction: candidate.direction
        )
    }

    private func acceptLoop(listener: any Listener, address: Multiaddr) async {
        while isRunning && !Task.isCancelled {
            do {
                let rawConnection = try await listener.accept()

                Task { [weak self] in
                    await self?.handleInboundConnection(rawConnection)
                }
            } catch {
                if isRunning && !Task.isCancelled {
                    emit(.listenError(address, error))
                    continue
                }
                break
            }
        }
    }

    private func handleInboundConnection(_ rawConnection: any RawConnection) async {
        // Gating check (accept)
        if let gater = configuration.pool.gater {
            let remoteAddress = rawConnection.remoteAddress
            if !gater.interceptAccept(address: remoteAddress) {
                await runBestEffort("close inbound raw connection rejected by accept gater") {
                    try await rawConnection.close()
                }
                emitConnectionEvent(.gated(peer: nil, address: remoteAddress, stage: .accept))
                return
            }
        }

        // Check inbound limits
        if !pool.canAcceptInbound() {
            await runBestEffort("close inbound raw connection rejected by inbound limit") {
                try await rawConnection.close()
            }
            return
        }

        do {
            // Upgrade connection (security + muxer negotiation)
            let result: UpgradeResult
            do {
                result = try await upgrader.upgrade(
                    rawConnection,
                    localKeyPair: configuration.keyPair,
                    role: .responder,
                    expectedPeer: nil
                )
            } catch {
                await runBestEffort("close inbound raw connection after upgrade failure") {
                    try await rawConnection.close()
                }
                throw error
            }

            let remotePeer = result.connection.remotePeer
            let remoteAddress = result.connection.remoteAddress

            // Self-connection guard (inbound)
            if remotePeer == configuration.keyPair.peerID {
                await runBestEffort("close inbound self-connection") {
                    try await result.connection.close()
                }
                return
            }

            // Gating check (secured)
            if let gater = configuration.pool.gater {
                if !gater.interceptSecured(peer: remotePeer, direction: .inbound) {
                    await runBestEffort("close inbound upgraded connection rejected by secured gater") {
                        try await result.connection.close()
                    }
                    emitConnectionEvent(.gated(peer: remotePeer, address: remoteAddress, stage: .secured))
                    return
                }
            }

            // Check per-peer limit
            if !pool.canConnectTo(peer: remotePeer) {
                await runBestEffort("close inbound upgraded connection rejected by per-peer limit") {
                    try await result.connection.close()
                }
                return
            }

            // Reserve inbound connection resource
            if let rm = configuration.resourceManager {
                do {
                    try rm.reserveInboundConnection(from: remotePeer)
                } catch {
                    await runBestEffort("close inbound upgraded connection after inbound resource reservation failure") {
                        try await result.connection.close()
                    }
                    return
                }
            }

            // Add to pool
            let isRelay = Self.isCircuitRelayAddress(remoteAddress)
            let connID = pool.add(
                result.connection,
                for: remotePeer,
                address: remoteAddress,
                direction: .inbound,
                isLimited: isRelay
            )

            // Clear dial backoff — peer is reachable (inbound proves connectivity)
            dialBackoff.recordSuccess(for: remotePeer)

            // Resolve simultaneous connect before emitting events.
            await resolveSimultaneousConnect(for: remotePeer)

            // Start handling inbound streams BEFORE onPeerConnected.
            // onPeerConnected may open new streams (e.g., discovery), which require
            // the inbound handler to be running for protocol negotiation.
            Task { [weak self] in
                await self?.handleInboundStreams(connection: result.connection)
                await self?.handleConnectionClosed(id: connID, peer: remotePeer)
            }

            // Emit events (guarded: only fires for first connection to this peer)
            await onPeerConnected(remotePeer, address: remoteAddress, isLimited: isRelay)
            emitConnectionEvent(.connected(peer: remotePeer, address: remoteAddress, direction: .inbound))

            // Start health monitoring
            await healthMonitor?.startMonitoring(peer: remotePeer)
        } catch {
            emit(.connectionError(nil, error))
        }
    }

    /// Accept loop for SecuredListener (e.g., QUIC).
    ///
    /// SecuredListener yields pre-secured, pre-multiplexed connections.
    private func securedAcceptLoop(listener: any SecuredListener, address: Multiaddr) async {
        for await muxedConnection in listener.connections {
            guard isRunning && !Task.isCancelled else { break }
            Task { [weak self] in
                await self?.handleSecuredInboundConnection(muxedConnection, from: address)
            }
        }
    }

    /// Handles inbound connection from SecuredListener (e.g., QUIC).
    ///
    /// The connection is already secured and multiplexed.
    private func handleSecuredInboundConnection(
        _ muxedConnection: any MuxedConnection,
        from address: Multiaddr
    ) async {
        let remotePeer = muxedConnection.remotePeer
        let remoteAddress = muxedConnection.remoteAddress

        // Gating check (accept stage)
        if let gater = configuration.pool.gater {
            if !gater.interceptAccept(address: remoteAddress) {
                await runBestEffort("close secured inbound connection rejected by accept gater") {
                    try await muxedConnection.close()
                }
                emitConnectionEvent(.gated(peer: nil, address: remoteAddress, stage: .accept))
                return
            }
        }

        // Check inbound limits
        if !pool.canAcceptInbound() {
            await runBestEffort("close secured inbound connection rejected by inbound limit") {
                try await muxedConnection.close()
            }
            return
        }

        // Self-connection guard (secured inbound)
        if remotePeer == configuration.keyPair.peerID {
            await runBestEffort("close secured inbound self-connection") {
                try await muxedConnection.close()
            }
            return
        }

        // Gating check (secured stage)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .inbound) {
                await runBestEffort("close secured inbound connection rejected by secured gater") {
                    try await muxedConnection.close()
                }
                emitConnectionEvent(.gated(peer: remotePeer, address: remoteAddress, stage: .secured))
                return
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            await runBestEffort("close secured inbound connection rejected by per-peer limit") {
                try await muxedConnection.close()
            }
            return
        }

        // Reserve inbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveInboundConnection(from: remotePeer)
            } catch {
                await runBestEffort("close secured inbound connection after inbound resource reservation failure") {
                    try await muxedConnection.close()
                }
                return
            }
        }

        // Add to pool
        let isRelay = Self.isCircuitRelayAddress(remoteAddress)
        let connID = pool.add(
            muxedConnection,
            for: remotePeer,
            address: remoteAddress,
            direction: .inbound,
            isLimited: isRelay
        )

        // Clear dial backoff — peer is reachable (inbound proves connectivity)
        dialBackoff.recordSuccess(for: remotePeer)

        // Resolve simultaneous connect before emitting events.
        await resolveSimultaneousConnect(for: remotePeer)

        // Start handling inbound streams BEFORE onPeerConnected.
        Task { [weak self] in
            await self?.handleInboundStreams(connection: muxedConnection)
            await self?.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        // Emit events (guarded: only fires for first connection to this peer)
        await onPeerConnected(remotePeer, address: remoteAddress, isLimited: isRelay)
        emitConnectionEvent(.connected(peer: remotePeer, address: remoteAddress, direction: .inbound))

        // Start health monitoring
        await healthMonitor?.startMonitoring(peer: remotePeer)
    }

    private func handleInboundStreams(connection: MuxedConnection) async {
        let supportedProtocols = Array(handlers.keys)
        let localPeer = configuration.keyPair.peerID
        let rm = configuration.resourceManager

        for await stream in connection.inboundStreams {
            let capturedHandlers = handlers

            // Capture connection info for the context
            let remotePeer = connection.remotePeer
            let remoteAddress = connection.remoteAddress
            let localAddress = connection.localAddress

            Task {
                // Reserve inbound stream resource
                if let rm = rm {
                    do {
                        try rm.reserveInboundStream(from: remotePeer)
                    } catch {
                        await runBestEffort("close inbound stream after inbound stream resource reservation failure") {
                            try await stream.close()
                        }
                        return
                    }
                }

                defer {
                    // Release inbound stream resource when handler completes
                    rm?.releaseStream(peer: remotePeer, direction: .inbound)
                }

                do {
                    // Negotiate protocol using multistream-select
                    let reader = BufferedStreamReader(stream: stream)
                    let result = try await MultistreamSelect.handle(
                        supported: supportedProtocols,
                        read: { try await reader.readMessage() },
                        write: { try await stream.write(ByteBuffer(bytes: $0)) }
                    )

                    // Preserve bytes read ahead during protocol negotiation for handler consumption.
                    let bufferedRemainder = reader.drainRemainder()
                    let negotiationRemainder = result.remainder + bufferedRemainder
                    let negotiatedStream: MuxedStream
                    if negotiationRemainder.isEmpty {
                        negotiatedStream = stream
                    } else {
                        negotiatedStream = BufferedMuxedStream(stream: stream, initialBuffer: negotiationRemainder)
                    }

                    // Find and run the handler
                    if let handler = capturedHandlers[result.protocolID] {
                        let context = StreamContext(
                            stream: negotiatedStream,
                            remotePeer: remotePeer,
                            remoteAddress: remoteAddress,
                            localPeer: localPeer,
                            localAddress: localAddress
                        )
                        await handler(context)
                    } else {
                        await runBestEffort("close inbound stream for unsupported protocol") {
                            try await stream.close()
                        }
                    }
                } catch {
                    await runBestEffort("close inbound stream after handler failure") {
                        try await stream.close()
                    }
                }
            }
        }
    }
}

// MARK: - NodePingProvider

/// Internal adapter to make Node work with HealthMonitor.
private final class NodePingProvider: PingProvider, Sendable {
    private let nodeRef: Mutex<Node?>
    private let pingService: PingService

    init(node: Node) {
        self.nodeRef = Mutex(node)
        self.pingService = PingService()
    }

    func ping(_ peer: PeerID) async throws -> Duration {
        guard let node = nodeRef.withLock({ $0 }) else {
            throw NodeError.nodeNotRunning
        }

        let result = try await pingService.ping(peer, using: node)
        return result.rtt
    }
}

// MARK: - BufferedStreamReader

/// A stream wrapper that returns pre-buffered bytes before reading the underlying stream.
final class BufferedMuxedStream: MuxedStream, Sendable {
    private let stream: MuxedStream
    private let buffer: Mutex<ByteBuffer>

    var id: UInt64 { stream.id }
    var protocolID: String? { stream.protocolID }

    init(stream: MuxedStream, initialBuffer: Data = Data()) {
        self.stream = stream
        self.buffer = Mutex(ByteBuffer(bytes: initialBuffer))
    }

    func read() async throws -> ByteBuffer {
        let buffered = buffer.withLock { buffer -> ByteBuffer? in
            guard buffer.readableBytes > 0 else { return nil }
            let data = buffer
            buffer = ByteBuffer()
            return data
        }

        if let buffered {
            return buffered
        }
        return try await stream.read()
    }

    func write(_ data: ByteBuffer) async throws {
        try await stream.write(data)
    }

    func closeWrite() async throws {
        try await stream.closeWrite()
    }

    func closeRead() async throws {
        try await stream.closeRead()
    }

    func close() async throws {
        try await stream.close()
    }

    func reset() async throws {
        try await stream.reset()
    }
}

// MARK: - BufferedStreamReader

/// A helper class for reading length-prefixed messages from a stream.
///
/// This class is `Sendable` and can be safely used across actor boundaries.
final class BufferedStreamReader: Sendable {
    private let stream: MuxedStream
    private let state: Mutex<Data>
    private let maxMessageSize: Int

    /// Maximum buffer size to prevent DoS (default 64KB for multistream-select).
    static let defaultMaxMessageSize = 64 * 1024

    init(stream: MuxedStream, maxMessageSize: Int = defaultMaxMessageSize) {
        self.stream = stream
        self.state = Mutex(Data())
        self.maxMessageSize = maxMessageSize
    }

    /// Returns and clears any bytes buffered beyond consumed negotiation messages.
    func drainRemainder() -> Data {
        state.withLock { buffer in
            let data = buffer
            buffer.removeAll(keepingCapacity: false)
            return data
        }
    }

    /// Result of trying to extract a message from the buffer.
    private enum ExtractResult {
        case message(Data)
        case needMoreData
        case invalidData(Error)
    }

    /// Reads a complete length-prefixed message from the stream.
    func readMessage() async throws -> Data {
        while true {
            // Try to extract a message from the buffer
            let result: ExtractResult = state.withLock { buffer in
                guard !buffer.isEmpty else { return .needMoreData }

                do {
                    let (length, lengthBytes) = try Varint.decode(buffer)

                    // Check for oversized message (Int.max check prevents crash on conversion)
                    guard length <= UInt64(maxMessageSize) else {
                        return .invalidData(NodeError.messageTooLarge(size: Int(min(length, UInt64(Int.max))), max: maxMessageSize))
                    }
                    let messageLength = Int(length)

                    let totalNeeded = lengthBytes + messageLength

                    guard buffer.count >= totalNeeded else {
                        return .needMoreData
                    }

                    let message = Data(buffer.prefix(totalNeeded))
                    buffer = Data(buffer.dropFirst(totalNeeded))
                    return .message(message)
                } catch let error as VarintError {
                    switch error {
                    case .insufficientData:
                        return .needMoreData
                    case .overflow, .valueExceedsIntMax:
                        return .invalidData(error)
                    }
                } catch {
                    return .invalidData(error)
                }
            }

            switch result {
            case .message(let data):
                return data
            case .needMoreData:
                break
            case .invalidData(let error):
                throw error
            }

            // Check buffer size before reading more
            let currentSize = state.withLock { $0.count }
            if currentSize > maxMessageSize {
                throw NodeError.messageTooLarge(size: currentSize, max: maxMessageSize)
            }

            // Read more data from the stream
            let chunk = try await stream.read()
            if chunk.readableBytes == 0 {
                throw NodeError.streamClosed
            }

            state.withLock { buffer in
                buffer.append(Data(buffer: chunk))
            }
        }
    }
}

// MARK: - NodeError

public enum NodeError: Error, Sendable {
    case noSuitableTransport
    case notConnected(PeerID)
    case protocolNegotiationFailed
    case streamClosed
    case connectionLimitReached
    case connectionGated(stage: GateStage)
    case nodeNotRunning
    case messageTooLarge(size: Int, max: Int)
    case resourceLimitExceeded(scope: String, resource: String)
    case noAddressesKnown(PeerID)
    case selfDialNotAllowed
    case noListenersBound
}

// MARK: - NodeConnectionProvider

/// Internal adapter to make Node work with Bootstrap.
///
/// Implements BootstrapConnectionProvider to allow Bootstrap
/// to connect to peers through the Node.
private final class NodeConnectionProvider: BootstrapConnectionProvider, Sendable {
    nonisolated(unsafe) private weak var node: Node?

    init(node: Node) {
        self.node = node
    }

    func connect(to address: Multiaddr) async throws -> PeerID {
        guard let node = node else {
            throw NodeError.nodeNotRunning
        }
        return try await node.connect(to: address)
    }

    func connectedPeerCount() async -> Int {
        guard let node = node else { return 0 }
        return await node.connectionCount
    }

    func connectedPeers() async -> Set<PeerID> {
        guard let node = node else { return [] }
        return Set(await node.connectedPeers)
    }
}
