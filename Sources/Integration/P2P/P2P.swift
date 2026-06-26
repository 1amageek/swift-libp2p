/// P2P - Unified entry point for swift-libp2p
///
/// Provides a high-level API for building P2P applications.
/// Node is a thin orchestrator that delegates connection lifecycle to Swarm.

import Foundation
import Synchronization

// Protocol abstractions
@_exported import P2PCore
@_exported import P2PTransport
@_exported import P2PTransportSecured
@_exported import P2PSecurity
@_exported import P2PMux
@_exported import P2PNegotiation
@_exported import P2PDiscovery
@_exported import P2PProtocols
@_exported import P2PRuntime
// Default implementations (batteries-included)
@_exported import P2PTransportTCP
@_exported import P2PSecurityNoise
// Plaintext is intentionally NOT @_exported: it provides no confidentiality and
// must be an explicit, deliberate choice. `import P2P` no longer pulls it into
// scope; callers that want it must `import P2PSecurityPlaintext` directly.
// Production validation rejects plaintext security (see validateProfileInputs).
import P2PSecurityPlaintext
@_exported import P2PMuxYamux
@_exported import P2PPing
@_exported import P2PGossipSub
@_exported import NIOCore
// Internal
import P2PIdentify
import P2PCircuitRelay
import P2PPnet

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

/// High-level operating profile for a node.
///
/// This controls recommended defaults for pool behavior, health checks,
/// and resource accounting. Use explicit initializers when you need to
/// override individual knobs.
public enum NodeOperationalProfile: Sendable {
    case development
    case production
}

public enum NodeConnectionProviderAuditMode: Sendable, Equatable {
    case transparentComposition
    case opaqueProviders
}

public enum NodeProductionAuditPolicy: Sendable, Equatable {
    case permissive
    case strict
}

public enum NodeStartValidationBehavior: Sendable {
    case disabled
    case warn
    case strict
}

public enum NodeConfigurationValidationIssue: String, Sendable, Equatable {
    case plaintextSecurityInProduction
    case missingSecurityForTransportCompositionInProduction
    case opaqueConnectionProvidersRequireManualSecurityAudit
    case disabledHealthChecksInProduction
    case disabledResourceManagerInProduction
}

public struct NodeStartValidationError: Error, Sendable {
    public let profile: NodeOperationalProfile
    public let validation: NodeConfigurationValidation

    public init(profile: NodeOperationalProfile, validation: NodeConfigurationValidation) {
        self.profile = profile
        self.validation = validation
    }
}

public struct NodeConfigurationValidation: Sendable, Equatable {
    public let errors: [NodeConfigurationValidationIssue]
    public let warnings: [NodeConfigurationValidationIssue]

    public var isValid: Bool {
        errors.isEmpty
    }

    public init(
        errors: [NodeConfigurationValidationIssue],
        warnings: [NodeConfigurationValidationIssue]
    ) {
        self.errors = errors
        self.warnings = warnings
    }
}

/// Configuration for a P2P node.
public struct NodeConfiguration: Sendable {
    /// Runtime-facing connection and listener configuration.
    public let runtime: RuntimeConfiguration

    /// The key pair for this node.
    public var keyPair: KeyPair { runtime.keyPair }

    /// Addresses to listen on.
    public var listenAddresses: [Multiaddr] { runtime.listenAddresses }

    /// Precomposed connection providers used directly by the runtime.
    public var connectionProviders: [any ConnectionProvider] { runtime.connectionProviders }

    /// Connection pool configuration.
    public var pool: PoolConfiguration { runtime.pool }

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

    /// Resource manager for system-wide resource accounting.
    ///
    /// Never `nil`: every node enforces resource limits. To deliberately
    /// run without limits, pass an explicit `NullResourceManager()` so the
    /// choice is visible at the call site rather than a silent default.
    public let resourceManager: any ResourceManager

    /// Traversal configuration (nil to disable traversal orchestration).
    public let traversal: TraversalConfiguration?

    /// Maximum concurrent inbound stream negotiations per connection (C2).
    /// Default: 128 (rust-libp2p default).
    public var maxNegotiatingInboundStreams: Int { runtime.maxNegotiatingInboundStreams }

    /// Explicitly registered services.
    public let services: ServicePipeline

    /// Optional discovery pipeline.
    public let discovery: DiscoveryPipeline?

