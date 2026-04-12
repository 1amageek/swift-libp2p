import Foundation
import P2PCore
import Synchronization

package struct DiscoveryContext: Sendable {
    public let localPeerID: PeerID

    public init(localPeerID: PeerID) {
        self.localPeerID = localPeerID
    }
}

public struct DiscoveryRuntimeRequirements: Sendable {
    public var inboundProtocolIDs: [String]
    public var observesPeers: Bool
    public var contributesListenAddresses: Bool
    public var receivesStreamOpening: Bool
    public var consumesIdentity: Bool
    public var consumesListenAddresses: Bool
    public var consumesSupportedProtocols: Bool
    public var activatesOnStart: Bool

    public static let empty = DiscoveryRuntimeRequirements()

    public init(
        inboundProtocolIDs: [String] = [],
        observesPeers: Bool = false,
        contributesListenAddresses: Bool = false,
        receivesStreamOpening: Bool = false,
        consumesIdentity: Bool = false,
        consumesListenAddresses: Bool = false,
        consumesSupportedProtocols: Bool = false,
        activatesOnStart: Bool = false
    ) {
        self.inboundProtocolIDs = inboundProtocolIDs
        self.observesPeers = observesPeers
        self.contributesListenAddresses = contributesListenAddresses
        self.receivesStreamOpening = receivesStreamOpening
        self.consumesIdentity = consumesIdentity
        self.consumesListenAddresses = consumesListenAddresses
        self.consumesSupportedProtocols = consumesSupportedProtocols
        self.activatesOnStart = activatesOnStart
    }
}

package struct ResolvedDiscoveryRuntimeRequirements: Sendable {
    package let inboundProtocolIDs: [String]
    package let observesPeers: Bool
    package let contributesListenAddresses: Bool
    package let receivesStreamOpening: Bool
    package let consumesIdentity: Bool
    package let consumesListenAddresses: Bool
    package let consumesSupportedProtocols: Bool
    package let activatesOnStart: Bool

    package static let empty = ResolvedDiscoveryRuntimeRequirements()

    package init(
        inboundProtocolIDs: [String] = [],
        observesPeers: Bool = false,
        contributesListenAddresses: Bool = false,
        receivesStreamOpening: Bool = false,
        consumesIdentity: Bool = false,
        consumesListenAddresses: Bool = false,
        consumesSupportedProtocols: Bool = false,
        activatesOnStart: Bool = false
    ) {
        self.inboundProtocolIDs = inboundProtocolIDs
        self.observesPeers = observesPeers
        self.contributesListenAddresses = contributesListenAddresses
        self.receivesStreamOpening = receivesStreamOpening
        self.consumesIdentity = consumesIdentity
        self.consumesListenAddresses = consumesListenAddresses
        self.consumesSupportedProtocols = consumesSupportedProtocols
        self.activatesOnStart = activatesOnStart
    }
}

package struct ResolvedDiscoveryComponent: Sendable {
    package let source: any DiscoveryService
    package let weight: Double
    package let startup: (@Sendable () async -> Void)?
    package let runtimeRequirements: ResolvedDiscoveryRuntimeRequirements
}

public struct DiscoveryComponent: Sendable {
    package let resolver: @Sendable (DiscoveryContext) -> ResolvedDiscoveryComponent

    package init(
        resolver: @escaping @Sendable (DiscoveryContext) -> ResolvedDiscoveryComponent
    ) {
        self.resolver = resolver
    }
}

public struct DiscoveryRegistration<Source: DiscoveryService>: Sendable {
    private let makeSource: @Sendable (DiscoveryContext) -> Source
    private let weight: Double
    private let startup: (@Sendable (Source) async -> Void)?
    private let inboundProtocolIDs: (@Sendable (Source) -> [String])?
    private let runtimeRequirements: DiscoveryRuntimeRequirements

