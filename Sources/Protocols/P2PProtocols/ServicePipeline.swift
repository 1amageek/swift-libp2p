import P2PCore
import P2PDiscovery
import P2PMux

public typealias InboundProtocolHandler = StreamService
public typealias PeerLifecycleObserver = PeerObserver
public typealias DiscoverySource = DiscoveryService
public typealias StreamOpening = StreamOpener
public typealias LocalIdentityProviding = NodeIdentityContext
public typealias ListenAddressProviding = ListenAddressContext
public typealias SupportedProtocolProviding = SupportedProtocolsContext
public typealias PeerStoreProviding = PeerStoreContext
public typealias AddressDialing = AddressDialer

public struct ServiceContext: Sendable {
    public let localIdentity: any LocalIdentityProviding
    public let listenAddresses: any ListenAddressProviding
    public let supportedProtocols: any SupportedProtocolProviding
    public let peerStore: any PeerStoreProviding
    public let streamOpener: any StreamOpening
    public let addressDialer: any AddressDialing

    public init(
        localIdentity: any LocalIdentityProviding,
        listenAddresses: any ListenAddressProviding,
        supportedProtocols: any SupportedProtocolProviding,
        peerStore: any PeerStoreProviding,
        streamOpener: any StreamOpening,
        addressDialer: any AddressDialing
    ) {
        self.localIdentity = localIdentity
        self.listenAddresses = listenAddresses
        self.supportedProtocols = supportedProtocols
        self.peerStore = peerStore
        self.streamOpener = streamOpener
        self.addressDialer = addressDialer
    }
}

public struct RuntimeServices: Sendable {
    public let lifecycleServices: [any LifecycleService]
    public let inboundHandlers: [any InboundProtocolHandler]
    public let peerObservers: [any PeerLifecycleObserver]
    public let discoverySources: [any DiscoverySource]
    public let listenAddressContributors: [any ListenAddressContributor]
    public let preStartActions: [@Sendable () async -> Void]
    public let postStartActions: [@Sendable () async throws -> Void]

    public static let empty = RuntimeServices(
        lifecycleServices: [],
        inboundHandlers: [],
        peerObservers: [],
        discoverySources: [],
        listenAddressContributors: [],
        preStartActions: [],
        postStartActions: []
    )

    public init(
        lifecycleServices: [any LifecycleService],
        inboundHandlers: [any InboundProtocolHandler],
        peerObservers: [any PeerLifecycleObserver],
        discoverySources: [any DiscoverySource],
        listenAddressContributors: [any ListenAddressContributor],
        preStartActions: [@Sendable () async -> Void],
        postStartActions: [@Sendable () async throws -> Void]
    ) {
        self.lifecycleServices = lifecycleServices
        self.inboundHandlers = inboundHandlers
        self.peerObservers = peerObservers
        self.discoverySources = discoverySources
        self.listenAddressContributors = listenAddressContributors
        self.preStartActions = preStartActions
        self.postStartActions = postStartActions
    }

    public func merging(_ other: RuntimeServices) -> RuntimeServices {
        RuntimeServices(
            lifecycleServices: lifecycleServices + other.lifecycleServices,
            inboundHandlers: inboundHandlers + other.inboundHandlers,
            peerObservers: peerObservers + other.peerObservers,
            discoverySources: discoverySources + other.discoverySources,
            listenAddressContributors: listenAddressContributors + other.listenAddressContributors,
            preStartActions: preStartActions + other.preStartActions,
            postStartActions: postStartActions + other.postStartActions
        )
    }
}

public struct ServiceRuntimeRequirements: Sendable {
    public var receivesStreamOpening: Bool
    public var consumesLocalIdentity: Bool
    public var consumesListenAddresses: Bool
    public var consumesSupportedProtocols: Bool
    public var activatesOnStart: Bool

    public static let empty = ServiceRuntimeRequirements()

    public init(
        receivesStreamOpening: Bool = false,
        consumesLocalIdentity: Bool = false,
        consumesListenAddresses: Bool = false,
        consumesSupportedProtocols: Bool = false,
        activatesOnStart: Bool = false
    ) {
        self.receivesStreamOpening = receivesStreamOpening
        self.consumesLocalIdentity = consumesLocalIdentity
        self.consumesListenAddresses = consumesListenAddresses
        self.consumesSupportedProtocols = consumesSupportedProtocols
        self.activatesOnStart = activatesOnStart
    }
}

