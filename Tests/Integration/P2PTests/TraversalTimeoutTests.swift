import Testing
import P2PCore
import P2PProtocols
@testable import P2P

private struct TimeoutOpener: StreamOpener {
    func newStream(to _: PeerID, protocol _: String) async throws -> MuxedStream {
        throw NodeError.nodeNotRunning
    }
}

private struct TimeoutRegistry: HandlerRegistry {
    func handle(_: String, handler _: @escaping ProtocolHandler) async {}
}

private struct SlowMechanism: TraversalMechanism {
    let id: String = "slow"
    let pathKind: TraversalPathKind = .ip

    func collectCandidates(context: TraversalContext) async -> [TraversalCandidate] {
        [TraversalCandidate(mechanismID: id, peer: context.targetPeer, address: nil, pathKind: .ip)]
    }

    func attempt(
        candidate _: TraversalCandidate,
        context _: TraversalContext
    ) async throws -> TraversalAttemptResult {
        try await Task.sleep(for: .seconds(2))
        throw TraversalError.noCandidate
    }
}

@Suite("TraversalTimeout")
struct TraversalTimeoutTests {
    @Test("attempt timeout surfaces as failed attempt", .timeLimit(.minutes(1)))
    func attemptTimeout() async throws {
        let localPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let remotePeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let coordinator = TraversalCoordinator(
            configuration: TraversalConfiguration(
                mechanisms: [SlowMechanism()],
                timeouts: .init(attemptTimeout: .milliseconds(100), overallTimeout: .seconds(1))
            ),
            localPeer: localPeer,
            transports: []
        )

        await coordinator.start(
            opener: TimeoutOpener(),
            registry: TimeoutRegistry(),
            getLocalAddresses: { [] },
            getPeers: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in remotePeer }
        )

        do {
            _ = try await coordinator.connect(to: remotePeer, knownAddresses: [])
            Issue.record("Expected timeout failure")
        } catch let TraversalError.allAttemptsFailed(failures) {
            #expect(!failures.isEmpty)
            #expect(failures[0].reason.contains("timeout"))
        }
    }
}
