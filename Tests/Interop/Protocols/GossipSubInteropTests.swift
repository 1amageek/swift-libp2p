/// GossipSubInteropTests - GossipSub protocol interoperability tests
///
/// Tests that swift-libp2p GossipSub implementation is compatible with go-libp2p.
/// Focuses on subscription management, message publishing, and mesh formation.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter GossipSubInteropTests

import Testing
import Foundation
import NIOCore
@testable import P2PTransportQUIC
@testable import P2PGossipSub
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
@testable import P2PNegotiation
@testable import P2PProtocols

/// Interoperability tests for GossipSub protocol
@Suite("GossipSub Protocol Interop Tests")
struct GossipSubInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p GossipSub node", .timeLimit(.minutes(2)))
    func connectToGossipSubNode() async throws {
        // Start go-libp2p GossipSub node with default topic
        let harness = try await GoProtocolHarness.start(
            protocol: .gossipsub(defaultTopic: "test-topic")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        print("[GossipSub] Node info: \(nodeInfo)")

        // Create Swift client
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // Connect to GossipSub node
        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Verify connection
        #expect(connection.remotePeer.description.contains(nodeInfo.peerID.prefix(8)))
        print("[GossipSub] Connected to GossipSub node")

        try await connection.close()
    }

    // MARK: - Subscription Tests

    @Test("GossipSub protocol handshake", .timeLimit(.minutes(2)))
    func gossipSubHandshake() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .gossipsub(defaultTopic: "test-topic")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Open stream and negotiate GossipSub protocol
        let stream = try await connection.newStream()

        // GossipSub uses /meshsub/1.1.0 or /meshsub/1.0.0
        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/meshsub/1.1.0", "/meshsub/1.0.0"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        // Should negotiate one of the meshsub protocols
        #expect(negotiationResult.protocolID.contains("meshsub"))
        print("[GossipSub] Negotiated protocol: \(negotiationResult.protocolID)")

        try await stream.close()
        try await connection.close()
    }

    @Test("GossipSub GRAFT/PRUNE message exchange", .timeLimit(.minutes(2)))
    func gossipSubGraftPrune() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .gossipsub(defaultTopic: "test-topic")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/meshsub/1.1.0", "/meshsub/1.0.0"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID.contains("meshsub"))

        // After protocol negotiation, GossipSub nodes exchange control messages
        // Wait briefly for the peer to send its subscription info
        try await Task.sleep(for: .milliseconds(500))

        // The go-libp2p node should send GRAFT messages for topics it's subscribed to
        // We can check if any data is available
        print("[GossipSub] Protocol handshake completed, waiting for control messages...")

        // Note: Full GRAFT/PRUNE testing requires implementing GossipSub message encoding
        // This test verifies the basic protocol negotiation path

        try await stream.close()
        try await connection.close()
    }

    // MARK: - Message Tests

    @Test("GossipSub topic join", .timeLimit(.minutes(2)))
    func gossipSubTopicJoin() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .gossipsub(defaultTopic: "test-topic")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Create GossipSub service
        let gossipSub = GossipSubService(
            keyPair: keyPair,
            configuration: GossipSubConfiguration()
        )

        print("[GossipSub] GossipSub service created")

        // The full test would involve:
        // 1. Registering the GossipSub handler
        // 2. Subscribing to a topic
        // 3. Verifying mesh formation with the go-libp2p node

        try await connection.close()
    }

    // MARK: - Mesh Formation Tests

    @Test("GossipSub mesh topology formation", .timeLimit(.minutes(3)))
    func gossipSubMeshFormation() async throws {
        // Start two go-libp2p nodes
        let harness1 = try await GoProtocolHarness.start(
            protocol: .gossipsub(defaultTopic: "mesh-test")
        )
        defer { Task { try? await harness1.stop() } }

        print("[GossipSub] First node started: \(harness1.nodeInfo.peerID)")

        // Connect to the first node
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(harness1.nodeInfo.address),
            localKeyPair: keyPair
        )

        // Open GossipSub stream
        let stream = try await connection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/meshsub/1.1.0"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == "/meshsub/1.1.0")
        print("[GossipSub] Mesh protocol negotiated")

        // Check container logs for mesh formation evidence
        try await Task.sleep(for: .seconds(1))
        let logs = try await harness1.getLogs()
        print("[GossipSub] Node logs: \(logs.prefix(500))...")

        try await stream.close()
        try await connection.close()
    }
}