public struct ServiceComponent: Sendable {
    package let resolver: @Sendable (ServiceContext) -> RuntimeServices

    package init(
        resolver: @escaping @Sendable (ServiceContext) -> RuntimeServices
    ) {
        self.resolver = resolver
    }
}

@resultBuilder
public enum ServicePipelineBuilder {
    public static func buildBlock() -> [ServiceComponent] {
        []
    }

    public static func buildBlock(_ components: [ServiceComponent]...) -> [ServiceComponent] {
        components.flatMap { $0 }
    }

    public static func buildArray(_ components: [[ServiceComponent]]) -> [ServiceComponent] {
        components.flatMap { $0 }
    }

    public static func buildEither(first component: [ServiceComponent]) -> [ServiceComponent] {
        component
    }

    public static func buildEither(second component: [ServiceComponent]) -> [ServiceComponent] {
        component
    }

    public static func buildExpression(_ component: ServiceComponent) -> [ServiceComponent] {
        [component]
    }

    public static func buildExpression(_ components: [ServiceComponent]) -> [ServiceComponent] {
        components
    }

    public static func buildOptional(_ component: [ServiceComponent]?) -> [ServiceComponent] {
        component ?? []
    }
}

public struct ServicePipeline: Sendable {
    private let components: [ServiceComponent]

    public init(@ServicePipelineBuilder _ content: () -> [ServiceComponent]) {
        self.components = content()
    }

    public static let empty = ServicePipeline {}

    package func resolve(context: ServiceContext) -> RuntimeServices {
        components.reduce(.empty) { partial, component in
            partial.merging(component.resolver(context))
        }
    }
}

public struct ServiceRegistration<Service: LifecycleService>: Sendable {
    private typealias InboundHandlerResolver = @Sendable (Service) -> any InboundProtocolHandler
    private typealias PeerObserverResolver = @Sendable (Service) -> any PeerLifecycleObserver
    private typealias DiscoverySourceResolver = @Sendable (Service) -> any DiscoverySource
    private typealias ListenAddressContributorResolver = @Sendable (Service) -> any ListenAddressContributor

    private let makeService: @Sendable (ServiceContext) -> Service
    private let inboundHandlerResolver: InboundHandlerResolver?
    private let peerObserverResolver: PeerObserverResolver?
    private let discoverySourceResolver: DiscoverySourceResolver?
    private let listenAddressContributorResolver: ListenAddressContributorResolver?
    private let runtimeRequirements: ServiceRuntimeRequirements
    private let preStartHooks: [@Sendable (ServiceContext, Service) async -> Void]
    private let postStartHooks: [@Sendable (ServiceContext, Service) async -> Void]
    public private(set) var defaultsApplied: Bool

    public init(_ service: Service) {
        self.makeService = { _ in service }
        self.inboundHandlerResolver = nil
        self.peerObserverResolver = nil
        self.discoverySourceResolver = nil
        self.listenAddressContributorResolver = nil
        self.runtimeRequirements = .empty
        self.preStartHooks = []
        self.postStartHooks = []
        self.defaultsApplied = false
    }

    package init(makeService: @escaping @Sendable (ServiceContext) -> Service) {
        self.makeService = makeService
        self.inboundHandlerResolver = nil
        self.peerObserverResolver = nil
        self.discoverySourceResolver = nil
        self.listenAddressContributorResolver = nil
        self.runtimeRequirements = .empty
        self.preStartHooks = []
        self.postStartHooks = []
        self.defaultsApplied = false
    }

    private init(
        makeService: @escaping @Sendable (ServiceContext) -> Service,
        inboundHandlerResolver: InboundHandlerResolver?,
        peerObserverResolver: PeerObserverResolver?,
        discoverySourceResolver: DiscoverySourceResolver?,
        listenAddressContributorResolver: ListenAddressContributorResolver?,
        runtimeRequirements: ServiceRuntimeRequirements,
        preStartHooks: [@Sendable (ServiceContext, Service) async -> Void],
        postStartHooks: [@Sendable (ServiceContext, Service) async -> Void],
        defaultsApplied: Bool
    ) {
        self.makeService = makeService
        self.inboundHandlerResolver = inboundHandlerResolver
        self.peerObserverResolver = peerObserverResolver
        self.discoverySourceResolver = discoverySourceResolver
        self.listenAddressContributorResolver = listenAddressContributorResolver
        self.runtimeRequirements = runtimeRequirements
        self.preStartHooks = preStartHooks
        self.postStartHooks = postStartHooks
        self.defaultsApplied = defaultsApplied
    }

