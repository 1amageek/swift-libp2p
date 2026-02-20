import Testing
import P2PCore
import P2PProtocols
@testable import P2P

private actor AttemptLog {
    var attempts: [String] = []

    func append(_ value: String) {
        attempts.append(value)
    }
}

private actor ParallelAttemptState {
    var started: [String] = []
    var cancelled: [String] = []

    func markStarted(_ id: String) {
        started.append(id)
    }

    func markCancelled(_ id: String) {
        cancelled.append(id)
    }
}

private struct StubOpener: StreamOpener {
    func newStream(to _: PeerID, protocol _: String) async throws -> MuxedStream {
        throw NodeError.nodeNotRunning
    }
}

private struct StubRegistry: HandlerRegistry {
    func handle(_: String, handler _: @escaping ProtocolHandler) async {}
}

private struct StaticHintProvider: TraversalHintProvider {
    let hintsToReturn: [TraversalCandidate]

    func hints(context _: TraversalContext) async -> [TraversalCandidate] {
        hintsToReturn
    }
}

private struct StaticMechanism: TraversalMechanism {
    let id: String
    let pathKind: TraversalPathKind
    let candidates: [TraversalCandidate]
    let attemptLog: AttemptLog
    let shouldSucceed: Bool

    func collectCandidates(context _: TraversalContext) async -> [TraversalCandidate] {
        candidates
    }

    func attempt(
        candidate _: TraversalCandidate,
        context: TraversalContext
    ) async throws -> TraversalAttemptResult {
        await attemptLog.append(id)
        if shouldSucceed {
            return TraversalAttemptResult(
                connectedPeer: context.targetPeer,
                selectedAddress: nil,
                mechanismID: id
            )
        }
        throw TraversalError.noCandidate
    }
}

private struct RacingMechanism: TraversalMechanism {
    let id: String = "direct"
    let pathKind: TraversalPathKind = .ip
    let state: ParallelAttemptState
    let fastDelay: Duration
    let slowDelay: Duration

    func collectCandidates(context: TraversalContext) async -> [TraversalCandidate] {
        [
            TraversalCandidate(
                mechanismID: id,
                peer: context.targetPeer,
                address: nil,
                pathKind: .ip,
                score: 1.0,
                metadata: ["id": "fast"]
            ),
            TraversalCandidate(
                mechanismID: id,
                peer: context.targetPeer,
                address: nil,
                pathKind: .ip,
                score: 0.9,
                metadata: ["id": "slow"]
            ),
        ]
    }

    func attempt(
        candidate: TraversalCandidate,
        context: TraversalContext
    ) async throws -> TraversalAttemptResult {
        let candidateID = candidate.metadata["id"] ?? "unknown"
        await state.markStarted(candidateID)
        do {
            if candidateID == "fast" {
                try await Task.sleep(for: fastDelay)
                return TraversalAttemptResult(
                    connectedPeer: context.targetPeer,
                    selectedAddress: nil,
                    mechanismID: id
                )
            }
            try await Task.sleep(for: slowDelay)
            throw TraversalError.noCandidate
        } catch is CancellationError {
            await state.markCancelled(candidateID)
            throw CancellationError()
        }
    }
}

@Suite("TraversalCoordinator")
struct TraversalCoordinatorTests {
    @Test("local success stops fallback", .timeLimit(.minutes(1)))
    func localSuccessStopsFallback() async throws {
        let localPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let remotePeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let attemptLog = AttemptLog()

        let local = StaticMechanism(
            id: "local",
            pathKind: .local,
            candidates: [TraversalCandidate(mechanismID: "local", peer: remotePeer, address: nil, pathKind: .local, score: 1)],
            attemptLog: attemptLog,
            shouldSucceed: true
        )
        let relay = StaticMechanism(
            id: "relay",
            pathKind: .relay,
            candidates: [TraversalCandidate(mechanismID: "relay", peer: remotePeer, address: nil, pathKind: .relay, score: 1)],
            attemptLog: attemptLog,
            shouldSucceed: true
        )

        let coordinator = TraversalCoordinator(
            configuration: TraversalConfiguration(mechanisms: [local, relay]),
            localPeer: localPeer,
            transports: []
        )

        await coordinator.start(
            opener: StubOpener(),
            registry: StubRegistry(),
            getLocalAddresses: { [] },
            getPeers: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in remotePeer }
        )