    /// Whether the runtime connection providers are transparent facade-managed
    /// compositions or opaque expert-provided implementations.
    public let connectionProviderAuditMode: NodeConnectionProviderAuditMode

    /// How strictly production validation should treat opaque providers.
    public let productionAuditPolicy: NodeProductionAuditPolicy

    /// The operating profile this configuration was created for, if any.
    ///
    /// When set, `Node.start()` validates the configuration against this
    /// profile so production guarantees (security, resource limits) are
    /// enforced even when `start()` is called without an explicit profile.
    public let operationalProfile: NodeOperationalProfile?

    /// Whether the configured security set includes plaintext.
    ///
    /// Captured at configuration time because once transports/security are
    /// composed into opaque `ConnectionProvider`s, the security protocol IDs are
    /// no longer recoverable. `validationReport(for:)` uses this so a plaintext
    /// configuration is rejected in production even after composition.
    public let usesPlaintextSecurity: Bool

    private static let plaintextSecurityProtocolID = "/plaintext/2.0.0"

    static func containsPlaintext(_ security: [any SecurityUpgrader]) -> Bool {
        security.contains { $0.protocolID == plaintextSecurityProtocolID }
    }

    public init(
        runtime: RuntimeConfiguration = .init(),
        healthCheck: HealthMonitorConfiguration? = .default,
        discoveryConfig: DiscoveryConfiguration = .default,
        peerStore: (any PeerStore)? = nil,
        addressBookConfig: AddressBookConfiguration? = nil,
        bootstrap: BootstrapConfiguration? = nil,
        protoBook: (any ProtoBook)? = nil,
        keyBook: (any KeyBook)? = nil,
        resourceManager: any ResourceManager = DefaultResourceManager(configuration: .default),
        traversal: TraversalConfiguration? = nil,
        connectionProviderAuditMode: NodeConnectionProviderAuditMode = .opaqueProviders,
        productionAuditPolicy: NodeProductionAuditPolicy = .permissive,
        operationalProfile: NodeOperationalProfile? = nil,
        usesPlaintextSecurity: Bool = false,
        services: ServicePipeline = .empty,
        discovery: DiscoveryPipeline? = nil
    ) {
        self.runtime = runtime
        self.healthCheck = healthCheck
        self.discoveryConfig = discoveryConfig
        self.peerStore = peerStore
        self.addressBookConfig = addressBookConfig
        self.bootstrap = bootstrap
        self.protoBook = protoBook
        self.keyBook = keyBook
        self.resourceManager = resourceManager
        self.traversal = traversal
        self.connectionProviderAuditMode = connectionProviderAuditMode
        self.productionAuditPolicy = productionAuditPolicy
        self.operationalProfile = operationalProfile
        self.usesPlaintextSecurity = usesPlaintextSecurity
        self.services = services
        self.discovery = discovery
    }

    public init(
        profile: NodeOperationalProfile,
        auditPolicy: NodeProductionAuditPolicy = .strict,
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        connectionProviders: [any ConnectionProvider] = [],
        transports: [any Transport] = [],
        security: [any SecurityUpgrader] = [],
        muxers: [any Muxer] = [],
        discoveryConfig: DiscoveryConfiguration = .default,
        peerStore: (any PeerStore)? = nil,
        addressBookConfig: AddressBookConfiguration? = nil,
        bootstrap: BootstrapConfiguration? = nil,
        protoBook: (any ProtoBook)? = nil,
        keyBook: (any KeyBook)? = nil,
        traversal: TraversalConfiguration? = nil,
        maxNegotiatingInboundStreams: Int = 128,
        services: ServicePipeline = .empty,
        discovery: DiscoveryPipeline? = nil
    ) throws {
        let connectionProviderAuditMode: NodeConnectionProviderAuditMode = connectionProviders.isEmpty
            ? .transparentComposition
            : .opaqueProviders
        let validation = Self.validateProfileInputs(
            profile: profile,
            connectionProviderAuditMode: connectionProviderAuditMode,
            auditPolicy: auditPolicy,
            connectionProviders: connectionProviders,
            transports: transports,
            security: security,
            healthCheck: Self.defaultHealthCheck(for: profile),
            resourceManager: Self.defaultResourceManager(for: profile)
        )
        guard validation.errors.isEmpty else {
            throw NodeStartValidationError(profile: profile, validation: validation)
        }

        self.runtime = RuntimeConfiguration(
            keyPair: keyPair,
            listenAddresses: listenAddresses,
            connectionProviders: connectionProviders.isEmpty
                ? ConnectionProviders.compose(
                    transports: transports,
                    security: security,
                    muxers: muxers
                )
                : connectionProviders,
            pool: Self.defaultPool(for: profile),
            maxNegotiatingInboundStreams: maxNegotiatingInboundStreams
        )
        self.healthCheck = Self.defaultHealthCheck(for: profile)
        self.discoveryConfig = discoveryConfig
        self.peerStore = peerStore
        self.addressBookConfig = addressBookConfig
        self.bootstrap = bootstrap
        self.protoBook = protoBook
        self.keyBook = keyBook
        self.resourceManager = Self.defaultResourceManager(for: profile)
        self.traversal = traversal
        self.connectionProviderAuditMode = connectionProviderAuditMode
        self.productionAuditPolicy = auditPolicy
        self.operationalProfile = profile
        self.usesPlaintextSecurity = Self.containsPlaintext(security)
        self.services = services
        self.discovery = discovery
    }

