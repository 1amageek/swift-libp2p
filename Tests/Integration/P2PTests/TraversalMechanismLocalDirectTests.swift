import Testing
import P2PCore
import P2PTransport
@testable import P2P

private struct LocalMockTransport: Transport {
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

@Suite("TraversalMechanism LocalDirect")
struct TraversalMechanismLocalDirectTests {
    @Test("collects only local transport candidates", .timeLimit(.minutes(1)))
    func collectsLocalDialable() async throws {
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let memoryAddress = try Multiaddr("/memory/42")
        let ipAddress = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

        let mechanism = LocalDirectMechanism()
        let context = TraversalContext(
            localPeer: peer,
            targetPeer: peer,
            knownAddresses: [memoryAddress, ipAddress],
            transports: [
                LocalMockTransport(pathKind: .local, canDialClosure: { $0 == memoryAddress }),
                LocalMockTransport(pathKind: .ip, canDialClosure: { $0 == ipAddress }),
            ],
            connectedPeers: [],
            opener: nil,
            getLocalAddresses: { [] },
            isLimitedConnection: { _ in false },
            dialAddress: { _ in peer }
        )

        let candidates = await mechanism.collectCandidates(context: context)
        #expect(candidates.count == 1)
        #expect(candidates.first?.address == memoryAddress)
    }
}
