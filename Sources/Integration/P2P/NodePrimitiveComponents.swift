import P2PAutoNAT
import P2PCircuitRelay
import P2PCore
import P2PDCUtR
import P2PDiscovery
import P2PDiscoveryBeacon
import P2PDiscoveryCYCLON
import P2PDiscoveryMDNS
import P2PDiscoveryPlumtree
import P2PDiscoverySWIM
import P2PGossipSub
import P2PIdentify
import P2PKademlia
import P2PPlumtree
import P2PPing
import P2PProtocols

struct ServiceDescriptor<ServiceType: LifecycleService>: Sendable {
    let registration: ServiceRegistration<ServiceType>

    func component() -> ServiceComponent {
        registration.component()
    }

    func updating(
        _ update: (inout ServiceRegistration<ServiceType>) -> Void
    ) -> ServiceDescriptor<ServiceType> {
        var registration = registration
        update(&registration)
        return ServiceDescriptor(registration: registration)
    }
}

struct DiscoveryDescriptor<Source: DiscoveryService>: Sendable {
    let registration: DiscoveryRegistration<Source>

    func component() -> DiscoveryComponent {
        registration.component()
    }

    func updating(
        _ update: (inout DiscoveryRegistration<Source>) -> Void
    ) -> DiscoveryDescriptor<Source> {
        var registration = registration
        update(&registration)
        return DiscoveryDescriptor(registration: registration)
    }
}

public protocol ServiceNodeComponent: NodeComponent {
    associatedtype ServiceType: LifecycleService
    var servicePrimitive: Service<ServiceType> { get }
    init(servicePrimitive: Service<ServiceType>)
}

public extension ServiceNodeComponent {
    var nodeGroup: NodeGroup {
        servicePrimitive.nodeGroup
    }

    func handlesInboundStreams() -> Self where ServiceType: InboundProtocolHandler {
        Self(servicePrimitive: servicePrimitive.handlesInboundStreams())
    }

    func observesPeers() -> Self where ServiceType: PeerLifecycleObserver {
        Self(servicePrimitive: servicePrimitive.observesPeers())
    }

    func participatesInDiscovery() -> Self where ServiceType: DiscoverySource {
        Self(servicePrimitive: servicePrimitive.participatesInDiscovery())
    }

    func contributesListenAddresses() -> Self where ServiceType: ListenAddressContributor {
        Self(servicePrimitive: servicePrimitive.contributesListenAddresses())
    }

    func receivesStreamOpening() -> Self where ServiceType: StreamOpeningConsumer {
        Self(servicePrimitive: servicePrimitive.receivesStreamOpening())
    }

    func consumesLocalIdentity() -> Self where ServiceType: LocalIdentityConsumer {
        Self(servicePrimitive: servicePrimitive.consumesLocalIdentity())
    }

    func consumesListenAddresses() -> Self where ServiceType: ListenAddressConsumer {
        Self(servicePrimitive: servicePrimitive.consumesListenAddresses())
    }

    func consumesSupportedProtocols() -> Self where ServiceType: SupportedProtocolsConsumer {
        Self(servicePrimitive: servicePrimitive.consumesSupportedProtocols())
    }

    func activatesOnStart() -> Self {
        Self(servicePrimitive: servicePrimitive.activatesOnStart())
    }

    func activatesWithStreamOpening() -> Self where ServiceType: StreamOpeningActivatable {
        Self(servicePrimitive: servicePrimitive.activatesWithStreamOpening())
    }

    func preStart(
        _ startupHook: @escaping @Sendable (ServiceContext, ServiceType) async -> Void
    ) -> Self {
        Self(servicePrimitive: servicePrimitive.preStart(startupHook))
    }

    func postStart(
        _ startupHook: @escaping @Sendable (ServiceContext, ServiceType) async -> Void
    ) -> Self {
        Self(servicePrimitive: servicePrimitive.postStart(startupHook))
    }
}

public protocol DiscoveryNodeComponent: NodeComponent {
    associatedtype Source: DiscoveryService
    var discoveryPrimitive: Discovery<Source> { get }
    init(discoveryPrimitive: Discovery<Source>)
}

