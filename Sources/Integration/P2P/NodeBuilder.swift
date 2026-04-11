import Foundation
import P2PCore
import P2PDiscovery
import P2PMux
import P2PProtocols
import P2PRuntime
import P2PSecurity
import P2PTransport

public struct NodeBuilder: Sendable {
    public let runtime: RuntimeConfiguration
    public var keyPair: KeyPair { runtime.keyPair }
    public var listenAddresses: [Multiaddr] { runtime.listenAddresses }
    public var connectionProviders: [any ConnectionProvider] { runtime.connectionProviders }
    public var pool: PoolConfiguration { runtime.pool }
    public let healthCheck: HealthMonitorConfiguration?
    public let discoveryConfig: DiscoveryConfiguration
    public let peerStore: (any PeerStore)?
    public let addressBookConfig: AddressBookConfiguration?
    public let bootstrap: BootstrapConfiguration?
    public let protoBook: (any ProtoBook)?
    public let keyBook: (any KeyBook)?
    public let resourceManager: (any ResourceManager)?
    public let traversal: TraversalConfiguration?
    public var maxNegotiatingInboundStreams: Int { runtime.maxNegotiatingInboundStreams }

    private let serviceComponents: [ServiceComponent]
    private let discoveryComponents: [DiscoveryComponent]

    public init(
        runtime: RuntimeConfiguration = .init(),
        healthCheck: HealthMonitorConfiguration? = .default,
        discoveryConfig: DiscoveryConfiguration = .default,
        peerStore: (any PeerStore)? = nil,
        addressBookConfig: AddressBookConfiguration? = nil,
        bootstrap: BootstrapConfiguration? = nil,
        protoBook: (any ProtoBook)? = nil,
        keyBook: (any KeyBook)? = nil,
        resourceManager: (any ResourceManager)? = nil,
        traversal: TraversalConfiguration? = nil,
        @ServicePipelineBuilder services: () -> [ServiceComponent] = { [] },
        @DiscoveryPipelineBuilder discovery: () -> [DiscoveryComponent] = { [] }
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
        self.serviceComponents = services()
        self.discoveryComponents = discovery()
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
        resourceManager: (any ResourceManager)? = nil,
        traversal: TraversalConfiguration? = nil,
        maxNegotiatingInboundStreams: Int = 128,
        @ServicePipelineBuilder services: () -> [ServiceComponent] = { [] },
        @DiscoveryPipelineBuilder discovery: () -> [DiscoveryComponent] = { [] }
    ) {
        self.init(
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
            services: services,
            discovery: discovery
        )
    }

    public func configuration() -> NodeConfiguration {
        let discoveryPipeline: DiscoveryPipeline?
        if discoveryComponents.isEmpty {
            discoveryPipeline = nil
        } else {
            discoveryPipeline = DiscoveryPipeline(
                localPeerID: keyPair.peerID
            ) {
                discoveryComponents
            }
        }

        return NodeConfiguration(
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
            services: ServicePipeline {
                serviceComponents
            },
            discovery: discoveryPipeline
        )
    }

    public func build() -> Node {
        Node(configuration: configuration())
    }
}
