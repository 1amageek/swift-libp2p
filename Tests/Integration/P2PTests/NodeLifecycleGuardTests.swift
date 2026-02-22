/// NodeLifecycleGuardTests - Tests for Node lifecycle state machine guards.

import Testing
import Foundation
import NIOCore
@testable import P2P
@testable import P2PCore
@testable import P2PTransport
@testable import P2PTransportMemory
@testable import P2PSecurity
@testable import P2PSecurityPlaintext
@testable import P2PMux
@testable import P2PMuxYamux

@Suite("Node Lifecycle Guard Tests", .serialized)
struct NodeLifecycleGuardTests {

    private func makeNode(hub: MemoryHub, name: String) -> Node {
        let addr = Multiaddr.memory(id: name)
        return Node(configuration: NodeConfiguration(
            listenAddresses: [addr],
            transports: [MemoryTransport(hub: hub)],
            security: [PlaintextUpgrader()],
            muxers: [YamuxMuxer()],
            pool: PoolConfiguration(
                limits: .development,
                reconnectionPolicy: .disabled,
                idleTimeout: .seconds(300)
            ),
            healthCheck: nil
        ))
    }

    // MARK: - Pre-start (idle state)

    @Test("handle() works before start", .timeLimit(.minutes(1)))
    func handleBeforeStart() async {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "idle-handle")

        await node.handle("/test/1.0.0") { _ in }
        let protocols = await node.supportedProtocols()
        #expect(protocols.contains("/test/1.0.0"))

        await node.shutdown()
        hub.reset()
    }

    @Test("handleStream() works before start", .timeLimit(.minutes(1)))
    func handleStreamBeforeStart() async {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "idle-handlestream")

        await node.handleStream("/test/1.0.0") { _ in }
        let protocols = await node.supportedProtocols()
        #expect(protocols.contains("/test/1.0.0"))

        await node.shutdown()
        hub.reset()
    }

    @Test("connect(to address) throws before start", .timeLimit(.minutes(1)))
    func connectToAddressBeforeStart() async {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "idle-connect")

        await #expect(throws: NodeError.self) {
            _ = try await node.connect(to: Multiaddr.memory(id: "nonexistent"))
        }

        await node.shutdown()
        hub.reset()
    }

    @Test("newStream throws before start", .timeLimit(.minutes(1)))
    func newStreamBeforeStart() async {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "idle-newstream")
        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        await #expect(throws: NodeError.self) {
            _ = try await node.newStream(to: peer, protocol: "/test/1.0.0")
        }

        await node.shutdown()
        hub.reset()
    }

    // MARK: - Shutdown from idle (never started)

    @Test("shutdown from idle finishes events stream", .timeLimit(.minutes(1)))
    func shutdownFromIdleFinishesEvents() async {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "idle-shutdown-events")

        let consumeTask = Task {
            for await _ in await node.events {}
            return true
        }

        await node.shutdown()
        let finished = await consumeTask.value
        #expect(finished)

        hub.reset()
    }

    @Test("shutdown from idle transitions to stopped", .timeLimit(.minutes(1)))
    func shutdownFromIdleTransitionsToStopped() async {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "idle-shutdown-stopped")

        await node.shutdown()

        // start() should throw — node is stopped, not idle
        await #expect(throws: NodeError.self) {
            try await node.start()
        }

        hub.reset()
    }

    @Test("shutdown from idle is idempotent", .timeLimit(.minutes(1)))
    func shutdownFromIdleIsIdempotent() async {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "idle-shutdown-idempotent")

        await node.shutdown()
        await node.shutdown()
        await node.shutdown()

        hub.reset()
    }

    // MARK: - Post-shutdown (stopped state)

    @Test("connect(to address) throws after shutdown", .timeLimit(.minutes(1)))
    func connectToAddressAfterShutdown() async throws {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "stopped-connect-addr")
        try await node.start()
        await node.shutdown()

        await #expect(throws: NodeError.self) {
            _ = try await node.connect(to: Multiaddr.memory(id: "nonexistent"))
        }

        hub.reset()
    }

    @Test("connect(to peer) throws after shutdown", .timeLimit(.minutes(1)))
    func connectToPeerAfterShutdown() async throws {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "stopped-connect-peer")
        try await node.start()
        await node.shutdown()

        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        await #expect(throws: NodeError.self) {
            _ = try await node.connect(to: peer)
        }

        hub.reset()
    }

    @Test("newStream throws after shutdown", .timeLimit(.minutes(1)))
    func newStreamAfterShutdown() async throws {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "stopped-newstream")
        try await node.start()
        await node.shutdown()

        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        await #expect(throws: NodeError.self) {
            _ = try await node.newStream(to: peer, protocol: "/test/1.0.0")
        }

        hub.reset()
    }

    @Test("disconnect is no-op after shutdown", .timeLimit(.minutes(1)))
    func disconnectAfterShutdown() async throws {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "stopped-disconnect")
        try await node.start()
        await node.shutdown()

        let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        await node.disconnect(from: peer)

        hub.reset()
    }

    @Test("handle() is no-op after shutdown", .timeLimit(.minutes(1)))
    func handleAfterShutdown() async throws {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "stopped-handle")
        try await node.start()
        await node.shutdown()

        await node.handle("/test/late/1.0.0") { _ in }
        let protocols = await node.supportedProtocols()
        #expect(!protocols.contains("/test/late/1.0.0"))

        hub.reset()
    }

    @Test("start() throws after shutdown (no restart)", .timeLimit(.minutes(1)))
    func startAfterShutdown() async throws {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "stopped-restart")
        try await node.start()
        await node.shutdown()

        await #expect(throws: NodeError.self) {
            try await node.start()
        }

        hub.reset()
    }

    @Test("shutdown is idempotent", .timeLimit(.minutes(1)))
    func shutdownIdempotent() async throws {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "shutdown-idempotent")
        try await node.start()
        await node.shutdown()
        await node.shutdown()

        hub.reset()
    }

    @Test("read-only properties work after shutdown", .timeLimit(.minutes(1)))
    func readOnlyAfterShutdown() async throws {
        let hub = MemoryHub()
        let node = makeNode(hub: hub, name: "shutdown-readonly")
        try await node.start()
        await node.shutdown()

        let peers = await node.connectedPeers
        #expect(peers.isEmpty)

        let count = await node.connectionCount
        #expect(count == 0)

        hub.reset()
    }
}
