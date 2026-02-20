import Foundation
import Testing
@testable import P2P
@testable import P2PCore
@testable import P2PIdentify
@testable import P2PMux
@testable import P2PMuxYamux
@testable import P2PProtocols
@testable import P2PSecurityPlaintext
@testable import P2PTransportMemory

@Suite("Identify Integration Tests", .serialized)
struct IdentifyIntegrationTests {

    @Test("IdentifyService handlers registered on Node start", .timeLimit(.minutes(1)))
    func identifyHandlersRegistered() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "identify-server")

        let keyPair = KeyPair.generateEd25519()
        let identifyService = IdentifyService(configuration: .init(
            agentVersion: "test/1.0.0",
            cleanupInterval: nil
        ))

        let node = Node(configuration: NodeConfiguration(
            keyPair: keyPair,
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: PoolConfiguration(
                limits: .development,
                reconnectionPolicy: .disabled,
                idleTimeout: .seconds(300)
            ),
            healthCheck: nil,
            identifyService: identifyService
        ))

        try await node.start()

        // Verify identify protocol handlers are registered
        let protocols = await node.supportedProtocols
        #expect(protocols.contains(LibP2PProtocol.identify))
        #expect(protocols.contains(LibP2PProtocol.identifyPush))

        await node.shutdown()
        hub.reset()
    }

    @Test("peerConnected notifies IdentifyService", .timeLimit(.minutes(1)))
    func peerConnectedNotifiesIdentify() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "identify-peer-connected")

        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()

        let serverIdentify = IdentifyService(configuration: .init(
            agentVersion: "server/1.0.0",
            cleanupInterval: nil
        ))

        let pool = PoolConfiguration(
            limits: .development,
            reconnectionPolicy: .disabled,
            idleTimeout: .seconds(300)
        )

        let server = Node(configuration: NodeConfiguration(
            keyPair: serverKeyPair,
            listenAddresses: [serverAddress],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: nil,
            identifyService: serverIdentify
        ))
        let client = Node(configuration: NodeConfiguration(
            keyPair: clientKeyPair,
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: nil
        ))

        try await server.start()
        try await client.start()

        _ = try await client.connect(to: serverAddress)

        // Wait for the server to receive the connection
        try await waitUntil(timeout: .seconds(2)) {
            serverIdentify.connectedPeers.contains(clientKeyPair.peerID)
        }

        #expect(serverIdentify.connectedPeers.contains(clientKeyPair.peerID))

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("peerDisconnected notifies IdentifyService", .timeLimit(.minutes(1)))
    func peerDisconnectedNotifiesIdentify() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "identify-peer-disconnected")

        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()

        let serverIdentify = IdentifyService(configuration: .init(
            agentVersion: "server/1.0.0",
            cleanupInterval: nil
        ))

        let pool = PoolConfiguration(
            limits: .development,
            reconnectionPolicy: .disabled,
            idleTimeout: .seconds(300)
        )

        let server = Node(configuration: NodeConfiguration(
            keyPair: serverKeyPair,
            listenAddresses: [serverAddress],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: nil,
            identifyService: serverIdentify
        ))
        let client = Node(configuration: NodeConfiguration(
            keyPair: clientKeyPair,
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: nil
        ))

        try await server.start()
        try await client.start()

        _ = try await client.connect(to: serverAddress)

        // Wait for connection
        try await waitUntil(timeout: .seconds(2)) {
            serverIdentify.connectedPeers.contains(clientKeyPair.peerID)
        }

        // Disconnect
        await client.disconnect(from: serverKeyPair.peerID)
        await server.disconnect(from: clientKeyPair.peerID)

        #expect(!serverIdentify.connectedPeers.contains(clientKeyPair.peerID))

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }

    @Test("Node shutdown calls IdentifyService shutdown", .timeLimit(.minutes(1)))
    func nodeShutdownCallsIdentifyShutdown() async throws {
        let hub = MemoryHub()
        let address = Multiaddr.memory(id: "identify-shutdown")

        let keyPair = KeyPair.generateEd25519()
        let identifyService = IdentifyService(configuration: .init(
            agentVersion: "test/1.0.0",
            cleanupInterval: nil
        ))

        let node = Node(configuration: NodeConfiguration(
            keyPair: keyPair,
            listenAddresses: [address],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: PoolConfiguration(
                limits: .development,
                reconnectionPolicy: .disabled,
                idleTimeout: .seconds(300)
            ),
            healthCheck: nil,
            identifyService: identifyService
        ))

        try await node.start()

        // Cache some data to verify cleanup
        identifyService.cacheInfo(
            IdentifyInfo(
                publicKey: keyPair.publicKey,
                listenAddresses: [],
                protocols: [],
                observedAddress: nil,
                protocolVersion: "test",
                agentVersion: "test",
                signedPeerRecord: nil
            ),
            for: PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        )

        await node.shutdown()

        // After shutdown, event stream should be finished (connectedPeers cleared)
        #expect(identifyService.connectedPeers.isEmpty)

        hub.reset()
    }

    @Test("Identify query works between two nodes", .timeLimit(.minutes(1)))
    func identifyQueryBetweenNodes() async throws {
        let hub = MemoryHub()
        let serverAddress = Multiaddr.memory(id: "identify-query")

        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()

        let serverIdentify = IdentifyService(configuration: .init(
            agentVersion: "server/1.0.0",
            cleanupInterval: nil
        ))
        let clientIdentify = IdentifyService(configuration: .init(
            agentVersion: "client/1.0.0",
            cleanupInterval: nil
        ))

        let pool = PoolConfiguration(
            limits: .development,
            reconnectionPolicy: .disabled,
            idleTimeout: .seconds(300)
        )

        let server = Node(configuration: NodeConfiguration(
            keyPair: serverKeyPair,
            listenAddresses: [serverAddress],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: nil,
            identifyService: serverIdentify
        ))
        let client = Node(configuration: NodeConfiguration(
            keyPair: clientKeyPair,
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: pool,
            healthCheck: nil,
            identifyService: clientIdentify
        ))

        try await server.start()
        try await client.start()

        _ = try await client.connect(to: serverAddress)

        // Client queries the server's identity
        let info = try await clientIdentify.identify(serverKeyPair.peerID, using: client)

        #expect(info.agentVersion == "server/1.0.0")
        #expect(info.publicKey == serverKeyPair.publicKey)

        await client.shutdown()
        await server.shutdown()
        hub.reset()
    }
}

// MARK: - Helpers

private enum WaitTimeoutError: Error {
    case timedOut
}

private func waitUntil(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(20),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if await condition() {
            return
        }
        try await Task.sleep(for: pollInterval)
    }
    throw WaitTimeoutError.timedOut
}