    public init(
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        connectionProviders: [any ConnectionProvider] = [],
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
        resourceManager: any ResourceManager = DefaultResourceManager(configuration: .default),
        traversal: TraversalConfiguration? = nil,
        privateNetwork: PnetConfiguration? = nil,
        productionAuditPolicy: NodeProductionAuditPolicy = .permissive,
        maxNegotiatingInboundStreams: Int = 128,
        services: ServicePipeline = .empty,
        discovery: DiscoveryPipeline? = nil
    ) {
        let connectionProviderAuditMode: NodeConnectionProviderAuditMode = connectionProviders.isEmpty
            ? .transparentComposition
            : .opaqueProviders
        // A configured PSK installs a pnet protector on the composed pipeline so
        // it runs before security and fails closed if it cannot be applied.
        let protector: (any ConnectionProtector)? = privateNetwork.map { PnetProtector(configuration: $0) }
        self.runtime = RuntimeConfiguration(
            keyPair: keyPair,
            listenAddresses: listenAddresses,
            connectionProviders: connectionProviders.isEmpty
                ? ConnectionProviders.compose(
                    transports: transports,
                    security: security,
                    muxers: muxers,
                    protector: protector
                )
                : connectionProviders,
            pool: pool,
            maxNegotiatingInboundStreams: maxNegotiatingInboundStreams
        )
        self.healthCheck = healthCheck
        self.discoveryConfig = discoveryConfig
        self.peerStore = peerStore
        self.addressBookConfig = addressBookConfig
        self.bootstrap = bootstrap
        self.protoBook = protoBook
        self.keyBook = keyBook
        self.resourceManager = resourceManager
        self.traversal = traversal
        self.connectionProviderAuditMode = connectionProviderAuditMode
        self.productionAuditPolicy = productionAuditPolicy
        self.operationalProfile = nil
        self.usesPlaintextSecurity = Self.containsPlaintext(security)
        self.services = services
        self.discovery = discovery
    }

    private static func defaultPool(for profile: NodeOperationalProfile) -> PoolConfiguration {
        switch profile {
        case .development:
            .development
        case .production:
            .production
        }
    }

    private static func defaultHealthCheck(
        for profile: NodeOperationalProfile
    ) -> HealthMonitorConfiguration? {
        switch profile {
        case .development:
            .development
        case .production:
            .production
        }
    }

    private static func defaultResourceManager(
        for profile: NodeOperationalProfile
    ) -> any ResourceManager {
        switch profile {
        case .development:
            DefaultResourceManager(configuration: .development)
        case .production:
            DefaultResourceManager(configuration: .default)
        }
    }

    public func validationReport(for profile: NodeOperationalProfile) -> NodeConfigurationValidation {
        guard profile == .production else {
            return NodeConfigurationValidation(errors: [], warnings: [])
        }

        var errors: [NodeConfigurationValidationIssue] = []
        var warnings: [NodeConfigurationValidationIssue] = []
        if usesPlaintextSecurity {
            errors.append(.plaintextSecurityInProduction)
        }
        if connectionProviderAuditMode == .opaqueProviders {
            switch productionAuditPolicy {
            case .strict:
                errors.append(.opaqueConnectionProvidersRequireManualSecurityAudit)
            case .permissive:
                warnings.append(.opaqueConnectionProvidersRequireManualSecurityAudit)
            }
        }
        if healthCheck == nil {
            warnings.append(.disabledHealthChecksInProduction)
        }
        if Self.isResourceManagerDisabled(resourceManager) {
            errors.append(.disabledResourceManagerInProduction)
        }

        return NodeConfigurationValidation(errors: errors, warnings: warnings)
    }