    private init(
        weight: Double,
        makeSource: @escaping @Sendable (DiscoveryContext) -> Source,
        startup: (@Sendable (Source) async -> Void)?,
        inboundProtocolIDs: (@Sendable (Source) -> [String])?,
        runtimeRequirements: DiscoveryRuntimeRequirements
    ) {
        self.makeSource = makeSource
        self.weight = weight
        self.startup = startup
        self.inboundProtocolIDs = inboundProtocolIDs
        self.runtimeRequirements = runtimeRequirements
    }

    public init(
        _ source: Source,
        weight: Double = 1.0,
        startup: (@Sendable (Source) async -> Void)? = nil
    ) {
        self.init(
            weight: weight,
            makeSource: { _ in source },
            startup: startup,
            inboundProtocolIDs: nil,
            runtimeRequirements: .empty
        )
    }

    public init(
        weight: Double = 1.0,
        makeSource: @escaping @Sendable (PeerID) -> Source,
        startup: (@Sendable (Source) async -> Void)? = nil
    ) {
        self.init(
            weight: weight,
            makeSource: { context in makeSource(context.localPeerID) },
            startup: startup,
            inboundProtocolIDs: nil,
            runtimeRequirements: .empty
        )
    }

    package func component() -> DiscoveryComponent {
        DiscoveryComponent { context in
            let source = makeSource(context)
            let startupAction: (@Sendable () async -> Void)?
            if let startup {
                startupAction = { await startup(source) }
            } else {
                startupAction = nil
            }
            let resolvedRequirements = ResolvedDiscoveryRuntimeRequirements(
                inboundProtocolIDs: inboundProtocolIDs.map { $0(source) } ?? [],
                observesPeers: runtimeRequirements.observesPeers,
                contributesListenAddresses: runtimeRequirements.contributesListenAddresses,
                receivesStreamOpening: runtimeRequirements.receivesStreamOpening,
                consumesIdentity: runtimeRequirements.consumesIdentity,
                consumesListenAddresses: runtimeRequirements.consumesListenAddresses,
                consumesSupportedProtocols: runtimeRequirements.consumesSupportedProtocols,
                activatesOnStart: runtimeRequirements.activatesOnStart
            )
            return ResolvedDiscoveryComponent(
                source: source,
                weight: weight,
                startup: startupAction,
                runtimeRequirements: resolvedRequirements
            )
        }
    }

    public mutating func declareInboundProtocolIDs(
        _ resolver: @escaping @Sendable (Source) -> [String]
    ) {
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: resolver,
            runtimeRequirements: runtimeRequirements
        )
    }

    public mutating func observesPeerLifecycle() {
        var requirements = runtimeRequirements
        requirements.observesPeers = true
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: requirements
        )
    }

    public mutating func publishesListenAddresses() {
        var requirements = runtimeRequirements
        requirements.contributesListenAddresses = true
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: requirements
        )
    }

    public mutating func receivesStreamOpening() {
        var requirements = runtimeRequirements
        requirements.receivesStreamOpening = true
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: requirements
        )
    }

    public mutating func requiresIdentity() {
        var requirements = runtimeRequirements
        requirements.consumesIdentity = true
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: requirements
        )
    }

    public mutating func requiresListenAddresses() {
        var requirements = runtimeRequirements
        requirements.consumesListenAddresses = true
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: requirements
        )
    }

    public mutating func requiresSupportedProtocols() {
        var requirements = runtimeRequirements
        requirements.consumesSupportedProtocols = true
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: requirements
        )
    }

    public mutating func activatesOnRuntimeStart() {
        var requirements = runtimeRequirements
        requirements.activatesOnStart = true
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: requirements
        )
    }
}

package extension DiscoveryRegistration {
    mutating func onStart(
        _ startupHook: @escaping @Sendable (Source) async -> Void
    ) {
        let combinedStartup: (@Sendable (Source) async -> Void)?
        if let startup {
            combinedStartup = { source in
                await startup(source)
                await startupHook(source)
            }
        } else {
            combinedStartup = startupHook
        }
        self = DiscoveryRegistration(
            weight: weight,
            makeSource: makeSource,
            startup: combinedStartup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: runtimeRequirements
        )
    }

    mutating func setWeight(_ newWeight: Double) {
        self = DiscoveryRegistration(
            weight: newWeight,
            makeSource: makeSource,
            startup: startup,
            inboundProtocolIDs: inboundProtocolIDs,
            runtimeRequirements: runtimeRequirements
        )
    }
}

