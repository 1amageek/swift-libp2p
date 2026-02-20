import Testing
import P2PCore
import P2PTransport
@testable import P2P

private struct MechanismMockTransport: Transport {
    let pathKind: TransportPathKind
    let canDialClosure: @Sendable (Multiaddr) -> Bool

    var protocols: [[String]] { [] }

    func dial(_ address: Multiaddr) async throws -> RawConnection {
        throw TransportError.unsupportedAddress(address)
    }

    func listen(_ address: Multiaddr) async throws -> Listener {
        throw TransportError.unsupportedAddress(address)
    }

    func canDial(_ address: Multiaddr) -> Bool { canDialClosure(address) }

    func canListen(_: Multiaddr) -> Bool { false }
}

@Suite("TraversalMechanism Direct")
struct TraversalMechanismDirectTests {
    @Test("collects only IP dialable addresses", .timeLimit(.minutes(1)))
    func collectsIPDialable() async throws {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let direct = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let relay = try Multiaddr("/ip4/1.2.3.4/tcp/4001/p2p-circuit")

        let mechanism = DirectMechanism()
        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [direct, relay],
            transports: [
                MechanismMockTransport(pathKind: .ip, canDialClosure: { $0 == direct }),
                MechanismMockTransport(pathKind: .relay, canDialClosure: { _ in true }),
            ],
            connectedPeers: [],
            opener: nil,
            registry: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in peer }
        )

        let candidates = await mechanism.collectCandidates(context: context)
        #expect(candidates.count == 1)
        #expect(candidates.first?.address == direct)
    }

    @Test("attempt dials selected address", .timeLimit(.minutes(1)))
    func attemptDialsAddress() async throws {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let address = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let mechanism = DirectMechanism()

        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [address],
            transports: [],
            connectedPeers: [],
            opener: nil,
            registry: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { addr in
                #expect(addr == address)
                return peer
            }
        )

        let result = try await mechanism.attempt(
            candidate: TraversalCandidate(
                mechanismID: mechanism.id,
                peer: peer,
                address: address,
                pathKind: .ip
            ),
            context: context
        )

        #expect(result.connectedPeer == peer)
        #expect(result.selectedAddress == address)
    }
}