public extension DiscoveryNodeComponent {
    var nodeGroup: NodeGroup {
        discoveryPrimitive.nodeGroup
    }

    func weight(_ newWeight: Double) -> Self {
        Self(discoveryPrimitive: discoveryPrimitive.weight(newWeight))
    }

    func onStart(
        _ startupHook: @escaping @Sendable (Source) async -> Void
    ) -> Self {
        Self(discoveryPrimitive: discoveryPrimitive.onStart(startupHook))
    }

    func handlesInboundStreams() -> Self where Source: StreamService {
        Self(discoveryPrimitive: discoveryPrimitive.handlesInboundStreams())
    }

    func observesPeers() -> Self where Source: PeerObserver {
        Self(discoveryPrimitive: discoveryPrimitive.observesPeers())
    }

    func contributesListenAddresses() -> Self where Source: ListenAddressContributor {
        Self(discoveryPrimitive: discoveryPrimitive.contributesListenAddresses())
    }

    func receivesStreamOpening() -> Self {
        Self(discoveryPrimitive: discoveryPrimitive.receivesStreamOpening())
    }

    func consumesLocalIdentity() -> Self where Source: LocalIdentityConsumer {
        Self(discoveryPrimitive: discoveryPrimitive.consumesLocalIdentity())
    }

    func consumesListenAddresses() -> Self where Source: ListenAddressConsumer {
        Self(discoveryPrimitive: discoveryPrimitive.consumesListenAddresses())
    }

    func consumesSupportedProtocols() -> Self where Source: SupportedProtocolsConsumer {
        Self(discoveryPrimitive: discoveryPrimitive.consumesSupportedProtocols())
    }

    func activatesOnStart() -> Self {
        Self(discoveryPrimitive: discoveryPrimitive.activatesOnStart())
    }
}

public struct Service<ServiceType: LifecycleService>: ServiceNodeComponent {
    fileprivate let descriptor: ServiceDescriptor<ServiceType>

    public init(_ serviceInstance: ServiceType) {
        self.descriptor = ServiceDescriptor(
            registration: ServiceRegistration(serviceInstance)
        )
    }

    package init(
        makeService: @escaping @Sendable (ServiceContext) -> ServiceType
    ) {
        self.descriptor = ServiceDescriptor(
            registration: ServiceRegistration(makeService: makeService)
        )
    }

    fileprivate init(descriptor: ServiceDescriptor<ServiceType>) {
        self.descriptor = descriptor
    }

    public var servicePrimitive: Service<ServiceType> {
        self
    }

    public init(servicePrimitive: Service<ServiceType>) {
        self = servicePrimitive
    }

    public var nodeGroup: NodeGroup {
        NodeGroup {
            descriptor.component()
        }
    }
}

public extension Service {
    func handlesInboundStreams() -> Service where ServiceType: InboundProtocolHandler {
        Service(descriptor: descriptor.updating { $0.handlesInboundStreams() })
    }

    func observesPeers() -> Service where ServiceType: PeerLifecycleObserver {
        Service(descriptor: descriptor.updating { $0.observesPeers() })
    }

    func participatesInDiscovery() -> Service where ServiceType: DiscoverySource {
        Service(descriptor: descriptor.updating { $0.participatesInDiscovery() })
    }

    func contributesListenAddresses() -> Service where ServiceType: ListenAddressContributor {
        Service(descriptor: descriptor.updating { $0.contributesListenAddresses() })
    }

    func receivesStreamOpening() -> Service where ServiceType: StreamOpeningConsumer {
        Service(descriptor: descriptor.updating { $0.receivesStreamOpening() })
    }

    func consumesLocalIdentity() -> Service where ServiceType: LocalIdentityConsumer {
        Service(descriptor: descriptor.updating { $0.consumesLocalIdentity() })
    }

    func consumesListenAddresses() -> Service where ServiceType: ListenAddressConsumer {
        Service(descriptor: descriptor.updating { $0.consumesListenAddresses() })
    }

