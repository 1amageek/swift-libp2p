import Testing
@testable import P2P
@testable import P2PCore
@testable import P2PTransportMemory
@testable import P2PSecurityPlaintext
@testable import P2PMuxYamux

@Suite("Node Traversal Integration", .serialized)
struct NodeTraversalIntegrationTests {
    private func makeNode(
        keyPair: KeyPair = .generateEd25519(),
        hub: MemoryHub,
        listenAddress: Multiaddr? = nil,
        traversal: TraversalConfiguration? = nil
    ) -> Node {
        let listenAddresses = listenAddress.map { [$0] } ?? []
        return Node(configuration: NodeConfiguration(
            keyPair: keyPair,
            listenAddresses: listenAddresses,
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: .init(reconnectionPolicy: .disabled),
            healthCheck: nil,
            traversal: traversal
        ))
    }

    @Test("connect(to peer) uses traversal coordinator", .timeLimit(.minutes(1)))
    func connectViaTraversal() async throws {
        let hub = MemoryHub()
        let serverAddr = Multiaddr.memory(id: "traversal-server")

        let server = makeNode(hub: hub, listenAddress: serverAddr)
        let client = makeNode(
            hub: hub,
            traversal: TraversalConfiguration(
                mechanisms: [
                    LocalDirectMechanism(),
                    DirectMechanism(),
                    RelayMechanism(),
                ]
            )
        )

        try await server.start()
        try await client.start()

        let serverPeer = await server.peerID
        await client.peerStore.addAddress(serverAddr, for: serverPeer)

        let connectedPeer = try await client.connect(to: serverPeer)
        #expect(connectedPeer == serverPeer)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }
}
