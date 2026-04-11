import Foundation
import P2PCore
import P2PDiscovery
import P2PProtocols

extension DiscoveryPipeline {
    package func runtimeServices(context: ServiceContext) -> RuntimeServices {
        runtimeRequirements.reduce(.empty) { partial, entry in
            partial.merging(runtimeServices(for: entry.service, requirements: entry.requirements, context: context))
        }
    }
}

private extension DiscoveryPipeline {
    func runtimeServices(
        for service: any DiscoveryService,
        requirements: ResolvedDiscoveryRuntimeRequirements,
        context: ServiceContext
    ) -> RuntimeServices {
        var inboundHandlers: [any InboundProtocolHandler] = []
        var peerObservers: [any PeerLifecycleObserver] = []
        var listenAddressContributors: [any ListenAddressContributor] = []
        var preStartActions: [@Sendable () async -> Void] = []
        var postStartActions: [@Sendable () async -> Void] = []

        if !requirements.inboundProtocolIDs.isEmpty {
            let handler = requireConformance(
                service,
                as: (any InboundProtocolHandler).self,
                role: "handles inbound streams"
            )
            inboundHandlers.append(
                DiscoveryOwnedInboundHandler(
                    ownerID: ownershipID,
                    protocolIDs: requirements.inboundProtocolIDs,
                    handler: handler
                )
            )
        }

        if requirements.observesPeers {
            let observer = requireConformance(
                service,
                as: (any PeerLifecycleObserver).self,
                role: "observes peer lifecycle"
            )
            peerObservers.append(
                DiscoveryOwnedPeerObserver(
                    ownerID: ownershipID,
                    observer: observer
                )
            )
        }

        if requirements.contributesListenAddresses {
            let contributor = requireConformance(
                service,
                as: (any ListenAddressContributor).self,
                role: "contributes listen addresses"
            )
            listenAddressContributors.append(
                DiscoveryOwnedListenAddressContributor(
                    ownerID: ownershipID,
                    contributor: contributor
                )
            )
        }

        let streamOpeningActivatable =
            requirements.receivesStreamOpening && requirements.activatesOnStart
            ? (service as? any StreamOpeningActivatable)
            : nil

        if requirements.receivesStreamOpening && streamOpeningActivatable == nil {
            let openerConsumer = requireConformance(
                service,
                as: (any StreamOpeningConsumer).self,
                role: "receives stream opening"
            )
            preStartActions.append { [ownerID = ownershipID, streamOpener = context.streamOpener] in
                await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                    await openerConsumer.attachStreamOpening(streamOpener)
                }
            }
        }

        if requirements.consumesIdentity {
            let identityConsumer = requireConformance(
                service,
                as: (any LocalIdentityConsumer).self,
                role: "consumes local identity"
            )
            preStartActions.append { [ownerID = ownershipID, localIdentity = context.localIdentity] in
                await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                    await identityConsumer.attachIdentityContext(localIdentity)
                }
            }
        }

        if requirements.consumesListenAddresses {
            let listenAddressConsumer = requireConformance(
                service,
                as: (any ListenAddressConsumer).self,
                role: "consumes listen addresses"
            )
            postStartActions.append { [ownerID = ownershipID, listenAddresses = context.listenAddresses] in
                await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                    await listenAddressConsumer.attachListenAddressContext(listenAddresses)
                }
            }
        }

        if requirements.consumesSupportedProtocols {
            let supportedProtocolsConsumer = requireConformance(
                service,
                as: (any SupportedProtocolsConsumer).self,
                role: "consumes supported protocols"
            )
            preStartActions.append { [ownerID = ownershipID, supportedProtocols = context.supportedProtocols] in
                await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                    await supportedProtocolsConsumer.attachSupportedProtocolsContext(supportedProtocols)
                }
            }
        }

        if let streamOpeningActivatable {
            postStartActions.append { [ownerID = ownershipID, streamOpener = context.streamOpener] in
                await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                    await streamOpeningActivatable.activate(using: streamOpener)
                }
            }
        } else if requirements.activatesOnStart {
            let activatableService = requireConformance(
                service,
                as: (any ActivatableService).self,
                role: "activates on runtime start"
            )
            postStartActions.append { [ownerID = ownershipID] in
                await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                    await activatableService.activate()
                }
            }
        }

        return RuntimeServices(
            lifecycleServices: [],
            inboundHandlers: inboundHandlers,
            peerObservers: peerObservers,
            discoverySources: [],
            listenAddressContributors: listenAddressContributors,
            preStartActions: preStartActions,
            postStartActions: postStartActions
        )
    }
}

private func requireConformance<Capability>(
    _ service: any DiscoveryService,
    as capability: Capability.Type,
    role: String
) -> Capability {
    guard let capability = service as? Capability else {
        preconditionFailure(
            "Discovery component declared runtime role '\(role)' but \(type(of: service)) does not conform to \(Capability.self)"
        )
    }
    return capability
}

private struct DiscoveryOwnedInboundHandler: InboundProtocolHandler {
    let protocolIDs: [String]

    private let ownerID: UUID
    private let handler: any InboundProtocolHandler

    init(
        ownerID: UUID,
        protocolIDs: [String],
        handler: any InboundProtocolHandler
    ) {
        self.ownerID = ownerID
        self.protocolIDs = protocolIDs
        self.handler = handler
    }

    func handleInboundStream(_ context: StreamContext) async {
        await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
            await handler.handleInboundStream(context)
        }
    }

    func shutdown() async {}
}

private struct DiscoveryOwnedPeerObserver: PeerLifecycleObserver {
    private let ownerID: UUID
    private let observer: any PeerLifecycleObserver

    init(
        ownerID: UUID,
        observer: any PeerLifecycleObserver
    ) {
        self.ownerID = ownerID
        self.observer = observer
    }

    func peerConnected(_ peer: PeerID) async {
        await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
            await observer.peerConnected(peer)
        }
    }

    func peerDisconnected(_ peer: PeerID) async {
        await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
            await observer.peerDisconnected(peer)
        }
    }
}

private struct DiscoveryOwnedListenAddressContributor: ListenAddressContributor {
    private let ownerID: UUID
    private let contributor: any ListenAddressContributor

    init(
        ownerID: UUID,
        contributor: any ListenAddressContributor
    ) {
        self.ownerID = ownerID
        self.contributor = contributor
    }

    func setListenAddressCallback(
        _ callback: @escaping @Sendable ([Multiaddr]) async -> Void
    ) {
        DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
            contributor.setListenAddressCallback(callback)
        }
    }

    func shutdown() async {}
}