    func consumesSupportedProtocols() -> Service where ServiceType: SupportedProtocolsConsumer {
        Service(descriptor: descriptor.updating { $0.consumesSupportedProtocols() })
    }

    func activatesOnStart() -> Service {
        Service(descriptor: descriptor.updating { $0.activatesOnStart() })
    }

    func activatesWithStreamOpening() -> Service where ServiceType: StreamOpeningActivatable {
        Service(descriptor: descriptor.updating { $0.activatesWithStreamOpening() })
    }

    func preStart(
        _ startupHook: @escaping @Sendable (ServiceContext, ServiceType) async -> Void
    ) -> Service {
        Service(descriptor: descriptor.updating { $0.preStart(startupHook) })
    }

    func postStart(
        _ startupHook: @escaping @Sendable (ServiceContext, ServiceType) async -> Void
    ) -> Service {
        Service(descriptor: descriptor.updating { $0.postStart(startupHook) })
    }
}

public struct Discovery<Source: DiscoveryService>: DiscoveryNodeComponent {
    fileprivate let descriptor: DiscoveryDescriptor<Source>

    public init(_ source: Source) {
        self.descriptor = DiscoveryDescriptor(
            registration: DiscoveryRegistration(source)
        )
    }

    package init(
        weight: Double = 1.0,
        makeSource: @escaping @Sendable (PeerID) -> Source,
        startup: (@Sendable (Source) async -> Void)? = nil
    ) {
        self.descriptor = DiscoveryDescriptor(
            registration: DiscoveryRegistration(
                weight: weight,
                makeSource: makeSource,
                startup: startup
            )
        )
    }

    fileprivate init(descriptor: DiscoveryDescriptor<Source>) {
        self.descriptor = descriptor
    }

    public var discoveryPrimitive: Discovery<Source> {
        self
    }

    public init(discoveryPrimitive: Discovery<Source>) {
        self = discoveryPrimitive
    }

    public var nodeGroup: NodeGroup {
        NodeGroup {
            descriptor.component()
        }
    }
}

public extension Discovery {
    func weight(_ newWeight: Double) -> Discovery {
        Discovery(descriptor: descriptor.updating { $0.setWeight(newWeight) })
    }

    func onStart(
        _ startupHook: @escaping @Sendable (Source) async -> Void
    ) -> Discovery {
        Discovery(descriptor: descriptor.updating { $0.onStart(startupHook) })
    }

    func handlesInboundStreams() -> Discovery where Source: StreamService {
        Discovery(descriptor: descriptor.updating {
            $0.declareInboundProtocolIDs { $0.protocolIDs }
        })
    }

    func observesPeers() -> Discovery where Source: PeerObserver {
        Discovery(descriptor: descriptor.updating { $0.observesPeerLifecycle() })
    }

    func contributesListenAddresses() -> Discovery where Source: ListenAddressContributor {
        Discovery(descriptor: descriptor.updating { $0.publishesListenAddresses() })
    }

    func receivesStreamOpening() -> Discovery {
        Discovery(descriptor: descriptor.updating { $0.receivesStreamOpening() })
    }

    func consumesLocalIdentity() -> Discovery where Source: LocalIdentityConsumer {
        Discovery(descriptor: descriptor.updating { $0.requiresIdentity() })
    }

    func consumesListenAddresses() -> Discovery where Source: ListenAddressConsumer {
        Discovery(descriptor: descriptor.updating { $0.requiresListenAddresses() })
    }

    func consumesSupportedProtocols() -> Discovery where Source: SupportedProtocolsConsumer {
        Discovery(descriptor: descriptor.updating { $0.requiresSupportedProtocols() })
    }

    func activatesOnStart() -> Discovery {
        Discovery(descriptor: descriptor.updating { $0.activatesOnRuntimeStart() })
    }
}

public struct Ping: ServiceNodeComponent {
    public let servicePrimitive: Service<PingService>

    private static func defaults(_ primitive: Service<PingService>) -> Service<PingService> {
        primitive.handlesInboundStreams()
    }

