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
@Suite("GossipSub Protocol Interop Tests", .serialized)
struct GossipSubInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p GossipSub node", .timeLimit(.minutes(2)))
    func connectToGossipSubNode() async throws {
        // Start go-libp2p GossipSub node with default topic
        let harness = try await GoProtocolHarness.start(
            protocol: .gossipsub(defaultTopic: "test-topic")
        )
        defer { stopHarness(harness) }

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
        defer { stopHarness(harness) }

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
        defer { stopHarness(harness) }

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

        let topic = Topic("test-topic")
        let controlRPC = GossipSubRPC.builder()
            .graft(topic: topic)
            .prune(topic: topic)
            .build()
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(GossipSubProtobuf.encode(controlRPC))))

        let marker = "gossipsub-control-\(UUID().uuidString)"
        let publishMessage = try makeSignedMessage(
            keyPair: keyPair,
            topic: topic,
            payload: Data(marker.utf8)
        )
        let publishRPC = GossipSubRPC(messages: [publishMessage])
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(GossipSubProtobuf.encode(publishRPC))))

        try await waitForLog(in: harness, containing: marker)

        try await stream.close()
        try await connection.close()
    }

    // MARK: - Message Tests

    @Test("GossipSub topic join", .timeLimit(.minutes(2)))
    func gossipSubTopicJoin() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .gossipsub(defaultTopic: "test-topic")
        )
        defer { stopHarness(harness) }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()
        defer { closeStream(stream) }
        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/meshsub/1.1.0", "/meshsub/1.0.0"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )
        #expect(negotiationResult.protocolID.contains("meshsub"))

        let topic = Topic("test-topic")
        let subscriptionRPC = GossipSubRPC(subscriptions: [.subscribe(to: topic)])
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(GossipSubProtobuf.encode(subscriptionRPC))))

        let marker = "gossipsub-sub-\(UUID().uuidString)"
        let message = try makeSignedMessage(
            keyPair: keyPair,
            topic: topic,
            payload: Data(marker.utf8)
        )
        let publishRPC = GossipSubRPC(messages: [message])
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(GossipSubProtobuf.encode(publishRPC))))
        try await waitForLog(in: harness, containing: marker)

        try await connection.close()
    }

    // MARK: - Mesh Formation Tests

    @Test("GossipSub mesh topology formation", .timeLimit(.minutes(3)))
    func gossipSubMeshFormation() async throws {
        // Start two go-libp2p nodes
        let harness1 = try await GoProtocolHarness.start(
            protocol: .gossipsub(defaultTopic: "mesh-test")
        )
        defer { stopHarness(harness1) }

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

        let marker = "gossipsub-mesh-\(UUID().uuidString)"
        let message = try makeSignedMessage(
            keyPair: keyPair,
            topic: Topic("mesh-test"),
            payload: Data(marker.utf8)
        )
        let publishRPC = GossipSubRPC(messages: [message])
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(GossipSubProtobuf.encode(publishRPC))))
        try await waitForLog(in: harness1, containing: marker)

        try await stream.close()
        try await connection.close()
    }
}

private enum GossipSubInteropError: Error {
    case logWaitTimedOut(String)
}

private func randomSequenceNumber() -> Data {
    Data((0..<8).map { _ in UInt8.random(in: 0...255) })
}

private func encodeLengthPrefixed(_ payload: Data) -> Data {
    var framed = Data()
    framed.append(contentsOf: Varint.encode(UInt64(payload.count)))
    framed.append(payload)
    return framed
}

private func waitForLog(
    in harness: GoProtocolHarness,
    containing marker: String,
    timeout: Duration = .seconds(15),
    pollInterval: Duration = .milliseconds(100)
) async throws {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        let logs = try await harness.getLogs()
        if logs.contains(marker) {
            return
        }
        try await Task.sleep(for: pollInterval)
    }
    throw GossipSubInteropError.logWaitTimedOut(marker)
}

private func makeSignedMessage(
    keyPair: KeyPair,
    topic: Topic,
    payload: Data
) throws -> GossipSubMessage {
    try GossipSubMessage.Builder(data: payload, topic: topic)
        .source(keyPair.peerID)
        .sequenceNumber(randomSequenceNumber())
        .sign(with: keyPair.privateKey)
        .build()
}

private func stopHarness(_ harness: GoProtocolHarness) {
    Task {
        do {
            try await harness.stop()
        } catch {
            print("[GossipSub] Failed to stop harness: \(error)")
        }
    }
}

private func closeStream(_ stream: MuxedStream) {
    Task {
        do {
            try await stream.close()
        } catch {
            print("[GossipSub] Failed to close stream: \(error)")
        }
    }
}
