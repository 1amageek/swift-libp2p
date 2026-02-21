/// P2P - Unified entry point for swift-libp2p
///
/// Provides a high-level API for building P2P applications.
/// Node is a thin orchestrator that delegates connection lifecycle to Swarm.

import Foundation
import Synchronization

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

/// Thread-safe store for listen addresses, usable from @Sendable closures.
/// Wraps Mutex (which is ~Copyable) in a Sendable reference type.
internal final class ListenAddressStore: Sendable {
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

    /// Traversal configuration (nil to disable traversal orchestration).
    public let traversal: TraversalConfiguration?

    /// Maximum concurrent inbound stream negotiations per connection (C2).
    /// Default: 128 (rust-libp2p default).
    public let maxNegotiatingInboundStreams: Int

    /// Services registered with this node (unified service lifecycle).
    public let services: [any NodeService]

    public init(
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        transports: [any Transport] = [],
        security: [any SecurityUpgrader] = [],
        muxers: [any Muxer] = [],
        pool: PoolConfiguration = .init(),
        healthCheck: HealthMonitorConfiguration? = .default,
        discoveryConfig: DiscoveryConfiguration = .default,
        peerStore: (any PeerStore)? = nil,
        addressBookConfig: AddressBookConfiguration? = nil,
        bootstrap: BootstrapConfiguration? = nil,
        protoBook: (any ProtoBook)? = nil,
        keyBook: (any KeyBook)? = nil,
        resourceManager: (any ResourceManager)? = nil,
        traversal: TraversalConfiguration? = nil,
        maxNegotiatingInboundStreams: Int = 128,
        services: [any NodeService] = []
    ) {
        self.keyPair = keyPair
        self.listenAddresses = listenAddresses
        self.transports = transports
        self.security = security
        self.muxers = muxers
        self.pool = pool
        self.healthCheck = healthCheck
        self.discoveryConfig = discoveryConfig
        self.peerStore = peerStore
        self.addressBookConfig = addressBookConfig
        self.bootstrap = bootstrap
        self.protoBook = protoBook
        self.keyBook = keyBook
        self.resourceManager = resourceManager
        self.traversal = traversal
        self.maxNegotiatingInboundStreams = maxNegotiatingInboundStreams
        self.services = services
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

    // MARK: - Address Lifecycle Events (C4)

    /// A new external address candidate was observed (e.g., from Identify).
    case newExternalAddrCandidate(Multiaddr)

    /// An external address was confirmed as reachable (e.g., by AutoNAT).
    case externalAddrConfirmed(Multiaddr)

    /// An external address expired (no longer reachable).
    case externalAddrExpired(Multiaddr)

    /// A new listen address is active.
    case newListenAddr(Multiaddr)

    /// A listen address expired.
    case expiredListenAddr(Multiaddr)

    /// Dialing a peer.
    case dialing(PeerID)

    /// An outgoing connection attempt failed.
    case outgoingConnectionError(peer: PeerID?, error: any Error)
}

// MARK: - Node

/// A P2P network node.
///
/// ## Responsibilities
/// - Public API (connect, disconnect, newStream, etc.)
/// - Event emission
/// - Service lifecycle (register, attach, shutdown)
/// - Discovery integration
/// - Delegates connection lifecycle to Swarm
public actor Node: NodeContext {

    /// The configuration for this node.
    public let configuration: NodeConfiguration

    /// The peer ID of this node.
    public var peerID: PeerID {
        configuration.keyPair.peerID
    }

    // MARK: - NodeContext conformance

    /// The local peer ID (NodeContext).
    public nonisolated var localPeer: PeerID {
        configuration.keyPair.peerID
    }

    /// The local key pair (NodeContext).
    public nonisolated var localKeyPair: KeyPair {
        configuration.keyPair
    }

    /// Returns the current listen addresses (NodeContext).
    public func listenAddresses() -> [Multiaddr] {
        swarm.listenAddresses.current
    }

    /// Returns the list of supported protocol IDs (NodeContext).
    public func supportedProtocols() -> [String] {
        Array(localHandlers.keys)
    }

    // MARK: - Internal components

    /// The swarm manages all connection lifecycle.
    private let swarm: Swarm

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

    // Protocol handlers (local copy for supportedProtocols query)
    private var localHandlers: [String: ProtocolHandler] = [:]

    // State
    private var isRunning = false

    // Background tasks
    private var discoveryTasks: [Task<Void, Never>] = []
    private var eventForwardingTask: Task<Void, Never>?

    // Active services (populated during start())
    private var activeServices: [any NodeService] = []
    private var activePeerObservers: [any PeerObserver] = []

    // Traversal orchestration
    private var traversalCoordinator: TraversalCoordinator?

    // Events — created eagerly in init to prevent event loss
    private var eventContinuation: AsyncStream<NodeEvent>.Continuation?
    private let _events: AsyncStream<NodeEvent>

    /// Event stream for monitoring node state changes.
    public var events: AsyncStream<NodeEvent> {
        _events
    }

    /// Creates a new node with the given configuration.
    public init(configuration: NodeConfiguration) {
        self.configuration = configuration

        // Create Swarm with extracted configuration
        let swarmConfig = SwarmConfiguration(
            keyPair: configuration.keyPair,
            listenAddresses: configuration.listenAddresses,
            transports: configuration.transports,
            security: configuration.security,
            muxers: configuration.muxers,
            pool: configuration.pool,
            resourceManager: configuration.resourceManager,
            maxNegotiatingInboundStreams: configuration.maxNegotiatingInboundStreams
        )
        self.swarm = Swarm(configuration: swarmConfig)

        // Initialize peer store and address book
        let peerStore = configuration.peerStore ?? MemoryPeerStore()
        self._peerStore = peerStore
        self._addressBook = DefaultAddressBook(
            peerStore: peerStore,
            configuration: configuration.addressBookConfig ?? .default
        )
        self._protoBook = configuration.protoBook ?? MemoryProtoBook()
        self._keyBook = configuration.keyBook ?? MemoryKeyBook()

        // Create event stream eagerly to prevent event loss.
        let (stream, continuation) = AsyncStream<NodeEvent>.makeStream()
        self._events = stream
        self.eventContinuation = continuation
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
        localHandlers[protocolID] = handler
        Task { await swarm.registerHandler(for: protocolID, handler: handler) }
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
        let wrappedHandler: ProtocolHandler = { context in
            await handler(context.stream)
        }
        localHandlers[protocolID] = wrappedHandler
        Task { await swarm.registerHandler(for: protocolID, handler: wrappedHandler) }
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

        // --- Register handlers from services (before Swarm start) ---
        let allServices = configuration.services
        self.activeServices = allServices
        self.activePeerObservers = allServices.compactMap { $0 as? any PeerObserver }

        for service in allServices {
            if let proto = service as? any StreamService {
                for protocolID in proto.protocolIDs {
                    let handler: ProtocolHandler = { context in
                        await proto.handleInboundStream(context)
                    }
                    localHandlers[protocolID] = handler
                    await swarm.registerHandler(for: protocolID, handler: handler)
                }
            }
        }

        // Register local handlers with swarm
        for (protocolID, handler) in localHandlers {
            await swarm.registerHandler(for: protocolID, handler: handler)
        }

        // Start Swarm (listeners, accept loops, idle check)
        try await swarm.start()

        // Start event forwarding from Swarm to Node events
        startEventForwarding()

        // --- Attach services (listeners are up, addresses resolved) ---
        for service in allServices {
            await service.attach(to: self)
        }

        // --- Discovery integration ---
        let resolved = swarm.advertisedAddresses.current
        for service in allServices {
            if let discovery = service as? any DiscoveryBehaviour {
                if !resolved.isEmpty {
                    do {
                        try await discovery.announce(addresses: resolved)
                    } catch {
                        logger.warning("[P2P] Discovery announce failed: \(error)")
                    }
                }
                if configuration.discoveryConfig.autoConnect {
                    startDiscoveryTask(discovery: discovery)
                }
            }
        }

        // Initialize traversal orchestration if configured
        if let traversalConfig = configuration.traversal {
            let coordinator = TraversalCoordinator(
                configuration: traversalConfig,
                localPeer: peerID,
                transports: configuration.transports
            )
            let addressStore = swarm.listenAddresses
            let pool = swarm.pool
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
                dialAddress: { [weak self] (addr: Multiaddr) in
                    guard let self else { throw NodeError.nodeNotRunning }
                    return try await self.connect(to: addr)
                }
            )
            self.traversalCoordinator = coordinator
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

            _ = await bootstrap.bootstrap()

            if bootstrapConfig.automaticBootstrap {
                await bootstrap.startAutoBootstrap()
            }
        }
    }

