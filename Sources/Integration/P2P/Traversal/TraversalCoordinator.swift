import Foundation
import Synchronization
import P2PCore
import P2PProtocols
import P2PTransport

/// Orchestrates candidate collection and connectivity attempts across traversal mechanisms.
public final class TraversalCoordinator: EventEmitting, Sendable {
    public let configuration: TraversalConfiguration
    public let localPeer: PeerID
    private let transports: [any Transport]

    private let eventState: Mutex<EventState>
    private let runtimeState: Mutex<RuntimeState>

    private struct EventState: Sendable {
        var stream: AsyncStream<TraversalEvent>?
        var continuation: AsyncStream<TraversalEvent>.Continuation?
        var isFinished: Bool = false
    }

    private struct RuntimeState: Sendable {
        var opener: (any StreamOpener)?
        var registry: (any HandlerRegistry)?
        var getLocalAddresses: (@Sendable () -> [Multiaddr])?
        var getPeers: (@Sendable () -> [PeerID])?
        var isLimitedConnection: (@Sendable (PeerID) -> Bool)?
        var dialAddress: (@Sendable (Multiaddr) async throws -> PeerID)?
        var isRunning: Bool = false
        var isShutDown: Bool = false
    }

    private enum AttemptOutcome: Sendable {
        case succeeded(TraversalAttemptResult)
        case failed(
            candidate: TraversalCandidate,
            reason: String,
            timedOut: Bool,
            shouldFallback: Bool
        )
    }

    private enum StageOutcome: Sendable {
        case succeeded(TraversalAttemptResult)
        case failed([TraversalAttemptFailure])
        case blocked([TraversalAttemptFailure])
    }

    public var events: AsyncStream<TraversalEvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            if state.isFinished {
                let (stream, continuation) = AsyncStream<TraversalEvent>.makeStream()
                continuation.finish()
                return stream
            }
            let (stream, continuation) = AsyncStream<TraversalEvent>.makeStream(
                bufferingPolicy: .bufferingNewest(configuration.eventBufferSize)
            )
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    public init(
        configuration: TraversalConfiguration,
        localPeer: PeerID,
        transports: [any Transport]
    ) {
        self.configuration = configuration
        self.localPeer = localPeer
        self.transports = transports
        self.eventState = Mutex(EventState())
        self.runtimeState = Mutex(RuntimeState())
    }

