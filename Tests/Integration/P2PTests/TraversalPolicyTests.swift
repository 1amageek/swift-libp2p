import Testing
import P2PCore
@testable import P2P

@Suite("TraversalPolicy")
struct TraversalPolicyTests {
    @Test("orders local then ip then hole punch then relay", .timeLimit(.minutes(1)))
    func orderByPathKind() {
        let policy = DefaultTraversalPolicy()
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let candidates = [
            TraversalCandidate(mechanismID: "relay", peer: peer, address: nil, pathKind: .relay, score: 1.0),
            TraversalCandidate(mechanismID: "ip", peer: peer, address: nil, pathKind: .ip, score: 1.0),
            TraversalCandidate(mechanismID: "hole", peer: peer, address: nil, pathKind: .holePunch, score: 1.0),
            TraversalCandidate(mechanismID: "local", peer: peer, address: nil, pathKind: .local, score: 1.0),
        ]

        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [],
            transports: [],
            connectedPeers: [],
            opener: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in peer }
        )

        let ordered = policy.order(candidates: candidates, context: context)
        #expect(ordered.map(\.mechanismID) == ["local", "ip", "hole", "relay"])
    }

    @Test("stops fallback on connection limit", .timeLimit(.minutes(1)))
    func fallbackOnConnectionLimit() {
        let policy = DefaultTraversalPolicy()
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let candidate = TraversalCandidate(
            mechanismID: "direct",
            peer: peer,
            address: nil,
            pathKind: .ip,
            score: 1.0
        )

        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [],
            transports: [],
            connectedPeers: [],
            opener: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in peer }
        )

        let shouldFallback = policy.shouldFallback(
            after: NodeError.connectionLimitReached,
            from: candidate,
            context: context
        )
        #expect(shouldFallback == false)
    }

    @Test("allows fallback on missing context", .timeLimit(.minutes(1)))
    func fallbackOnMissingContext() {
        let policy = DefaultTraversalPolicy()
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let candidate = TraversalCandidate(
            mechanismID: "hole-punch",
            peer: peer,
            address: nil,
            pathKind: .holePunch,
            score: 1.0
        )

        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [],
            transports: [],
            connectedPeers: [],
            opener: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in peer }
        )

        let shouldFallback = policy.shouldFallback(
            after: TraversalError.missingContext("StreamOpener required"),
            from: candidate,
            context: context
        )
        #expect(shouldFallback == true)
    }
}
