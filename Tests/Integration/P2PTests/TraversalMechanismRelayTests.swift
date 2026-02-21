import Testing
import P2PCore
import P2PTransport
@testable import P2P

private struct RelayMockTransport: Transport {
    let pathKind: TransportPathKind
    let canDialClosure: @Sendable (Multiaddr) -> Bool

    var protocols: [[String]] { [] }

    func dial(_ address: Multiaddr) async throws -> any RawConnection {
        throw TransportError.unsupportedAddress(address)
    }

    func listen(_ address: Multiaddr) async throws -> any Listener {
        throw TransportError.unsupportedAddress(address)
    }

    func canDial(_ address: Multiaddr) -> Bool { canDialClosure(address) }

    func canListen(_: Multiaddr) -> Bool { false }
}

@Suite("TraversalMechanism Relay")
struct TraversalMechanismRelayTests {
    @Test("collects relay candidates only", .timeLimit(.minutes(1)))
    func collectsRelayCandidates() async throws {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let relayAddress = try Multiaddr("/ip4/1.2.3.4/tcp/4001/p2p-circuit")
        let directAddress = try Multiaddr("/ip4/1.2.3.4/tcp/4001")

        let mechanism = RelayMechanism()
        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [relayAddress, directAddress],
            transports: [
                RelayMockTransport(pathKind: .relay, canDialClosure: { $0 == relayAddress }),
                RelayMockTransport(pathKind: .ip, canDialClosure: { $0 == directAddress }),
            ],
            connectedPeers: [],
            opener: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in peer }
        )

        let candidates = await mechanism.collectCandidates(context: context)
        #expect(candidates.count == 1)
        #expect(candidates.first?.address == relayAddress)
    }
}