    /// Shuts down the node.
    public func shutdown() async {
        isRunning = false

        // Shutdown traversal coordinator first
        await traversalCoordinator?.shutdown()
        traversalCoordinator = nil

        // Shutdown PeerStore if using MemoryPeerStore
        if let memoryStore = _peerStore as? MemoryPeerStore {
            memoryStore.shutdown()
        }

        // Cancel discovery tasks
        for task in discoveryTasks { task.cancel() }
        discoveryTasks.removeAll()

        // Stop bootstrap
        if let bootstrap = _bootstrap {
            await bootstrap.stopAutoBootstrap()
        }
        _bootstrap = nil

        // Stop health monitor
        await healthMonitor?.stopAll()

        // Shutdown all active services FIRST (PeerObserver dispatch becomes no-op)
        for service in activeServices {
            await service.shutdown()
        }
        activeServices = []
        activePeerObservers = []

        // Cancel event forwarding (no more behaviour dispatch needed)
        eventForwardingTask?.cancel()

        // Shutdown swarm (closes connections, emits final events, finishes broadcaster)
        await swarm.shutdown()

        // Wait for event forwarding task to complete
        await eventForwardingTask?.value
        eventForwardingTask = nil

        // Finish event stream
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - Connections (delegated to Swarm)

    /// Connects to a peer at the given address.
    @discardableResult
    public func connect(to address: Multiaddr) async throws -> PeerID {
        try await swarm.dial(to: address)
    }

    /// Connects to a peer using known addresses and traversal orchestration.
    @discardableResult
    public func connect(to peer: PeerID) async throws -> PeerID {
        // Already connected?
        if swarm.pool.isConnected(to: peer) { return peer }

        // Collect addresses from address book.
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
    public func isLimitedConnection(to peer: PeerID) -> Bool {
        swarm.pool.isLimitedConnection(to: peer)
    }

    /// Disconnects from a peer.
    public func disconnect(from peer: PeerID) async {
        await healthMonitor?.stopMonitoring(peer: peer)
        await swarm.closePeer(peer)
    }

    /// Opens a stream to a peer with the given protocol.
    public func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        try await swarm.newStream(to: peer, protocol: protocolID)
    }

    /// Returns the connection to a peer if connected.
    public func connection(to peer: PeerID) -> MuxedConnection? {
        swarm.pool.connection(to: peer)
    }

    /// Returns the connection state for a peer.
    public func connectionState(of peer: PeerID) -> ConnectionState? {
        swarm.pool.connectionState(of: peer)
    }

    /// Returns all connected peers.
    public var connectedPeers: [PeerID] {
        swarm.pool.connectedPeers
    }

    /// Returns the resolved addresses suitable for external advertisement.
    public nonisolated var advertisedAddresses: [Multiaddr] {
        swarm.advertisedAddresses.current
    }

    /// Returns the number of active connections.
    public var connectionCount: Int {
        swarm.pool.connectionCount
    }

    /// Returns a point-in-time report of connection trim decisions.
    public func connectionTrimReport() -> ConnectionTrimReport {
        swarm.pool.trimReport()
    }

    // MARK: - Tagging & Protection

    /// Adds a tag to a peer's connections.
    public func tag(_ peer: PeerID, with tag: String) {
        swarm.pool.tag(peer, with: tag)
    }

    /// Removes a tag from a peer's connections.
    public func untag(_ peer: PeerID, tag: String) {
        swarm.pool.untag(peer, tag: tag)
    }

    /// Protects a peer's connections from trimming.
    public func protect(_ peer: PeerID) {
        swarm.pool.protect(peer)
    }

    /// Removes protection from a peer's connections.
    public func unprotect(_ peer: PeerID) {
        swarm.pool.unprotect(peer)
    }

    // MARK: - Keep-Alive (C3)

    /// Sets the keep-alive flag for all connections to a peer.
    public func setKeepAlive(_ keepAlive: Bool, for peer: PeerID) {
        swarm.pool.setKeepAlive(keepAlive, for: peer)
    }

    // MARK: - Address Resolution

    /// Resolves unspecified addresses (0.0.0.0 / ::) to actual network interface IPs.
    ///
    /// Delegates to Swarm's static implementation.
    static func resolveUnspecifiedAddresses(_ boundAddresses: [Multiaddr]) -> [Multiaddr] {
        Swarm.resolveUnspecifiedAddresses(boundAddresses)
    }

    // MARK: - Private: Event Forwarding

    /// Forwards SwarmEvents to NodeEvents and drives external emission.
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
            // Behaviour dispatch FIRST — services (GossipSub, Plumtree) set up
            // internal mesh before external consumers see the event.
            // Actor reentrancy allows newStream() callbacks during await.
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

    // MARK: - Private: Health Check

    private func handleHealthCheckFailed(peer: PeerID) async {
        emit(.connection(.healthCheckFailed(peer: peer)))
        await disconnect(from: peer)
    }

    // MARK: - Private: Discovery

    private func startDiscoveryTask(discovery: any DiscoveryService) {
        let config = configuration.discoveryConfig
        let localPeerID = configuration.keyPair.peerID

        let task = Task { [weak self, localPeerID] in
            let peers = await discovery.knownPeers()
            for peer in peers {
                guard !Task.isCancelled else { return }
                guard peer != localPeerID else { continue }
                await self?.tryAutoConnect(to: peer, hints: [], config: config)
            }

            for await observation in discovery.observations {
                guard !Task.isCancelled else { return }
                guard let self = self else { return }

                guard observation.subject != localPeerID else { continue }

                let connectionCount = await self.connectionCount
                guard connectionCount < config.maxAutoConnectPeers else { continue }

                switch observation.kind {
                case .announcement, .reachable:
                    await self._peerStore.addObservation(observation)
                    await self.tryAutoConnect(
                        to: observation.subject,
                        hints: observation.hints,
                        config: config
                    )
                case .unreachable:
                    break
                }
            }
        }
        discoveryTasks.append(task)
    }

    private func tryAutoConnect(
        to peer: PeerID,
        hints: [Multiaddr],
        config: DiscoveryConfiguration
    ) async {
        let pool = swarm.pool
        let dialBackoff = swarm.dialBackoff

        guard !dialBackoff.shouldBackOff(from: peer) else { return }
        guard !pool.isConnected(to: peer) else { return }
        guard !pool.hasReconnecting(for: peer) else { return }
        guard !pool.hasPendingDial(to: peer) else { return }

        if !hints.isEmpty {
            await _peerStore.addAddresses(hints, for: peer)
        }

        guard let address = await _addressBook.bestAddress(for: peer) else {
            return
        }

        do {
            try await connect(to: address)
            await _addressBook.recordSuccess(address: address, for: peer)
        } catch {
            dialBackoff.recordFailure(for: peer)
            await _addressBook.recordFailure(address: address, for: peer)
        }
    }

    // MARK: - Private: Event Emission

    private func emit(_ event: NodeEvent) {
        eventContinuation?.yield(event)
    }
}

// MARK: - NodePingProvider

/// Internal adapter to make Node work with HealthMonitor.
private final class NodePingProvider: PingProvider, @unchecked Sendable {
    nonisolated(unsafe) private weak var node: Node?
    private let pingService: PingService