        let result = try await coordinator.connect(to: remotePeer, knownAddresses: [])
        #expect(result.mechanismID == "local")

        let attempts = await attemptLog.attempts
        #expect(attempts == ["local"])
    }

    @Test("hint candidate is merged and attempted", .timeLimit(.minutes(1)))
    func hintCandidateMerged() async throws {
        let localPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let remotePeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let attemptLog = AttemptLog()

        let mechanism = StaticMechanism(
            id: "direct",
            pathKind: .ip,
            candidates: [],
            attemptLog: attemptLog,
            shouldSucceed: true
        )

        let hint = TraversalCandidate(
            mechanismID: "direct",
            peer: remotePeer,
            address: nil,
            pathKind: .ip,
            score: 1.0
        )

        let coordinator = TraversalCoordinator(
            configuration: TraversalConfiguration(
                mechanisms: [mechanism],
                hintProviders: [StaticHintProvider(hintsToReturn: [hint])]
            ),
            localPeer: localPeer,
            transports: []
        )

        await coordinator.start(
            opener: StubOpener(),
            registry: StubRegistry(),
            getLocalAddresses: { [] },
            getPeers: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in remotePeer }
        )

        let result = try await coordinator.connect(to: remotePeer, knownAddresses: [])
        #expect(result.mechanismID == "direct")

        let attempts = await attemptLog.attempts
        #expect(attempts == ["direct"])
    }

    @Test("falls back to next mechanism when first attempt fails", .timeLimit(.minutes(1)))
    func fallbackToNextMechanism() async throws {
        let localPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let remotePeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let attemptLog = AttemptLog()

        let direct = StaticMechanism(
            id: "direct",
            pathKind: .ip,
            candidates: [TraversalCandidate(mechanismID: "direct", peer: remotePeer, address: nil, pathKind: .ip, score: 1)],
            attemptLog: attemptLog,
            shouldSucceed: false
        )
        let relay = StaticMechanism(
            id: "relay",
            pathKind: .relay,
            candidates: [TraversalCandidate(mechanismID: "relay", peer: remotePeer, address: nil, pathKind: .relay, score: 1)],
            attemptLog: attemptLog,
            shouldSucceed: true
        )

        let coordinator = TraversalCoordinator(
            configuration: TraversalConfiguration(mechanisms: [direct, relay]),
            localPeer: localPeer,
            transports: []
        )

        await coordinator.start(
            opener: StubOpener(),
            registry: StubRegistry(),
            getLocalAddresses: { [] },
            getPeers: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in remotePeer }
        )

        let result = try await coordinator.connect(to: remotePeer, knownAddresses: [])
        #expect(result.mechanismID == "relay")

        let attempts = await attemptLog.attempts
        #expect(attempts == ["direct", "relay"])
    }

    @Test("first successful candidate wins and cancels remaining attempts", .timeLimit(.minutes(1)))
    func firstSuccessCancelsRemaining() async throws {
        let localPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let remotePeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let state = ParallelAttemptState()

        let coordinator = TraversalCoordinator(
            configuration: TraversalConfiguration(
                mechanisms: [
                    RacingMechanism(
                        state: state,
                        fastDelay: .milliseconds(50),
                        slowDelay: .seconds(2)
                    )
                ],
                timeouts: .init(
                    attemptTimeout: .seconds(3),
                    overallTimeout: .seconds(5)
                )
            ),
            localPeer: localPeer,
            transports: []
        )

        await coordinator.start(
            opener: StubOpener(),
            registry: StubRegistry(),
            getLocalAddresses: { [] },
            getPeers: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in remotePeer }
        )

        let clock = ContinuousClock()
        let start = clock.now
        let result = try await coordinator.connect(to: remotePeer, knownAddresses: [])
        let elapsed = start.duration(to: clock.now)

        #expect(result.mechanismID == "direct")
        #expect(elapsed < .seconds(1))

        let started = await state.started
        #expect(Set(started) == Set(["fast", "slow"]))

        let cancelled = await state.cancelled
        #expect(cancelled.contains("slow"))
    }
}