    package func component() -> ServiceComponent {
        ServiceComponent { context in
            let service = makeService(context)
            var preStartActions: [@Sendable () async -> Void] = []
            var postStartActions: [@Sendable () async throws -> Void] = []
            let streamOpeningActivatable =
                runtimeRequirements.receivesStreamOpening && runtimeRequirements.activatesOnStart
                ? (service as? any StreamOpeningActivatable)
                : nil
            if runtimeRequirements.receivesStreamOpening && streamOpeningActivatable == nil {
                let openerConsumer = requireServiceCapability(
                    service,
                    as: (any StreamOpeningConsumer).self,
                    role: "receives stream opening"
                )
                preStartActions.append {
                    await openerConsumer.attachStreamOpening(context.streamOpener)
                }
            }
            if runtimeRequirements.consumesLocalIdentity {
                let identityConsumer = requireServiceCapability(
                    service,
                    as: (any LocalIdentityConsumer).self,
                    role: "consumes local identity"
                )
                preStartActions.append {
                    await identityConsumer.attachIdentityContext(context.localIdentity)
                }
            }
            if runtimeRequirements.consumesListenAddresses {
                let listenAddressConsumer = requireServiceCapability(
                    service,
                    as: (any ListenAddressConsumer).self,
                    role: "consumes listen addresses"
                )
                postStartActions.append {
                    await listenAddressConsumer.attachListenAddressContext(context.listenAddresses)
                }
            }
            if runtimeRequirements.consumesSupportedProtocols {
                let supportedProtocolsConsumer = requireServiceCapability(
                    service,
                    as: (any SupportedProtocolsConsumer).self,
                    role: "consumes supported protocols"
                )
                preStartActions.append {
                    await supportedProtocolsConsumer.attachSupportedProtocolsContext(context.supportedProtocols)
                }
            }
            if let streamOpeningActivatable {
                postStartActions.append {
                    await streamOpeningActivatable.activate(using: context.streamOpener)
                }
            } else if runtimeRequirements.activatesOnStart {
                let activatableService = requireServiceCapability(
                    service,
                    as: (any ActivatableService).self,
                    role: "activates on start"
                )
                postStartActions.append {
                    await activatableService.activate()
                }
            }
            if !preStartHooks.isEmpty {
                preStartActions.append {
                    for hook in preStartHooks {
                        await hook(context, service)
                    }
                }
            }
            if !postStartHooks.isEmpty {
                postStartActions.append {
                    for hook in postStartHooks {
                        await hook(context, service)
                    }
                }
            }
            return RuntimeServices(
                lifecycleServices: [service],
                inboundHandlers: inboundHandlerResolver.map { [$0(service)] } ?? [],
                peerObservers: peerObserverResolver.map { [$0(service)] } ?? [],
                discoverySources: discoverySourceResolver.map { [$0(service)] } ?? [],
                listenAddressContributors: listenAddressContributorResolver.map { [$0(service)] } ?? [],
                preStartActions: preStartActions,
                postStartActions: postStartActions
            )
        }
    }

    private func updating(
        inboundHandlerResolver: InboundHandlerResolver?? = nil,
        peerObserverResolver: PeerObserverResolver?? = nil,
        discoverySourceResolver: DiscoverySourceResolver?? = nil,
        listenAddressContributorResolver: ListenAddressContributorResolver?? = nil,
        runtimeRequirements: ServiceRuntimeRequirements? = nil,
        appendingPreStartHook: (@Sendable (ServiceContext, Service) async -> Void)? = nil,
        appendingPostStartHook: (@Sendable (ServiceContext, Service) async -> Void)? = nil,
        defaultsApplied: Bool? = nil
    ) -> ServiceRegistration<Service> {
        var preHooks = preStartHooks
        var postHooks = postStartHooks
        if let appendingPreStartHook {
            preHooks.append(appendingPreStartHook)
        }
        if let appendingPostStartHook {
            postHooks.append(appendingPostStartHook)
        }
        return ServiceRegistration<Service>(
            makeService: makeService,
            inboundHandlerResolver: inboundHandlerResolver ?? self.inboundHandlerResolver,
            peerObserverResolver: peerObserverResolver ?? self.peerObserverResolver,
            discoverySourceResolver: discoverySourceResolver ?? self.discoverySourceResolver,
            listenAddressContributorResolver: listenAddressContributorResolver ?? self.listenAddressContributorResolver,
            runtimeRequirements: runtimeRequirements ?? self.runtimeRequirements,
            preStartHooks: preHooks,
            postStartHooks: postHooks,
            defaultsApplied: defaultsApplied ?? self.defaultsApplied
        )
    }
}