    public init(_ pingService: PingService = PingService()) {
        self.servicePrimitive = Self.defaults(Service(pingService))
    }

    public init(servicePrimitive: Service<PingService>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct Identify: ServiceNodeComponent {
    public let servicePrimitive: Service<IdentifyService>

    private static func defaults(_ primitive: Service<IdentifyService>) -> Service<IdentifyService> {
        primitive
            .handlesInboundStreams()
            .observesPeers()
            .consumesLocalIdentity()
            .consumesListenAddresses()
            .consumesSupportedProtocols()
            .activatesWithStreamOpening()
    }

    public init(_ identifyService: IdentifyService) {
        self.servicePrimitive = Self.defaults(Service(identifyService))
    }

    public init(configuration: IdentifyConfiguration = .init()) {
        self.servicePrimitive = Self.defaults(Service(makeService: { context in
            IdentifyService(
                configuration: configuration,
                localIdentity: context.localIdentity,
                listenAddressContext: context.listenAddresses,
                supportedProtocolsContext: context.supportedProtocols,
                streamOpener: context.streamOpener
            )
        }))
        .activatesOnStart()
    }

    public init(servicePrimitive: Service<IdentifyService>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct RelayServer: ServiceNodeComponent {
    public let servicePrimitive: Service<P2PCircuitRelay.RelayServer>

    private static func defaults(
        _ primitive: Service<P2PCircuitRelay.RelayServer>
    ) -> Service<P2PCircuitRelay.RelayServer> {
        primitive
            .handlesInboundStreams()
            .receivesStreamOpening()
            .consumesLocalIdentity()
            .consumesListenAddresses()
    }

    public init(_ relayServer: P2PCircuitRelay.RelayServer) {
        self.servicePrimitive = Self.defaults(Service(relayServer))
    }

    public init(configuration: P2PCircuitRelay.RelayServerConfiguration = .init()) {
        self.servicePrimitive = Self.defaults(Service(makeService: { context in
            P2PCircuitRelay.RelayServer(
                configuration: configuration,
                streamOpener: context.streamOpener,
                identityContext: context.localIdentity,
                listenAddressContext: context.listenAddresses
            )
        }))
    }

    public init(servicePrimitive: Service<P2PCircuitRelay.RelayServer>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct GossipSub: ServiceNodeComponent {
    public let servicePrimitive: Service<GossipSubService>

    private static func defaults(_ primitive: Service<GossipSubService>) -> Service<GossipSubService> {
        primitive
            .handlesInboundStreams()
            .observesPeers()
            .activatesWithStreamOpening()
    }

    public init(_ gossipSubService: GossipSubService) {
        self.servicePrimitive = Self.defaults(Service(gossipSubService))
    }

    public init(configuration: GossipSubConfiguration = .init()) {
        self.servicePrimitive = Self.defaults(Service(makeService: { context in
            GossipSubService(
                keyPair: context.localIdentity.localKeyPair,
                configuration: configuration,
                opener: context.streamOpener
            )
        }))
        .activatesOnStart()
    }

    public init(servicePrimitive: Service<GossipSubService>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct Plumtree: ServiceNodeComponent {
    public let servicePrimitive: Service<PlumtreeService>

    private static func defaults(_ primitive: Service<PlumtreeService>) -> Service<PlumtreeService> {
        primitive
            .handlesInboundStreams()
            .observesPeers()
            .activatesWithStreamOpening()
    }

    public init(_ plumtreeService: PlumtreeService) {
        self.servicePrimitive = Self.defaults(Service(plumtreeService))
    }

    public init(configuration: PlumtreeConfiguration = .default) {
        self.servicePrimitive = Self.defaults(Service(makeService: { context in
            PlumtreeService(
                localPeerID: context.localIdentity.localPeer,
                configuration: configuration,
                opener: context.streamOpener
            )
        }))
        .activatesOnStart()
    }

    public init(servicePrimitive: Service<PlumtreeService>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct DCUtR: ServiceNodeComponent {
    public let servicePrimitive: Service<DCUtRService>

    private static func defaults(_ primitive: Service<DCUtRService>) -> Service<DCUtRService> {
        primitive.handlesInboundStreams()
    }

    public init(_ dcutrService: DCUtRService) {
        self.servicePrimitive = Self.defaults(Service(dcutrService))
            .postStart { context, service in
                let addresses = await context.listenAddresses.listenAddresses()
                service.setLocalAddressProvider { addresses }
                service.setDialer { address in
                    _ = try await context.addressDialer.connect(to: address)
                }
            }
    }

    public init(configuration: DCUtRConfiguration = .init()) {
        self.servicePrimitive = Self.defaults(Service(makeService: { _ in
            DCUtRService(configuration: configuration)
        }))
        .postStart { context, service in
            let addresses = await context.listenAddresses.listenAddresses()
            service.setLocalAddressProvider { addresses }
            service.setDialer { address in
                _ = try await context.addressDialer.connect(to: address)
            }
        }
    }

    public init(servicePrimitive: Service<DCUtRService>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct Kademlia: ServiceNodeComponent {
    public let servicePrimitive: Service<KademliaService>

    private static func defaults(_ primitive: Service<KademliaService>) -> Service<KademliaService> {
        primitive
            .handlesInboundStreams()
            .activatesWithStreamOpening()
    }

    public init(_ kademliaService: KademliaService) {
        self.servicePrimitive = Self.defaults(Service(kademliaService))
    }

    public init(configuration: KademliaConfiguration = .default) {
        self.servicePrimitive = Self.defaults(Service(makeService: { context in
            KademliaService(
                localPeerID: context.localIdentity.localPeer,
                configuration: configuration,
                opener: context.streamOpener
            )
        }))
        .activatesOnStart()
    }

    public init(servicePrimitive: Service<KademliaService>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct AutoRelay: ServiceNodeComponent {
    public let servicePrimitive: Service<AutoRelayService>

    private static func defaults(_ primitive: Service<AutoRelayService>) -> Service<AutoRelayService> {
        primitive
            .contributesListenAddresses()
            .observesPeers()
            .activatesWithStreamOpening()
    }

    public init(_ autoRelayService: AutoRelayService) {
        self.servicePrimitive = Self.defaults(Service(autoRelayService))
    }

    public init(
        autoNAT: AutoNATService,
        relayClient: RelayClient,
        configuration: AutoRelayServiceConfiguration = .init()
    ) {
        self.servicePrimitive = Self.defaults(Service(makeService: { context in
            AutoRelayService(
                autoNAT: autoNAT,
                relayClient: relayClient,
                localPeer: context.localIdentity.localPeer,
                configuration: configuration,
                streamOpener: context.streamOpener
            )
        }))
        .activatesOnStart()
    }

    public init(servicePrimitive: Service<AutoRelayService>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct Supernode: ServiceNodeComponent {
    public let servicePrimitive: Service<SupernodeService>

    private static func defaults(_ primitive: Service<SupernodeService>) -> Service<SupernodeService> {
        primitive
            .observesPeers()
            .activatesOnStart()
    }

    public init(_ supernodeService: SupernodeService) {
        self.servicePrimitive = Self.defaults(Service(supernodeService))
    }

    public init(
        autoNAT: AutoNATService,
        relayServer: P2PCircuitRelay.RelayServer,
        configuration: SupernodeServiceConfiguration = .init()
    ) {
        self.servicePrimitive = Self.defaults(Service(
            SupernodeService(
                autoNAT: autoNAT,
                relayServer: relayServer,
                configuration: configuration
            )
        ))
    }

    public init(servicePrimitive: Service<SupernodeService>) {
        self.servicePrimitive = servicePrimitive
    }
}

public struct MDNS: DiscoveryNodeComponent {
    public let discoveryPrimitive: Discovery<MDNSDiscovery>

    private static func defaults(_ primitive: Discovery<MDNSDiscovery>) -> Discovery<MDNSDiscovery> {
        primitive.onStart { service in
            do {
                try await service.start()
            } catch {
            }
        }
    }

    public init(configuration: MDNSConfiguration = .default) {
        self.discoveryPrimitive = Self.defaults(Discovery(weight: 1.0, makeSource: { localPeerID in
            MDNSDiscovery(localPeerID: localPeerID, configuration: configuration)
        }))
    }

    public init(discoveryPrimitive: Discovery<MDNSDiscovery>) {
        self.discoveryPrimitive = discoveryPrimitive
    }
}

public struct SWIM: DiscoveryNodeComponent {
    public let discoveryPrimitive: Discovery<SWIMMembership>

    private static func defaults(_ primitive: Discovery<SWIMMembership>) -> Discovery<SWIMMembership> {
        primitive.onStart { service in
            do {
                try await service.start()
            } catch {
            }
        }
    }

    public init(configuration: SWIMMembershipConfiguration = .default) {
        self.discoveryPrimitive = Self.defaults(Discovery(weight: 1.0, makeSource: { localPeerID in
            SWIMMembership(localPeerID: localPeerID, configuration: configuration)
        }))
    }

    public init(discoveryPrimitive: Discovery<SWIMMembership>) {
        self.discoveryPrimitive = discoveryPrimitive
    }
}

public struct CYCLON: DiscoveryNodeComponent {
    public let discoveryPrimitive: Discovery<CYCLONDiscovery>

    private static func defaults(_ primitive: Discovery<CYCLONDiscovery>) -> Discovery<CYCLONDiscovery> {
        primitive
            .handlesInboundStreams()
            .activatesOnStart()
            .receivesStreamOpening()
    }

    public init(configuration: CYCLONConfiguration = .default) {
        self.discoveryPrimitive = Self.defaults(Discovery(weight: 1.0, makeSource: { localPeerID in
            CYCLONDiscovery(localPeerID: localPeerID, configuration: configuration)
        }))
    }

    public init(discoveryPrimitive: Discovery<CYCLONDiscovery>) {
        self.discoveryPrimitive = discoveryPrimitive
    }
}

public struct PlumtreeDiscovery: DiscoveryNodeComponent {
    public let discoveryPrimitive: Discovery<P2PDiscoveryPlumtree.PlumtreeDiscovery>

    private static func defaults(
        _ primitive: Discovery<P2PDiscoveryPlumtree.PlumtreeDiscovery>
    ) -> Discovery<P2PDiscoveryPlumtree.PlumtreeDiscovery> {
        primitive
            .handlesInboundStreams()
            .observesPeers()
            .activatesOnStart()
            .receivesStreamOpening()
    }

    public init(configuration: PlumtreeDiscoveryConfiguration = .default) {
        self.discoveryPrimitive = Self.defaults(Discovery(weight: 1.0, makeSource: { localPeerID in
            P2PDiscoveryPlumtree.PlumtreeDiscovery(localPeerID: localPeerID, configuration: configuration)
        }))
    }

    public init(discoveryPrimitive: Discovery<P2PDiscoveryPlumtree.PlumtreeDiscovery>) {
        self.discoveryPrimitive = discoveryPrimitive
    }
}

public struct Beacon: DiscoveryNodeComponent {
    public let discoveryPrimitive: Discovery<BeaconDiscovery>

    private static func defaults(_ primitive: Discovery<BeaconDiscovery>) -> Discovery<BeaconDiscovery> {
        primitive.onStart { service in
            service.start()
        }
    }

    public init(configuration: BeaconDiscoveryConfiguration) {
        self.discoveryPrimitive = Self.defaults(Discovery(weight: 1.0, makeSource: { localPeerID in
            precondition(
                configuration.keyPair.peerID == localPeerID,
                "BeaconDiscovery configuration keyPair must match DiscoveryPipeline localPeerID"
            )
            return BeaconDiscovery(configuration: configuration)
        }))
    }

    public init(discoveryPrimitive: Discovery<BeaconDiscovery>) {
        self.discoveryPrimitive = discoveryPrimitive
    }
}
