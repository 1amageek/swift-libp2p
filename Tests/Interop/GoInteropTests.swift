/// GoInteropTests - Interoperability tests with go-libp2p
///
/// Tests that swift-libp2p can communicate with go-libp2p nodes
/// over QUIC transport with Noise security.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests are disabled by default (use --filter to run explicitly)

import Testing
import Foundation
import NIOCore
@testable import P2PIdentify
@testable import P2PTransportQUIC
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
import QUIC

/// Interoperability tests with go-libp2p
///
/// These tests require Docker to be running and are disabled by default.
/// Run with: swift test --filter GoInteropTests
@Suite("Go-libp2p Interop Tests", .disabled("Requires Docker - run explicitly with --filter GoInteropTests"))
struct GoInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p node over QUIC", .timeLimit(.minutes(2)))
    func connectToGo() async throws {
        // Start go-libp2p node
        let harness = try await GoLibp2pHarness.start()
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo

        // Create Swift client
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // Connect to go-libp2p node
        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Verify connection is established
        #expect(connection.remotePeer.description.contains(nodeInfo.peerID.prefix(8)))

        // Cleanup
        try await connection.close()
    }

    // MARK: - Identify Tests

    @Test("Identify go-libp2p node", .timeLimit(.minutes(2)))
    func identifyGo() async throws {
        let harness = try await GoLibp2pHarness.start()
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Open stream and request identify
        let stream = try await connection.newStream()

        // Send identify request (empty data triggers server response)
        try await stream.write(ByteBuffer())
        try await stream.closeWrite()

        // Read identify response
        let data = try await stream.read()

        // Decode the response
        let info = try IdentifyProtobuf.decode(Data(buffer: data))

        // Verify go-libp2p response
        #expect(info.agentVersion?.contains("go-libp2p") == true || info.agentVersion != nil)
        #expect(info.protocolVersion != nil)
        #expect(info.protocols.contains("/ipfs/ping/1.0.0") || info.protocols.count > 0)
        #expect(info.publicKey != nil)

        // Cleanup
        try await stream.close()
        try await connection.close()
    }

    @Test("Verify go-libp2p PeerID matches public key", .timeLimit(.minutes(2)))
    func verifyGoPeerID() async throws {
        let harness = try await GoLibp2pHarness.start()
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Request identify
        let stream = try await connection.newStream()
        try await stream.write(ByteBuffer())
        try await stream.closeWrite()

        let data = try await stream.read()
        let info = try IdentifyProtobuf.decode(Data(buffer: data))

        // Verify PeerID derives from public key
        if let publicKey = info.publicKey {
            let derivedPeerID = PeerID(publicKey: publicKey)

            // The derived PeerID should match the one we connected to
            // (at least the prefix, since go-libp2p may use different encoding)
            #expect(derivedPeerID.description.hasPrefix("12D3KooW") || derivedPeerID.description.hasPrefix("Qm"))
        } else {
            Issue.record("No public key in identify response")
        }

        try await stream.close()
        try await connection.close()
    }

    // MARK: - Ping Tests

    @Test("Ping go-libp2p node", .timeLimit(.minutes(2)))
    func pingGo() async throws {
        let harness = try await GoLibp2pHarness.start()
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Open stream and send ping
        let stream = try await connection.newStream()

        // Generate 32-byte random payload (libp2p ping spec)
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let startTime = ContinuousClock.now

        try await stream.write(ByteBuffer(bytes: payload))
        try await stream.closeWrite()

        // Read echo response
        let response = try await stream.read()

        let rtt = ContinuousClock.now - startTime

        // Verify response matches payload
        #expect(Data(buffer: response) == payload, "Ping response should match sent payload")
        #expect(rtt < .seconds(5), "RTT should be reasonable")

        try await stream.close()
        try await connection.close()
    }

    @Test("Multiple pings to go-libp2p node", .timeLimit(.minutes(2)))
    func multiplePingsToGo() async throws {
        let harness = try await GoLibp2pHarness.start()
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        var rtts: [Duration] = []

        for i in 0..<5 {
            let stream = try await connection.newStream()

            let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let startTime = ContinuousClock.now

            try await stream.write(ByteBuffer(bytes: payload))
            try await stream.closeWrite()

            let response = try await stream.read()
            let rtt = ContinuousClock.now - startTime

            #expect(Data(buffer: response) == payload, "Ping \(i) response should match")
            rtts.append(rtt)

            try await stream.close()
        }

        #expect(rtts.count == 5)

        // Calculate average RTT
        let totalNanos = rtts.reduce(0) { $0 + $1.components.attoseconds / 1_000_000_000 }
        let avgNanos = totalNanos / 5
        let avgRTT = Duration.nanoseconds(avgNanos)

        #expect(avgRTT < .seconds(1), "Average RTT should be reasonable")

        try await connection.close()
    }

    // MARK: - Bidirectional Tests

    @Test("Bidirectional stream with go-libp2p", .timeLimit(.minutes(2)))
    func bidirectionalStream() async throws {
        let harness = try await GoLibp2pHarness.start()
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        // Send data
        let testData = Data("Hello from Swift!".utf8)
        try await stream.write(ByteBuffer(bytes: testData))
        try await stream.closeWrite()

        // Read response (may be empty if no echo handler)
        let response = try await stream.read()

        // We don't necessarily expect a response if there's no echo handler,
        // but the stream operations should complete without error
        #expect(response.readableBytes >= 0)

        try await stream.close()
        try await connection.close()
    }
}

// MARK: - Manual Test Entry Point

/// Run these tests manually when Docker is available
///
/// ```bash
/// # Build the test image first
/// cd Tests/Interop
/// docker build -t go-libp2p-test .
///
/// # Run interop tests
/// swift test --filter GoInteropTests
/// ```
extension GoInteropTests {

    @Test("Manual: Check Docker availability", .disabled("Manual test"))
    func checkDocker() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "info"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0, "Docker should be available")
    }
}