    init(node: Node) {
        self.node = node
        self.pingService = PingService()
    }

    func ping(_ peer: PeerID) async throws -> Duration {
        guard let node else {
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
            let result: ExtractResult = state.withLock { buffer in
                guard !buffer.isEmpty else { return .needMoreData }

                do {
                    let (length, lengthBytes) = try Varint.decode(buffer)

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

            let currentSize = state.withLock { $0.count }
            if currentSize > maxMessageSize {
                throw NodeError.messageTooLarge(size: currentSize, max: maxMessageSize)
            }

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

// MARK: - AsyncSemaphore (C2)

/// Async-compatible counting semaphore for limiting concurrency.
internal final class AsyncSemaphore: Sendable {
    private let state: Mutex<SemaphoreState>

    private struct SemaphoreState: Sendable {
        var count: Int
        var waiters: [CheckedContinuation<Void, Never>]
    }

    init(count: Int) {
        self.state = Mutex(SemaphoreState(count: count, waiters: []))
    }

    func wait() async {
        let shouldSuspend: Bool = state.withLock { state in
            if state.count > 0 {
                state.count -= 1
                return false
            }
            return true
        }

        guard shouldSuspend else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeImmediately = state.withLock { state -> Bool in
                if state.count > 0 {
                    state.count -= 1
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func signal() {
        let waiter: CheckedContinuation<Void, Never>? = state.withLock { state in
            if !state.waiters.isEmpty {
                return state.waiters.removeFirst()
            }
            state.count += 1
            return nil
        }
        waiter?.resume()
    }
}
