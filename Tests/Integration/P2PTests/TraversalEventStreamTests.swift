import Testing
import P2PCore
import P2PProtocols
@testable import P2P

private struct EventOpener: StreamOpener {
    func newStream(to _: PeerID, protocol _: String) async throws -> MuxedStream {
        throw NodeError.nodeNotRunning
    }
}

@Suite("TraversalEventStream")
struct TraversalEventStreamTests {
    @Test("shutdown finishes events stream", .timeLimit(.minutes(1)))
    func shutdownFinishesStream() async {
        let localPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let coordinator = TraversalCoordinator(
            configuration: TraversalConfiguration(),
            localPeer: localPeer,
            transports: []
        )

        await coordinator.start(
            opener: EventOpener(),
            getLocalAddresses: { [] },
            getPeers: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in localPeer }
        )

        let consumeTask = Task {
            for await _ in coordinator.events {
                // consume
            }
            return true
        }

        await coordinator.shutdown()
        let finished = await consumeTask.value
        #expect(finished)
    }
}
