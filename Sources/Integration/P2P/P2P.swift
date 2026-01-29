/// P2P - Unified entry point for swift-libp2p
///
/// Provides a high-level API for building P2P applications.

import Foundation
import Synchronization
@_exported import P2PCore
@_exported import P2PTransport
@_exported import P2PSecurity
@_exported import P2PMux
@_exported import P2PNegotiation
@_exported import P2PDiscovery
@_exported import P2PProtocols
import P2PPing

/// Logger for P2P operations.
private let logger = Logger(label: "p2p.node")

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
        resourceManager: (any ResourceManager)? = nil
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

    // Auto-connect tracking
    private var autoConnectCooldowns: [PeerID: ContinuousClock.Instant] = [:]

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

        // Start idle check task
        startIdleCheckTask()

        // Start discovery auto-connect task (reactive via observations stream)
        if configuration.discoveryConfig.autoConnect, let discovery = configuration.discovery {
            startDiscoveryTask(discovery: discovery)
        }

        // Start listeners
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
                            Task { [weak self] in
                                await self?.securedAcceptLoop(listener: listener, address: listener.localAddress)
                            }
                        } else {
                            // Standard transport
                            let listener = try await transport.listen(address)
                            listeners.append(listener)

                            // Start accept loop
                            Task { [weak self] in
                                await self?.acceptLoop(listener: listener, address: address)
                            }
                        }
                    } catch {
                        emit(.listenError(address, error))
                    }
                }
            }
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

    /// Stops the node.
    public func stop() async {
        isRunning = false

        // Shutdown PeerStore if using MemoryPeerStore (stops GC + releases events)
        if let memoryStore = _peerStore as? MemoryPeerStore {
            memoryStore.shutdown()
        }

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
            emit(.peerDisconnected(peer))
        }

        // Clear auto-connect cooldowns
        autoConnectCooldowns.removeAll()

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

        // SecuredTransport (e.g., QUIC) bypasses the upgrade pipeline
        if let securedTransport = transport as? SecuredTransport {
            return try await performSecuredDial(to: address, using: securedTransport)
        }

        // Track connecting state if peer ID is known from address
        let connectingID: ConnectionID?
        if let peerID = address.peerID {
            connectingID = pool.addConnecting(for: peerID, address: address, direction: .outbound)
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
            try? await rawConnection.close()
            throw error
        }

        let remotePeer = result.connection.remotePeer

        // Gating check (secured)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                try? await result.connection.close()
                emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                throw NodeError.connectionGated(stage: .secured)
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            try? await result.connection.close()
            throw NodeError.connectionLimitReached
        }

        // Reserve outbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveOutboundConnection(to: remotePeer)
            } catch let error as ResourceError {
                try? await result.connection.close()
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
                direction: .outbound
            )
        }
        didConnect = true

        // Enable auto-reconnect if policy allows
        if configuration.pool.reconnectionPolicy.enabled {
            pool.enableAutoReconnect(for: remotePeer, address: address)
        }

        // Emit events
        emit(.peerConnected(remotePeer))
        emitConnectionEvent(.connected(peer: remotePeer, address: address, direction: .outbound))

        // Start health monitoring
        await healthMonitor?.startMonitoring(peer: remotePeer)

        // Start handling inbound streams
        Task { [weak self] in
            await self?.handleInboundStreams(connection: result.connection)
            await self?.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        return remotePeer
    }

    /// Performs dial operation for SecuredTransport (e.g., QUIC).
    ///
    /// SecuredTransport provides built-in security and multiplexing,
    /// so we bypass the standard upgrade pipeline and get a MuxedConnection directly.
    private func performSecuredDial(
        to address: Multiaddr,
        using transport: SecuredTransport
    ) async throws -> PeerID {
        // Track connecting state if peer ID is known from address
        let connectingID: ConnectionID?
        if let peerID = address.peerID {
            connectingID = pool.addConnecting(for: peerID, address: address, direction: .outbound)
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

        // Gating check (secured stage)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                try? await muxedConnection.close()
                emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                throw NodeError.connectionGated(stage: .secured)
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            try? await muxedConnection.close()
            throw NodeError.connectionLimitReached
        }

        // Reserve outbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveOutboundConnection(to: remotePeer)
            } catch let error as ResourceError {
                try? await muxedConnection.close()
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
                direction: .outbound
            )
        }
        didConnect = true

        // Enable auto-reconnect if policy allows
        if configuration.pool.reconnectionPolicy.enabled {
            pool.enableAutoReconnect(for: remotePeer, address: address)
        }

        // Emit events
        emit(.peerConnected(remotePeer))
        emitConnectionEvent(.connected(peer: remotePeer, address: address, direction: .outbound))

        // Start health monitoring
        await healthMonitor?.startMonitoring(peer: remotePeer)

        // Start handling inbound streams
        Task { [weak self] in
            await self?.handleInboundStreams(connection: muxedConnection)
            await self?.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        return remotePeer
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
            try? await managed.connection?.close()
            // Release connection resource only for entries with active reservations.
            // Entries in .disconnected/.failed were already released by handleConnectionClosed.
            if managed.state.isConnected {
                configuration.resourceManager?.releaseConnection(peer: peer, direction: managed.direction)
            }
        }

        if !removed.isEmpty {
            emit(.peerDisconnected(peer))
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
                write: { try await stream.write($0) }
            )
        } catch {
            configuration.resourceManager?.releaseStream(peer: peer, direction: .outbound)
            try? await stream.close()
            throw error
        }

        if result.protocolID != protocolID {
            configuration.resourceManager?.releaseStream(peer: peer, direction: .outbound)
            try? await stream.close()
            throw NodeError.protocolNegotiationFailed
        }

        // Wrap stream with resource tracking if resource manager is configured
        if let rm = configuration.resourceManager {
            return ResourceTrackedStream(
                stream: stream,
                peer: peer,
                direction: .outbound,
                resourceManager: rm
            )
        }
        return stream
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

    /// Returns the number of active connections.
    public var connectionCount: Int {
        pool.connectionCount
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

    // MARK: - Private Helpers

    private func emit(_ event: NodeEvent) {
        eventContinuation?.yield(event)
    }

    private func emitConnectionEvent(_ event: ConnectionEvent) {
        eventContinuation?.yield(.connection(event))
    }

    private func handleConnectionClosed(id: ConnectionID, peer: PeerID) async {
        let managed = pool.managedConnection(id)
        let wasConnected = managed?.state.isConnected ?? false

        // Don't overwrite reconnecting state - let the reconnection logic handle it
        if case .reconnecting = managed?.state {
            return
        }

        // Release connection resource
        if let direction = managed?.direction {
            configuration.resourceManager?.releaseConnection(peer: peer, direction: direction)
        }

        // Update state
        pool.updateState(id, to: .disconnected(reason: .remoteClose))

        // Stop health monitoring
        await healthMonitor?.stopMonitoring(peer: peer)

        if wasConnected {
            emit(.peerDisconnected(peer))
            emitConnectionEvent(.disconnected(peer: peer, reason: .remoteClose))

            // Reset retry count if connection was stable (prevents retry accumulation
            // from transient disconnections after long-lived connections)
            pool.resetRetryCountIfStable(id)

            // Check if we should reconnect
            if let address = pool.reconnectAddress(for: peer) {
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
            try? await Task.sleep(for: delay)
            await self?.performReconnect(id: id, peer: peer, address: address, attempt: attempt)
        }
    }

    private func performReconnect(id: ConnectionID, peer: PeerID, address: Multiaddr, attempt: Int) async {
        guard isRunning else { return }
        guard pool.reconnectAddress(for: peer) != nil else { return }

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
                    try? await muxedConnection.close()
                    throw NodeError.notConnected(peer)
                }

                if let gater = configuration.pool.gater {
                    if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                        try? await muxedConnection.close()
                        emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                        throw NodeError.connectionGated(stage: .secured)
                    }
                }

                // Reserve outbound connection resource for the reconnected connection
                if let rm = configuration.resourceManager {
                    do {
                        try rm.reserveOutboundConnection(to: peer)
                    } catch let error as ResourceError {
                        try? await muxedConnection.close()
                        switch error {
                        case .limitExceeded(let scope, let resource):
                            throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                        }
                    }
                }

                pool.updateConnection(id, connection: muxedConnection)
                pool.resetRetryCount(id)

                emit(.peerConnected(remotePeer))
                emitConnectionEvent(.reconnected(peer: peer, attempt: attempt))

                await healthMonitor?.startMonitoring(peer: remotePeer)

                Task { [weak self] in
                    await self?.handleInboundStreams(connection: muxedConnection)
                    await self?.handleConnectionClosed(id: id, peer: remotePeer)
                }
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
                try? await rawConnection.close()
                throw error
            }

            let remotePeer = result.connection.remotePeer

            // Verify it's the same peer
            guard remotePeer == peer else {
                try? await result.connection.close()
                throw NodeError.notConnected(peer)
            }

            // Gating check (secured)
            if let gater = configuration.pool.gater {
                if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                    try? await result.connection.close()
                    emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                    throw NodeError.connectionGated(stage: .secured)
                }
            }

            // Reserve outbound connection resource for the reconnected connection
            if let rm = configuration.resourceManager {
                do {
                    try rm.reserveOutboundConnection(to: peer)
                } catch let error as ResourceError {
                    try? await result.connection.close()
                    switch error {
                    case .limitExceeded(let scope, let resource):
                        throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                    }
                }
            }

            // Update existing entry instead of creating new one
            pool.updateConnection(id, connection: result.connection)
            pool.resetRetryCount(id)

            // Emit events
            emit(.peerConnected(remotePeer))
            emitConnectionEvent(.reconnected(peer: peer, attempt: attempt))

            // Start health monitoring
            await healthMonitor?.startMonitoring(peer: remotePeer)

            // Start handling inbound streams (with same ID)
            Task { [weak self] in
                await self?.handleInboundStreams(connection: result.connection)
                await self?.handleConnectionClosed(id: id, peer: remotePeer)
            }

        } catch {
            // Check if we should retry again
            let retryCount = pool.managedConnection(id)?.retryCount ?? attempt
            let policy = configuration.pool.reconnectionPolicy

            if policy.shouldReconnect(attempt: retryCount, reason: .error(code: .transportError, message: error.localizedDescription)) {
                await scheduleReconnect(id: id, peer: peer, address: address, attempt: retryCount + 1)
            } else {
                pool.updateState(id, to: .failed(reason: .error(code: .transportError, message: error.localizedDescription)))
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
                try? await Task.sleep(for: idleTimeout / 2)
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
        // Check and set cooldown atomically BEFORE any await
        // This prevents race conditions where multiple calls bypass cooldown during await
        let now = ContinuousClock.now
        if let cooldownUntil = autoConnectCooldowns[peer] {
            if now < cooldownUntil {
                return
            }
        }
        // Set cooldown immediately to prevent concurrent attempts
        autoConnectCooldowns[peer] = now + config.reconnectCooldown

        // Already connected?
        guard !pool.isConnected(to: peer) else { return }

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
            // Record success
            await _addressBook.recordSuccess(address: address, for: peer)
        } catch {
            // Record failure
            await _addressBook.recordFailure(address: address, for: peer)
        }
    }

    private func performIdleCheck() async {
        let idleTimeout = configuration.pool.idleTimeout

        // 1. Close idle connections
        let idleConnections = pool.idleConnections(threshold: idleTimeout)
        for managed in idleConnections {
            configuration.resourceManager?.releaseConnection(peer: managed.peer, direction: managed.direction)
            try? await managed.connection?.close()
            _ = pool.remove(managed.id)
            emit(.peerDisconnected(managed.peer))
            emitConnectionEvent(.disconnected(peer: managed.peer, reason: .idleTimeout))
        }

        // 2. Trim if over limits
        let trimmed = pool.trimIfNeeded()
        for managed in trimmed {
            configuration.resourceManager?.releaseConnection(peer: managed.peer, direction: managed.direction)
            try? await managed.connection?.close()
            emit(.peerDisconnected(managed.peer))
            emitConnectionEvent(.trimmed(peer: managed.peer, reason: "Connection limit exceeded"))
        }

        // 3. Cleanup stale entries (failed, old disconnected)
        _ = pool.cleanupStaleEntries(disconnectedThreshold: idleTimeout)
    }

    private func acceptLoop(listener: any Listener, address: Multiaddr) async {
        while isRunning {
            do {
                let rawConnection = try await listener.accept()

                Task { [weak self] in
                    await self?.handleInboundConnection(rawConnection)
                }
            } catch {
                if isRunning {
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
                try? await rawConnection.close()
                emitConnectionEvent(.gated(peer: nil, address: remoteAddress, stage: .accept))
                return
            }
        }

        // Check inbound limits
        if !pool.canAcceptInbound() {
            try? await rawConnection.close()
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
                try? await rawConnection.close()
                throw error
            }

            let remotePeer = result.connection.remotePeer
            let remoteAddress = result.connection.remoteAddress

            // Gating check (secured)
            if let gater = configuration.pool.gater {
                if !gater.interceptSecured(peer: remotePeer, direction: .inbound) {
                    try? await result.connection.close()
                    emitConnectionEvent(.gated(peer: remotePeer, address: remoteAddress, stage: .secured))
                    return
                }
            }

            // Check per-peer limit
            if !pool.canConnectTo(peer: remotePeer) {
                try? await result.connection.close()
                return
            }

            // Reserve inbound connection resource
            if let rm = configuration.resourceManager {
                do {
                    try rm.reserveInboundConnection(from: remotePeer)
                } catch {
                    try? await result.connection.close()
                    return
                }
            }

            // Add to pool
            let connID = pool.add(
                result.connection,
                for: remotePeer,
                address: remoteAddress,
                direction: .inbound
            )

            // Emit events
            emit(.peerConnected(remotePeer))
            emitConnectionEvent(.connected(peer: remotePeer, address: remoteAddress, direction: .inbound))

            // Start health monitoring
            await healthMonitor?.startMonitoring(peer: remotePeer)

            // Handle inbound streams
            await handleInboundStreams(connection: result.connection)
            await handleConnectionClosed(id: connID, peer: remotePeer)
        } catch {
            emit(.connectionError(nil, error))
        }
    }

    /// Accept loop for SecuredListener (e.g., QUIC).
    ///
    /// SecuredListener yields pre-secured, pre-multiplexed connections.
    private func securedAcceptLoop(listener: any SecuredListener, address: Multiaddr) async {
        for await muxedConnection in listener.connections {
            guard isRunning else { break }
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
                try? await muxedConnection.close()
                emitConnectionEvent(.gated(peer: nil, address: remoteAddress, stage: .accept))
                return
            }
        }

        // Check inbound limits
        if !pool.canAcceptInbound() {
            try? await muxedConnection.close()
            return
        }

        // Gating check (secured stage)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .inbound) {
                try? await muxedConnection.close()
                emitConnectionEvent(.gated(peer: remotePeer, address: remoteAddress, stage: .secured))
                return
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            try? await muxedConnection.close()
            return
        }

        // Reserve inbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveInboundConnection(from: remotePeer)
            } catch {
                try? await muxedConnection.close()
                return
            }
        }

        // Add to pool
        let connID = pool.add(
            muxedConnection,
            for: remotePeer,
            address: remoteAddress,
            direction: .inbound
        )

        // Emit events
        emit(.peerConnected(remotePeer))
        emitConnectionEvent(.connected(peer: remotePeer, address: remoteAddress, direction: .inbound))

        // Start health monitoring
        await healthMonitor?.startMonitoring(peer: remotePeer)

        // Handle inbound streams
        await handleInboundStreams(connection: muxedConnection)
        await handleConnectionClosed(id: connID, peer: remotePeer)
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
                        try? await stream.close()
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
                        write: { try await stream.write($0) }
                    )

                    // Find and run the handler
                    if let handler = capturedHandlers[result.protocolID] {
                        let context = StreamContext(
                            stream: stream,
                            remotePeer: remotePeer,
                            remoteAddress: remoteAddress,
                            localPeer: localPeer,
                            localAddress: localAddress
                        )
                        await handler(context)
                    } else {
                        try? await stream.close()
                    }
                } catch {
                    try? await stream.close()
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
            if chunk.isEmpty {
                throw NodeError.streamClosed
            }

            state.withLock { buffer in
                buffer.append(chunk)
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
