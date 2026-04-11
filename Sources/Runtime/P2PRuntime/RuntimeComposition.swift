import P2PDiscovery
import P2PProtocols

package protocol RuntimeCapabilitySource:
    LocalIdentityProviding,
    ListenAddressProviding,
    SupportedProtocolProviding,
    PeerStoreProviding,
    StreamOpening,
    AddressDialing
{}

public struct RuntimeComposition: Sendable {
    public let services: RuntimeServices
    public let discoverySources: [any DiscoveryService]
    public let preStartActions: [@Sendable () async -> Void]
    public let postStartActions: [@Sendable () async -> Void]

    public init(
        services: RuntimeServices,
        discoverySources: [any DiscoveryService],
        preStartActions: [@Sendable () async -> Void],
        postStartActions: [@Sendable () async -> Void]
    ) {
        self.services = services
        self.discoverySources = discoverySources
        self.preStartActions = preStartActions
        self.postStartActions = postStartActions
    }

    package static func resolve(
        services pipeline: ServicePipeline,
        context: ServiceContext,
        discovery discoveryPipeline: DiscoveryPipeline?
    ) -> RuntimeComposition {
        var services = pipeline.resolve(context: context)
        var discoverySources = services.discoverySources
        var preStartActions = services.preStartActions
        var postStartActions = services.postStartActions

        if let discoveryPipeline {
            let discoveryRuntimeServices = discoveryPipeline.runtimeServices(context: context)
            services = services.merging(discoveryRuntimeServices)
            preStartActions = services.preStartActions
            postStartActions = services.postStartActions
            postStartActions.append {
                await discoveryPipeline.start()
            }
            discoverySources.append(discoveryPipeline)
        }

        return RuntimeComposition(
            services: services,
            discoverySources: discoverySources,
            preStartActions: preStartActions,
            postStartActions: postStartActions
        )
    }
}
