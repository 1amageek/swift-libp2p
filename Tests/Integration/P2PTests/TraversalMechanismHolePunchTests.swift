import Testing
import P2PCore
import P2PDCUtR
import P2PProtocols
@testable import P2P

private struct StubOpener: StreamOpener {
    func newStream(to _: PeerID, protocol _: String) async throws -> MuxedStream {
        throw NodeError.nodeNotRunning
    }
}

@Suite("TraversalMechanism HolePunch")
struct TraversalMechanismHolePunchTests {
    @Test("requires limited connection when configured", .timeLimit(.minutes(1)))
    func requiresLimitedConnection() async {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let mechanism = HolePunchMechanism(dcutr: DCUtRService(), requireLimitedConnection: true)

        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [],
            transports: [],
            connectedPeers: [],
            opener: StubOpener(),
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in peer }
        )

        let candidates = await mechanism.collectCandidates(context: context)
        #expect(candidates.isEmpty)
    }

    @Test("attempt without opener throws missing context", .timeLimit(.minutes(1)))
    func attemptWithoutOpener() async {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let mechanism = HolePunchMechanism(dcutr: DCUtRService(), requireLimitedConnection: false)

        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [],
            transports: [],
            connectedPeers: [],
            opener: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in true },
            dialAddress: { _ in peer }
        )

        do {
            _ = try await mechanism.attempt(
                candidate: TraversalCandidate(
                    mechanismID: mechanism.id,
                    peer: peer,
                    address: nil,
                    pathKind: .holePunch
                ),
                context: context
            )
            Issue.record("Expected missing context error")
        } catch let TraversalError.missingContext(message) {
            #expect(message.contains("StreamOpener"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("collectCandidates returns empty without opener", .timeLimit(.minutes(1)))
    func collectCandidatesWithoutOpener() async {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let mechanism = HolePunchMechanism(dcutr: DCUtRService(), requireLimitedConnection: false)

        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [],
            transports: [],
            connectedPeers: [],
            opener: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in true },
            dialAddress: { _ in peer }
        )

        let candidates = await mechanism.collectCandidates(context: context)
        #expect(candidates.isEmpty)
    }
}
