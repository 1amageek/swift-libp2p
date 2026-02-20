import Testing
@testable import P2P
@testable import P2PCore

@Suite("Traversal Interop Smoke Tests", .serialized)
struct TraversalInteropSmokeTests {
    @Test("default traversal policy keeps relay after direct", .timeLimit(.minutes(1)))
    func relayAfterDirect() {
        let policy = DefaultTraversalPolicy()
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [],
            transports: [],
            connectedPeers: [],
            opener: nil,
            registry: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in peer }
        )

        let ordered = policy.order(candidates: [
            TraversalCandidate(
                mechanismID: "relay",
                peer: peer,
                address: nil,
                pathKind: .relay,
                score: 0.5
            ),
            TraversalCandidate(
                mechanismID: "direct",
                peer: peer,
                address: nil,
                pathKind: .ip,
                score: 0.5
            ),
        ], context: context)

        #expect(ordered.first?.pathKind == .ip)
        #expect(ordered.last?.pathKind == .relay)
    }
}