    /// A resource manager is "disabled" (no enforced limits) when it is an
    /// explicit `NullResourceManager`. In production this is treated as an
    /// error, not a silent default — opting out of limits must be deliberate.
    static func isResourceManagerDisabled(_ manager: any ResourceManager) -> Bool {
        manager is NullResourceManager
    }

    public static func validateProfileInputs(
        profile: NodeOperationalProfile,
        connectionProviderAuditMode: NodeConnectionProviderAuditMode,
        auditPolicy: NodeProductionAuditPolicy = .permissive,
        connectionProviders: [any ConnectionProvider],
        transports: [any Transport],
        security: [any SecurityUpgrader],
        healthCheck: HealthMonitorConfiguration? = nil,
        resourceManager: (any ResourceManager)? = nil
    ) -> NodeConfigurationValidation {
        guard profile == .production else {
            return NodeConfigurationValidation(errors: [], warnings: [])
        }

        var errors: [NodeConfigurationValidationIssue] = []
        var warnings: [NodeConfigurationValidationIssue] = []

        if security.contains(where: { $0.protocolID == plaintextSecurityProtocolID }) {
            errors.append(.plaintextSecurityInProduction)
        }
        if connectionProviders.isEmpty && !transports.isEmpty && security.isEmpty {
            errors.append(.missingSecurityForTransportCompositionInProduction)
        }
        if connectionProviderAuditMode == .opaqueProviders {
            switch auditPolicy {
            case .strict:
                errors.append(.opaqueConnectionProvidersRequireManualSecurityAudit)
            case .permissive:
                warnings.append(.opaqueConnectionProvidersRequireManualSecurityAudit)
            }
        }
        if healthCheck == nil {
            warnings.append(.disabledHealthChecksInProduction)
        }
        // A missing resource manager (nil) or an explicit NullResourceManager
        // means no enforced limits — an error in production, never a silent default.
        if resourceManager == nil || resourceManager.map(Self.isResourceManagerDisabled) == true {
            errors.append(.disabledResourceManagerInProduction)
        }

        return NodeConfigurationValidation(errors: errors, warnings: warnings)
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
public actor Node:
    NodeIdentityContext,
    ListenAddressContext,
    SupportedProtocolsContext,
    PeerStoreContext,
    StreamOpener
{

    /// The configuration for this node.
    public nonisolated let configuration: NodeConfiguration

    /// The peer ID of this node.
    public var peerID: PeerID {
        configuration.keyPair.peerID
    }

    // MARK: - Role Context Conformance

    /// The local peer ID.
    public nonisolated var localPeer: PeerID {
        configuration.keyPair.peerID
    }

    /// The local key pair.
    public nonisolated var localKeyPair: KeyPair {
        configuration.keyPair
    }

    /// Returns the current listen addresses.
    ///
    /// Includes both direct listen addresses from Swarm and relay
    /// addresses populated by `AutoRelayService`.
    public func listenAddresses() async -> [Multiaddr] {
        await runtime.listenAddresses()
    }

    /// Returns the list of supported protocol IDs.
    public func supportedProtocols() async -> [String] {
        await runtime.supportedProtocols()
    }

    // MARK: - Internal components

    /// The runtime manages lifecycle and connection orchestration.
    private let runtime: NodeRuntime

    // Discovery components
    private let _peerStore: any PeerStore
    private let _addressBook: any AddressBook
    private let _protoBook: any ProtoBook
    private let _keyBook: any KeyBook

    /// The peer store for this node.
    public var peerStore: any PeerStore { _peerStore }

    /// The address book for this node.
    public var addressBook: any AddressBook { _addressBook }

    /// The protocol book for this node.
    public var protoBook: any ProtoBook { _protoBook }

    /// The key book for this node.
    public var keyBook: any KeyBook { _keyBook }

    // Lifecycle state machine: idle → running → stopped
    private enum NodeLifecycleState {
        case idle      // Created, not yet started. handle/handleStream allowed.
        case starting  // Start sequence in progress.
        case running   // Started. All operations allowed.
        case stopped   // Shut down. Read-only queries only.
    }
    private var lifecycleState: NodeLifecycleState = .idle

    /// Event stream for monitoring node state changes.
    public nonisolated var events: AsyncStream<NodeEvent> { runtime.events }

    /// Creates a new node with the given configuration.
    public init(configuration: NodeConfiguration) {
        self.configuration = configuration

        // Initialize peer store and address book
        let peerStore = configuration.peerStore ?? MemoryPeerStore()
        self._peerStore = peerStore
        self._addressBook = DefaultAddressBook(
            peerStore: peerStore,
            configuration: configuration.addressBookConfig ?? .default
        )
        self._protoBook = configuration.protoBook ?? MemoryProtoBook()
        self._keyBook = configuration.keyBook ?? MemoryKeyBook()
        self.runtime = NodeRuntime(
            configuration: configuration,
            peerStore: peerStore,
            addressBook: self._addressBook,
            protoBook: self._protoBook,
            keyBook: self._keyBook
        )
    }

    public init(
        profile: NodeOperationalProfile,
        auditPolicy: NodeProductionAuditPolicy = .strict,
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        connectionProviders: [any ConnectionProvider] = [],
        transports: [any Transport] = [],
        security: [any SecurityUpgrader] = [],
        muxers: [any Muxer] = [],
        discoveryConfig: DiscoveryConfiguration = .default,
        peerStore: (any PeerStore)? = nil,
        addressBookConfig: AddressBookConfiguration? = nil,
        bootstrap: BootstrapConfiguration? = nil,
        protoBook: (any ProtoBook)? = nil,
        keyBook: (any KeyBook)? = nil,
        traversal: TraversalConfiguration? = nil,
        maxNegotiatingInboundStreams: Int = 128,
        @NodeGroupBuilder _ content: () -> NodeGroup = { NodeGroup() }
    ) throws {
        let components = try content().resolveNodeComponents()
        self.init(configuration: try NodeConfiguration(
            profile: profile,
            auditPolicy: auditPolicy,
            keyPair: keyPair,
            listenAddresses: listenAddresses,
            connectionProviders: connectionProviders,
            transports: transports,
            security: security,
            muxers: muxers,
            discoveryConfig: discoveryConfig,
            peerStore: peerStore,
            addressBookConfig: addressBookConfig,
            bootstrap: bootstrap,
            protoBook: protoBook,
            keyBook: keyBook,
            traversal: traversal,
            maxNegotiatingInboundStreams: maxNegotiatingInboundStreams,
            services: components.servicePipeline(),
            discovery: components.discoveryPipeline(localPeerID: keyPair.peerID)
        ))
    }

    public init(
        runtime: RuntimeConfiguration = .init(),
        healthCheck: HealthMonitorConfiguration? = .default,
        discoveryConfig: DiscoveryConfiguration = .default,
        peerStore: (any PeerStore)? = nil,
        addressBookConfig: AddressBookConfiguration? = nil,
        bootstrap: BootstrapConfiguration? = nil,
        protoBook: (any ProtoBook)? = nil,
        keyBook: (any KeyBook)? = nil,
        resourceManager: any ResourceManager = DefaultResourceManager(configuration: .default),
        traversal: TraversalConfiguration? = nil,
        @NodeGroupBuilder _ content: () -> NodeGroup = { NodeGroup() }
    ) throws {
        let components = try content().resolveNodeComponents()
        self.init(configuration: NodeConfiguration(
            runtime: runtime,
            healthCheck: healthCheck,
            discoveryConfig: discoveryConfig,
            peerStore: peerStore,
            addressBookConfig: addressBookConfig,
            bootstrap: bootstrap,
            protoBook: protoBook,
            keyBook: keyBook,
            resourceManager: resourceManager,
            traversal: traversal,
            services: components.servicePipeline(),
            discovery: components.discoveryPipeline(localPeerID: runtime.keyPair.peerID)
        ))
    }

    public init(
        keyPair: KeyPair = .generateEd25519(),
        listenAddresses: [Multiaddr] = [],
        connectionProviders: [any ConnectionProvider] = [],
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
        resourceManager: any ResourceManager = DefaultResourceManager(configuration: .default),
        traversal: TraversalConfiguration? = nil,
        maxNegotiatingInboundStreams: Int = 128,
        @NodeGroupBuilder _ content: () -> NodeGroup = { NodeGroup() }
    ) throws {
        try self.init(
            runtime: RuntimeConfiguration(
                keyPair: keyPair,
                listenAddresses: listenAddresses,
                connectionProviders: connectionProviders.isEmpty
                    ? ConnectionProviders.compose(
                        transports: transports,
                        security: security,
                        muxers: muxers
                    )
                    : connectionProviders,
                pool: pool,
                maxNegotiatingInboundStreams: maxNegotiatingInboundStreams
            ),
            healthCheck: healthCheck,
            discoveryConfig: discoveryConfig,
            peerStore: peerStore,
            addressBookConfig: addressBookConfig,
            bootstrap: bootstrap,
            protoBook: protoBook,
            keyBook: keyBook,
            resourceManager: resourceManager,
            traversal: traversal,
            content
        )
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
    ) async {
        guard lifecycleState != .stopped else { return }
        await runtime.registerHandler(for: protocolID, handler: handler)
    }

    /// Registers a simple protocol handler that only needs the stream.
    ///
    /// - Parameters:
    ///   - protocolID: The protocol identifier (e.g., "/chat/1.0.0")
    ///   - handler: The handler function for incoming streams
    public func handleStream(
        _ protocolID: String,
        handler: @escaping @Sendable (MuxedStream) async -> Void
    ) async {
        guard lifecycleState != .stopped else { return }
        let wrappedHandler: ProtocolHandler = { context in
            await handler(context.stream)
        }
        await runtime.registerHandler(for: protocolID, handler: wrappedHandler)
    }

    // MARK: - Lifecycle

    /// Starts the node.
    ///
    /// If the configuration was created for an operating profile (e.g.
    /// `.production`), the configuration is validated against that profile:
    /// errors (such as plaintext security or a disabled resource manager in
    /// production) abort the start; warnings are logged.
    public func start() async throws {
        if let profile = configuration.operationalProfile {
            try await start(validating: profile, behavior: .warn)
        } else {
            try await start(validating: nil, behavior: .disabled)
        }
    }

    /// Starts the node with optional validation against an operating profile.
    public func start(
        validating profile: NodeOperationalProfile?,
        behavior: NodeStartValidationBehavior = .strict
    ) async throws {
        if let profile {
            let validation = configuration.validationReport(for: profile)
            switch behavior {
            case .disabled:
                break
            case .warn:
                for error in validation.errors {
                    logger.warning("Node start validation error: \(error.rawValue)")
                }
                for warning in validation.warnings {
                    logger.warning("Node start validation warning: \(warning.rawValue)")
                }
                if !validation.errors.isEmpty {
                    throw NodeStartValidationError(profile: profile, validation: validation)
                }
            case .strict:
                if !validation.errors.isEmpty || !validation.warnings.isEmpty {
                    throw NodeStartValidationError(profile: profile, validation: validation)
                }
            }
        }

        switch lifecycleState {
        case .running: return
        case .starting: return
        case .stopped: throw NodeError.nodeNotRunning
        case .idle: break
        }
        lifecycleState = .starting

        do {
            try await runtime.start(capabilities: self)
            lifecycleState = .running
        } catch {
            lifecycleState = .idle
            throw error
        }
    }

    /// Shuts down the node.
    ///
    /// Safe to call from any lifecycle state:
    /// - `idle`: transitions to `stopped`, finishes event stream
    /// - `running`: full cleanup (services, swarm, events)
    /// - `stopped`: no-op (idempotent)
    public func shutdown() async throws {
        guard lifecycleState != .stopped else { return }
        lifecycleState = .stopped
        try await runtime.shutdown()
    }

    // MARK: - Connections (delegated to Swarm)

    /// Connects to a peer at the given address.
    @discardableResult
    public func connect(to address: Multiaddr) async throws -> PeerID {
        guard lifecycleState == .running else { throw NodeError.nodeNotRunning }
        return try await runtime.dial(to: address)
    }

    /// Connects to a peer using known addresses and traversal orchestration.
    @discardableResult
    public func connect(to peer: PeerID) async throws -> PeerID {
        guard lifecycleState == .running else { throw NodeError.nodeNotRunning }
        return try await runtime.connect(to: peer)
    }

    /// Returns whether the connection to a peer is limited (relay).
    public func isLimitedConnection(to peer: PeerID) -> Bool {
        runtime.isLimitedConnection(to: peer)
    }

    /// Disconnects from a peer.
    public func disconnect(from peer: PeerID) async {
        guard lifecycleState == .running else { return }
        await runtime.closePeer(peer)
    }

    /// Opens a stream to a peer with the given protocol.
    public func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        guard lifecycleState == .running else { throw NodeError.nodeNotRunning }
        return try await runtime.newStream(to: peer, protocol: protocolID)
    }

    /// Returns the connection to a peer if connected.
    public func connection(to peer: PeerID) -> MuxedConnection? {
        runtime.connection(to: peer)
    }

    /// Returns the connection state for a peer.
    public func connectionState(of peer: PeerID) -> ConnectionState? {
        runtime.connectionState(of: peer)
    }

    /// Returns all connected peers.
    public var connectedPeers: [PeerID] {
        runtime.connectedPeers
    }

    /// Returns the resolved addresses suitable for external advertisement.
    public nonisolated var advertisedAddresses: [Multiaddr] {
        runtime.advertisedAddresses
    }

    /// Returns the number of active connections.
    public var connectionCount: Int {
        runtime.connectionCount
    }

    /// Returns a point-in-time report of connection trim decisions.
    public func connectionTrimReport() -> ConnectionTrimReport {
        runtime.connectionTrimReport()
    }

    // MARK: - Tagging & Protection

    /// Adds a tag to a peer's connections.
    public func tag(_ peer: PeerID, with tag: String) {
        runtime.tag(peer, with: tag)
    }

    /// Removes a tag from a peer's connections.
    public func untag(_ peer: PeerID, tag: String) {
        runtime.untag(peer, tag: tag)
    }

    /// Protects a peer's connections from trimming.
    public func protect(_ peer: PeerID) {
        runtime.protect(peer)
    }

    /// Removes protection from a peer's connections.
    public func unprotect(_ peer: PeerID) {
        runtime.unprotect(peer)
    }

    // MARK: - Keep-Alive (C3)

    /// Sets the keep-alive flag for all connections to a peer.
    public func setKeepAlive(_ keepAlive: Bool, for peer: PeerID) {
        runtime.setKeepAlive(keepAlive, for: peer)
    }

    // MARK: - Address Resolution

    /// Resolves unspecified addresses (0.0.0.0 / ::) to actual network interface IPs.
    ///
    /// Delegates to Swarm's static implementation.
    static func resolveUnspecifiedAddresses(_ boundAddresses: [Multiaddr]) -> [Multiaddr] {
        Swarm.resolveUnspecifiedAddresses(boundAddresses)
    }

}

extension Node: RuntimeCapabilitySource {}

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
    /// A dial was suppressed because the peer is currently in dial backoff
    /// after recent failures. Retry after the backoff window expires.
    case dialBackedOff(PeerID)
}

// MARK: - AsyncSemaphore (C2)

/// Async-compatible counting semaphore for limiting concurrency.
internal final class AsyncSemaphore: Sendable {
    private let state: Mutex<SemaphoreState>

    private struct SemaphoreState: Sendable {
        var count: Int
        var waiters: [CheckedContinuation<Void, Never>]
        /// Once drained (e.g. at shutdown), all current and future waits resume
        /// immediately so no task hangs waiting on a semaphore that will never
        /// be signalled again.
        var isDrained: Bool = false
    }

    init(count: Int) {
        self.state = Mutex(SemaphoreState(count: count, waiters: []))
    }

    func wait() async {
        let shouldSuspend: Bool = state.withLock { state in
            if state.isDrained { return false }
            if state.count > 0 {
                state.count -= 1
                return false
            }
            return true
        }

        guard shouldSuspend else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeImmediately = state.withLock { state -> Bool in
                if state.isDrained {
                    return true
                }
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

    /// Resumes all currently suspended waiters and marks the semaphore drained
    /// so subsequent waits do not block. Called during shutdown so in-flight
    /// stream-negotiation tasks can observe cancellation instead of hanging.
    func drain() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { state in
            state.isDrained = true
            let pending = state.waiters
            state.waiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