@resultBuilder
public enum DiscoveryPipelineBuilder {
    public static func buildBlock() -> [DiscoveryComponent] {
        []
    }

    public static func buildBlock(_ components: [DiscoveryComponent]...) -> [DiscoveryComponent] {
        components.flatMap { $0 }
    }

    public static func buildArray(_ components: [[DiscoveryComponent]]) -> [DiscoveryComponent] {
        components.flatMap { $0 }
    }

    public static func buildEither(first component: [DiscoveryComponent]) -> [DiscoveryComponent] {
        component
    }

    public static func buildEither(second component: [DiscoveryComponent]) -> [DiscoveryComponent] {
        component
    }

    public static func buildExpression(_ component: DiscoveryComponent) -> [DiscoveryComponent] {
        [component]
    }

    public static func buildExpression(_ components: [DiscoveryComponent]) -> [DiscoveryComponent] {
        components
    }

    public static func buildOptional(_ component: [DiscoveryComponent]?) -> [DiscoveryComponent] {
        component ?? []
    }
}

package func discovery<Source: DiscoveryService>(
    _ source: Source,
    weight: Double = 1.0,
    startup: (@Sendable (Source) async -> Void)? = nil
) -> DiscoveryComponent {
    DiscoveryRegistration(
        source,
        weight: weight,
        startup: startup
    ).component()
}

package func discovery<Source: DiscoveryService>(
    _ source: Source,
    weight: Double = 1.0,
    startup: (@Sendable (Source) async -> Void)? = nil,
    configure: (inout DiscoveryRegistration<Source>) -> Void
) -> DiscoveryComponent {
    var registration = DiscoveryRegistration(
        source,
        weight: weight,
        startup: startup
    )
    configure(&registration)
    return registration.component()
}

package func discovery(
    _ source: any DiscoveryService,
    weight: Double = 1.0,
    startup: (@Sendable (any DiscoveryService) async -> Void)? = nil
) -> DiscoveryComponent {
    let startupAction: (@Sendable () async -> Void)?
    if let startup {
        startupAction = { await startup(source) }
    } else {
        startupAction = nil
    }
    return DiscoveryComponent { _ in
        ResolvedDiscoveryComponent(
            source: source,
            weight: weight,
            startup: startupAction,
            runtimeRequirements: .empty
        )
    }
}

package func discovery<Source: DiscoveryService>(
    weight: Double = 1.0,
    _ makeSource: @escaping @Sendable (PeerID) -> Source,
    startup: (@Sendable (Source) async -> Void)? = nil
) -> DiscoveryComponent {
    DiscoveryRegistration(
        weight: weight,
        makeSource: makeSource,
        startup: startup
    ).component()
}

package func discovery<Source: DiscoveryService>(
    weight: Double = 1.0,
    _ makeSource: @escaping @Sendable (PeerID) -> Source,
    startup: (@Sendable (Source) async -> Void)? = nil,
    configure: (inout DiscoveryRegistration<Source>) -> Void
) -> DiscoveryComponent {
    var registration = DiscoveryRegistration(
        weight: weight,
        makeSource: makeSource,
        startup: startup
    )
    configure(&registration)
    return registration.component()
}

package func discovery(
    weight: Double = 1.0,
    _ makeSource: @escaping @Sendable (PeerID) -> any DiscoveryService,
    startup: (@Sendable (any DiscoveryService) async -> Void)? = nil
) -> DiscoveryComponent {
    return DiscoveryComponent { context in
        let source = makeSource(context.localPeerID)
        let startupAction: (@Sendable () async -> Void)?
        if let startup {
            startupAction = { await startup(source) }
        } else {
            startupAction = nil
        }
        return ResolvedDiscoveryComponent(
            source: source,
            weight: weight,
            startup: startupAction,
            runtimeRequirements: .empty
        )
    }
}

public final class DiscoveryPipeline: DiscoveryService, Sendable {
    public let localPeerID: PeerID