    public func start(
        opener: any StreamOpener,
        registry: any HandlerRegistry,
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr],
        getPeers: @escaping @Sendable () -> [PeerID],
        isLimitedConnection: @escaping @Sendable (PeerID) -> Bool,
        dialAddress: @escaping @Sendable (Multiaddr) async throws -> PeerID
    ) async {
        let shouldStart = runtimeState.withLock { state -> Bool in
            if state.isRunning || state.isShutDown {
                return false
            }
            state.opener = opener
            state.registry = registry
            state.getLocalAddresses = getLocalAddresses
            state.getPeers = getPeers
            state.isLimitedConnection = isLimitedConnection
            state.dialAddress = dialAddress
            state.isRunning = true
            return true
        }

        guard shouldStart else { return }

        let setupContext = TraversalContext(
            localPeer: localPeer,
            targetPeer: localPeer,
            knownAddresses: [],
            transports: transports,
            connectedPeers: getPeers(),
            opener: opener,
            registry: registry,
            getLocalAddresses: getLocalAddresses,
            isLimitedConnection: isLimitedConnection,
            dialAddress: dialAddress
        )

        for mechanism in configuration.mechanisms {
            await mechanism.prepare(context: setupContext)
        }
    }

    public func connect(
        to peer: PeerID,
        knownAddresses: [Multiaddr]
    ) async throws -> TraversalAttemptResult {
        let runtime = runtimeState.withLock { state in state }

        guard runtime.isRunning, !runtime.isShutDown else {
            throw TraversalError.missingContext("TraversalCoordinator is not running")
        }
        guard let getLocalAddresses = runtime.getLocalAddresses,
              let getPeers = runtime.getPeers,
              let isLimitedConnection = runtime.isLimitedConnection,
              let dialAddress = runtime.dialAddress else {
            throw TraversalError.missingContext("Traversal runtime state is incomplete")
        }

        let context = TraversalContext(
            localPeer: localPeer,
            targetPeer: peer,
            knownAddresses: knownAddresses,
            transports: transports,
            connectedPeers: getPeers(),
            opener: runtime.opener,
            registry: runtime.registry,
            getLocalAddresses: getLocalAddresses,
            isLimitedConnection: isLimitedConnection,
            dialAddress: dialAddress
        )

        var candidates: [TraversalCandidate] = []

        for provider in configuration.hintProviders {
            candidates.append(contentsOf: await provider.hints(context: context))
        }

        for mechanism in configuration.mechanisms {
            candidates.append(contentsOf: await mechanism.collectCandidates(context: context))
        }

        let deduped = deduplicate(candidates)
        let ordered = configuration.policy.order(candidates: deduped, context: context)

        ordered.forEach { emit(.candidateCollected($0)) }
        emit(.started(peer: peer, candidates: ordered.count))

        guard !ordered.isEmpty else {
            throw TraversalError.noCandidate
        }

        var mechanismByID: [String: any TraversalMechanism] = [:]
        for mechanism in configuration.mechanisms where mechanismByID[mechanism.id] == nil {
            mechanismByID[mechanism.id] = mechanism
        }
        var failures: [TraversalAttemptFailure] = []

        let startTime = ContinuousClock.now
        for stage in candidateStages(from: ordered) {
            let elapsed = startTime.duration(to: .now)
            if elapsed >= configuration.timeouts.overallTimeout {
                throw TraversalError.timeout("overall")
            }
            let remaining = configuration.timeouts.overallTimeout - elapsed
            let timeout = minDuration(configuration.timeouts.attemptTimeout, remaining)

            let outcome = await attemptStage(
                stage,
                context: context,
                mechanismByID: mechanismByID,
                attemptTimeout: timeout
            )
            switch outcome {
            case .succeeded(let result):
                emit(.completed(result))
                return result
            case .failed(let stageFailures):
                failures.append(contentsOf: stageFailures)
            case .blocked(let stageFailures):
                failures.append(contentsOf: stageFailures)
                throw TraversalError.allAttemptsFailed(failures)
            }
        }

        throw TraversalError.allAttemptsFailed(failures)
    }

    public func shutdown() {
        let shouldShutdown = runtimeState.withLock { state -> Bool in
            if state.isShutDown { return false }
            state.isShutDown = true
            state.isRunning = false
            state.opener = nil
            state.registry = nil
            state.getLocalAddresses = nil
            state.getPeers = nil
            state.isLimitedConnection = nil
            state.dialAddress = nil
            return true
        }
        guard shouldShutdown else { return }

        configuration.mechanisms.forEach { $0.shutdown() }

        eventState.withLock { state in
            state.isFinished = true
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    private func emit(_ event: TraversalEvent) {
        eventState.withLock { state in
            _ = state.continuation?.yield(event)
        }
    }

    private func deduplicate(_ candidates: [TraversalCandidate]) -> [TraversalCandidate] {
        var seen = Set<String>()
        var result: [TraversalCandidate] = []
        result.reserveCapacity(candidates.count)

        for candidate in candidates {
            let metadataKey = candidate.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
            let key = [
                candidate.mechanismID,
                candidate.peer.description,
                candidate.address?.description ?? "<none>",
                String(describing: candidate.pathKind),
                metadataKey,
            ].joined(separator: "|")
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private func candidateStages(from ordered: [TraversalCandidate]) -> [[TraversalCandidate]] {
        guard !ordered.isEmpty else { return [] }
        var stages: [[TraversalCandidate]] = []
        var current: [TraversalCandidate] = []
        var currentKind: TraversalPathKind?

        for candidate in ordered {
            if currentKind == nil || currentKind == candidate.pathKind {
                current.append(candidate)
                currentKind = candidate.pathKind
                continue
            }
            stages.append(current)
            current = [candidate]
            currentKind = candidate.pathKind
        }

        if !current.isEmpty {
            stages.append(current)
        }
        return stages
    }

    private func attemptStage(
        _ candidates: [TraversalCandidate],
        context: TraversalContext,
        mechanismByID: [String: any TraversalMechanism],
        attemptTimeout: Duration
    ) async -> StageOutcome {
        var failures: [TraversalAttemptFailure] = []
        var scheduled: [(TraversalCandidate, any TraversalMechanism)] = []
        scheduled.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard let mechanism = mechanismByID[candidate.mechanismID] else {
                failures.append(
                    TraversalAttemptFailure(
                        mechanismID: candidate.mechanismID,
                        reason: "mechanism unavailable"
                    )
                )
                continue
            }
            emit(.attemptStarted(candidate))
            scheduled.append((candidate, mechanism))
        }

        guard !scheduled.isEmpty else {
            return .failed(failures)
        }

        let policy = configuration.policy
        let stageOutcome = await withTaskGroup(of: AttemptOutcome.self) { group -> StageOutcome in
            for (candidate, mechanism) in scheduled {
                group.addTask {
                    do {
                        let result = try await self.withTimeout(attemptTimeout) {
                            try await mechanism.attempt(candidate: candidate, context: context)
                        }
                        return .succeeded(result)
                    } catch {
                        return .failed(
                            candidate: candidate,
                            reason: String(describing: error),
                            timedOut: self.isTimeoutError(error),
                            shouldFallback: policy.shouldFallback(after: error, from: candidate, context: context)
                        )
                    }
                }
            }

            while let outcome = await group.next() {
                switch outcome {
                case .succeeded(let result):
                    group.cancelAll()
                    return .succeeded(result)
                case .failed(let candidate, let reason, let timedOut, let shouldFallback):
                    if timedOut {
                        emit(.timedOut(candidate))
                    } else {
                        emit(.attemptFailed(candidate, reason: reason))
                    }
                    failures.append(
                        TraversalAttemptFailure(
                            mechanismID: candidate.mechanismID,
                            reason: reason
                        )
                    )
                    if !shouldFallback {
                        group.cancelAll()
                        return .blocked(failures)
                    }
                }
            }

            return .failed(failures)
        }

        return stageOutcome
    }

    private func minDuration(_ lhs: Duration, _ rhs: Duration) -> Duration {
        if lhs <= rhs { return lhs }
        return rhs
    }

    private func isTimeoutError(_ error: any Error) -> Bool {
        guard let traversalError = error as? TraversalError else { return false }
        if case .timeout = traversalError {
            return true
        }
        return false
    }

    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TraversalError.timeout("attempt")
            }
            guard let first = try await group.next() else {
                throw TraversalError.timeout("attempt")
            }
            group.cancelAll()
            return first
        }
    }
}