package extension ServiceRegistration {
    mutating func markDefaultsApplied() {
        self = updating(defaultsApplied: true)
    }
}

private func requireServiceCapability<Capability>(
    _ service: some LifecycleService,
    as capability: Capability.Type,
    role: String
) -> Capability {
    guard let capability = service as? Capability else {
        preconditionFailure(
            "Service component declared runtime role '\(role)' but \(type(of: service)) does not conform to \(Capability.self)"
        )
    }
    return capability
}

package func service<Service: LifecycleService>(
    _ service: Service,
    configure: (inout ServiceRegistration<Service>) -> Void = { _ in }
) -> ServiceComponent {
    var factory = ServiceRegistration(service)
    configure(&factory)
    return factory.component()
}

package func service<Service: LifecycleService>(
    make makeService: @escaping @Sendable (ServiceContext) -> Service,
    configure: (inout ServiceRegistration<Service>) -> Void = { _ in }
) -> ServiceComponent {
    var factory = ServiceRegistration(makeService: makeService)
    configure(&factory)
    return factory.component()
}

public extension ServiceRegistration where Service: InboundProtocolHandler {
    mutating func handlesInboundStreams() {
        self = updating(inboundHandlerResolver: { $0 })
    }
}

public extension ServiceRegistration where Service: PeerLifecycleObserver {
    mutating func observesPeers() {
        self = updating(peerObserverResolver: { $0 })
    }
}

public extension ServiceRegistration where Service: DiscoverySource {
    mutating func participatesInDiscovery() {
        self = updating(discoverySourceResolver: { $0 })
    }
}

public extension ServiceRegistration where Service: ListenAddressContributor {
    mutating func contributesListenAddresses() {
        self = updating(listenAddressContributorResolver: { $0 })
    }
}

package extension ServiceRegistration {
    mutating func preStart(
        _ startupHook: @escaping @Sendable (ServiceContext, Service) async -> Void
    ) {
        self = updating(appendingPreStartHook: startupHook)
    }

    mutating func postStart(
        _ startupHook: @escaping @Sendable (ServiceContext, Service) async -> Void
    ) {
        self = updating(appendingPostStartHook: startupHook)
    }

    mutating func onStart(
        _ startupHook: @escaping @Sendable (ServiceContext, Service) async -> Void
    ) {
        postStart(startupHook)
    }
}

public extension ServiceRegistration where Service: StreamOpeningConsumer {
    mutating func receivesStreamOpening() {
        var requirements = runtimeRequirements
        requirements.receivesStreamOpening = true
        self = updating(runtimeRequirements: requirements)
    }
}

public extension ServiceRegistration where Service: LocalIdentityConsumer {
    mutating func consumesLocalIdentity() {
        var requirements = runtimeRequirements
        requirements.consumesLocalIdentity = true
        self = updating(runtimeRequirements: requirements)
    }
}

public extension ServiceRegistration where Service: ListenAddressConsumer {
    mutating func consumesListenAddresses() {
        var requirements = runtimeRequirements
        requirements.consumesListenAddresses = true
        self = updating(runtimeRequirements: requirements)
    }
}

public extension ServiceRegistration where Service: SupportedProtocolsConsumer {
    mutating func consumesSupportedProtocols() {
        var requirements = runtimeRequirements
        requirements.consumesSupportedProtocols = true
        self = updating(runtimeRequirements: requirements)
    }
}

public extension ServiceRegistration {
    mutating func activatesOnStart() {
        var requirements = runtimeRequirements
        requirements.activatesOnStart = true
        self = updating(runtimeRequirements: requirements)
    }
}

public extension ServiceRegistration where Service: StreamOpeningActivatable {
    mutating func activatesWithStreamOpening() {
        var requirements = runtimeRequirements
        requirements.receivesStreamOpening = true
        requirements.activatesOnStart = true
        self = updating(runtimeRequirements: requirements)
    }
}