    private let ownerID: UUID
    private let services: [(service: any DiscoveryService, weight: Double)]
    private let startups: [@Sendable () async -> Void]
    package let runtimeRequirements: [(service: any DiscoveryService, requirements: ResolvedDiscoveryRuntimeRequirements)]
    private let state: Mutex<State>
    private let broadcaster = EventBroadcaster<PeerObservation>()

    private struct State: Sendable {
        var sequenceNumber: UInt64 = 0
        var forwardingTasks: [Task<Void, Never>] = []
        var isRunning = false
        var isShutdown = false
    }

    public init(
        localPeerID: PeerID,
        @DiscoveryPipelineBuilder _ content: () -> [DiscoveryComponent]
    ) {
        let context = DiscoveryContext(localPeerID: localPeerID)
        let components = content()
        let resolved = Self.resolveComponents(context: context, components: components)
        self.localPeerID = context.localPeerID
        self.ownerID = resolved.ownerID
        self.services = resolved.services
        self.startups = resolved.startups
        self.runtimeRequirements = resolved.runtimeRequirements
        self.state = Mutex(State())
    }

    package init(
        context: DiscoveryContext,
        @DiscoveryPipelineBuilder _ content: () -> [DiscoveryComponent]
    ) {
        self.localPeerID = context.localPeerID
        let resolved = Self.resolveComponents(context: context, components: content())
        self.ownerID = resolved.ownerID
        self.services = resolved.services
        self.startups = resolved.startups
        self.runtimeRequirements = resolved.runtimeRequirements
        self.state = Mutex(State())
    }

    package var ownedServices: [any DiscoveryService] {
        services.map(\.service)
    }

    package var ownershipID: UUID {
        ownerID
    }

    private static func resolveComponents(
        context: DiscoveryContext,
        components: [DiscoveryComponent]
    ) -> (
        ownerID: UUID,
        services: [(service: any DiscoveryService, weight: Double)],
        startups: [@Sendable () async -> Void],
        runtimeRequirements: [(service: any DiscoveryService, requirements: ResolvedDiscoveryRuntimeRequirements)]
    ) {
        let resolved = components.map { $0.resolver(context) }
        let services = resolved.map { ($0.source, $0.weight) }
        Self.preconditionUniqueReferenceServices(services)
        let ownerID = UUID()
        for (service, _) in services {
            DiscoveryServiceOwnershipRegistry.claim(service, ownerID: ownerID)
        }
        return (
            ownerID: ownerID,
            services: services,
            startups: resolved.compactMap(\.startup),
            runtimeRequirements: resolved.map { ($0.source, $0.runtimeRequirements) }
        )
    }

    deinit {
        let shouldFinish = state.withLock { state -> Bool in
            guard !state.isShutdown else { return false }
            state.isShutdown = true
            for task in state.forwardingTasks {
                task.cancel()
            }
            state.forwardingTasks.removeAll()
            return true
        }
        if shouldFinish {
            for (service, _) in services {
                DiscoveryServiceOwnershipRegistry.release(service, ownerID: ownerID)
            }
            broadcaster.shutdown()
        }
    }

    public func start() async {
        let alreadyRunning = state.withLock { state in
            if state.isRunning { return true }
            state.isRunning = true
            return false
        }
        guard !alreadyRunning else { return }

        for startup in startups {
            await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                await startup()
            }
        }

        for (service, _) in services {
            let task = Task { [weak self] in
                guard let self else { return }
                await self.forwardEvents(from: service)
            }
            state.withLock { $0.forwardingTasks.append(task) }
        }
    }

    public func shutdown() async {
        let (tasks, servicesToStop) = state.withLock { state -> ([Task<Void, Never>], [(any DiscoveryService, Double)]) in
            guard !state.isShutdown else { return ([], []) }
            state.isShutdown = true
            state.isRunning = false
            let tasks = state.forwardingTasks
            state.forwardingTasks.removeAll()
            state.sequenceNumber = 0
            return (tasks, services)
        }

        for task in tasks {
            task.cancel()
        }

        for (service, _) in servicesToStop {
            await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                await service.shutdown()
            }
        }

        for (service, _) in servicesToStop {
            DiscoveryServiceOwnershipRegistry.release(service, ownerID: ownerID)
        }
        broadcaster.shutdown()
    }

    public func announce(addresses: [Multiaddr]) async throws {
        var errors: [Error] = []
        for (service, _) in services {
            do {
                try await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                    try await service.announce(addresses: addresses)
                }
            } catch {
                errors.append(error)
            }
        }
        if errors.count == services.count, let first = errors.first {
            throw first
        }
    }

    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        var allCandidates: [ScoredCandidate] = []
        var errors: [Error] = []

        await withTaskGroup(of: ([(ScoredCandidate, Double)], Error?).self) { group in
            for (service, weight) in services {
                group.addTask { [ownerID = self.ownerID] in
                    do {
                        let candidates = try await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                            try await service.find(peer: peer)
                        }
                        return (candidates.map { ($0, weight) }, nil)
                    } catch {
                        return ([], error)
                    }
                }
            }

            for await (weightedCandidates, error) in group {
                if let error {
                    errors.append(error)
                }
                for (candidate, weight) in weightedCandidates {
                    allCandidates.append(
                        ScoredCandidate(
                            peerID: candidate.peerID,
                            addresses: candidate.addresses,
                            score: candidate.score * weight
                        )
                    )
                }
            }
        }

        if allCandidates.isEmpty, let first = errors.first {
            throw first
        }

        return mergeCandidates(allCandidates)
    }

    public func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        let stream = broadcaster.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await observation in stream where observation.subject == peer {
                    continuation.yield(observation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func collectKnownPeers() async -> [PeerID] {
        var peers: Set<PeerID> = []
        for (service, _) in services {
            let known = await DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
                await service.collectKnownPeers()
            }
            peers.formUnion(known)
        }
        return Array(peers)
    }

    public var observations: AsyncStream<PeerObservation> {
        broadcaster.subscribe()
    }

    private func forwardEvents(from service: any DiscoveryService) async {
        let stream = DiscoveryServiceOwnershipRegistry.withOwnerAccess(ownerID: ownerID) {
            service.observations
        }
        for await observation in stream {
            guard !Task.isCancelled else { return }
            let sequenced = state.withLock { state -> PeerObservation in
                state.sequenceNumber += 1
                return PeerObservation(
                    subject: observation.subject,
                    observer: observation.observer,
                    kind: observation.kind,
                    hints: observation.hints,
                    timestamp: observation.timestamp,
                    sequenceNumber: state.sequenceNumber
                )
            }
            broadcaster.emit(sequenced)
        }
    }

    private func mergeCandidates(_ candidates: [ScoredCandidate]) -> [ScoredCandidate] {
        var byPeer: [PeerID: (addresses: Set<Multiaddr>, totalScore: Double, count: Int)] = [:]

        for candidate in candidates {
            if var existing = byPeer[candidate.peerID] {
                existing.addresses.formUnion(candidate.addresses)
                existing.totalScore += candidate.score
                existing.count += 1
                byPeer[candidate.peerID] = existing
            } else {
                byPeer[candidate.peerID] = (
                    addresses: Set(candidate.addresses),
                    totalScore: candidate.score,
                    count: 1
                )
            }
        }

        return byPeer.map { (peerID, data) in
            ScoredCandidate(
                peerID: peerID,
                addresses: Array(data.addresses),
                score: data.totalScore / Double(data.count)
            )
        }
        .sorted { $0.score > $1.score }
    }

    private static func preconditionUniqueReferenceServices(
        _ services: [(service: any DiscoveryService, weight: Double)]
    ) {
        var seenReferences: Set<ObjectIdentifier> = []
        for (service, _) in services {
            let mirror = Mirror(reflecting: service)
            guard mirror.displayStyle == .class else { continue }
            let identifier = ObjectIdentifier(service as AnyObject)
            precondition(
                seenReferences.insert(identifier).inserted,
                "DiscoveryPipeline child services must be unique reference instances"
            )
        }
    }
}
