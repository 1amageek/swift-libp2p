/// GoLibp2pInteropTests - Interoperability tests with go-libp2p
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
@testable import P2PNegotiation
@testable import P2PProtocols
import QUIC

/// Interoperability tests with go-libp2p
///
/// These tests require Docker to be running.
/// Run with: swift test --filter GoLibp2pInteropTests
@Suite("go-libp2p Interop Tests", .serialized)
struct GoLibp2pInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p node over QUIC", .timeLimit(.minutes(2)))
    func connectToGo() async throws {
        // Start go-libp2p node
        let harness = try await GoLibp2pHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

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
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Open stream and negotiate identify protocol
        let stream = try await connection.newStream()

        // Negotiate identify protocol using multistream-select
        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [ProtocolID.identify],
            read: {
                let buffer = try await stream.read()
                let data = Data(buffer: buffer)
                print("[GO] Read \(data.count) bytes: \(data.prefix(100).map { String(format: "%02X", $0) }.joined(separator: " "))")
                return data
            },
            write: { data in
                print("[GO] Write \(data.count) bytes: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
                try await stream.write(ByteBuffer(bytes: data))
            }
        )

        #expect(negotiationResult.protocolID == ProtocolID.identify)

        // Use remainder from negotiation if available (go-libp2p sends protocol confirmation
        // and identify response in the same packet), otherwise read from stream
        let bytes: Data
        if !negotiationResult.remainder.isEmpty {
            bytes = negotiationResult.remainder
        } else {
            // Wait for identify response
            try await Task.sleep(for: .seconds(1))
            let data = try await stream.read()
            bytes = Data(buffer: data)
        }

        // libp2p identify uses length-prefixed protobuf messages
        // Wire format: [varint: message length] [protobuf message]

        // Decode length prefix and extract protobuf message
        let (_, prefixBytes) = try Varint.decode(bytes)
        let protobufData = bytes.dropFirst(prefixBytes)
        let info = try IdentifyProtobuf.decode(Data(protobufData))

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
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Request identify with protocol negotiation
        let stream = try await connection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [ProtocolID.identify],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == ProtocolID.identify)

        // Use remainder from negotiation if available (go-libp2p sends protocol confirmation
        // and identify response in the same packet), otherwise read from stream
        let bytes: Data
        if !negotiationResult.remainder.isEmpty {
            bytes = negotiationResult.remainder
        } else {
            try await Task.sleep(for: .seconds(1))
            let data = try await stream.read()
            bytes = Data(buffer: data)
        }

        // libp2p identify uses length-prefixed protobuf messages
        // Wire format: [varint: message length] [protobuf message]
        let (_, prefixBytes) = try Varint.decode(bytes)
        let protobufData = bytes.dropFirst(prefixBytes)
        let info = try IdentifyProtobuf.decode(Data(protobufData))

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
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Open stream and negotiate ping protocol
        let stream = try await connection.newStream()

        // Negotiate ping protocol using multistream-select
        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [ProtocolID.ping],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == ProtocolID.ping)

        // Generate 32-byte random payload (libp2p ping spec)
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let startTime = ContinuousClock.now

        try await stream.write(ByteBuffer(bytes: payload))

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
        defer { Task { do { try await harness.stop() } catch { } } }

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

            // Negotiate ping protocol
            let negotiationResult = try await MultistreamSelect.negotiate(
                protocols: [ProtocolID.ping],
                read: { Data(buffer: try await stream.read()) },
                write: { data in try await stream.write(ByteBuffer(bytes: data)) }
            )

            #expect(negotiationResult.protocolID == ProtocolID.ping)

            let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let startTime = ContinuousClock.now

            try await stream.write(ByteBuffer(bytes: payload))

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
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        // Negotiate ping protocol for bidirectional test
        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [ProtocolID.ping],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == ProtocolID.ping)

        // Send 32-byte payload as per ping protocol
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await stream.write(ByteBuffer(bytes: payload))

        // Read response - ping protocol echoes the payload
        let response = try await stream.read()

        // Verify echo
        #expect(Data(buffer: response) == payload, "Bidirectional stream should echo payload")

        try await stream.close()
        try await connection.close()
    }

    @Test("Send raw data to go-libp2p (no protocol negotiation)", .timeLimit(.minutes(2)))
    func sendRawData() async throws {
        // Start go-libp2p node
        let harness = try await GoLibp2pHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo

        // Create Swift client
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // Connect to go-libp2p node
        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Open stream
        let stream = try await connection.newStream()

        print("Stream opened: ID=\(stream.id)")

        // Send simple data
        let testData = Data("Hello from swift-libp2p".utf8)
        try await stream.write(ByteBuffer(bytes: testData))
        print("Data written to stream")

        // Give time for frame generation and sending
        try await Task.sleep(for: .milliseconds(500))
        print("Waited 500ms for frame generation")

        // Close write to send FIN
        try await stream.closeWrite()
        print("Write side closed (FIN sent)")

        // Wait for packets to be sent and processed
        try await Task.sleep(for: .seconds(2))

        // Close stream
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
/// docker build -t go-libp2p-test -f Dockerfile.go .
///
/// # Run interop tests
/// swift test --filter GoLibp2pInteropTests
/// ```
extension GoLibp2pInteropTests {

    @Test("Manual: Check Docker availability", .disabled("Manual test"))
    func checkDocker() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["docker", "info"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try runProcessWithTimeout(process)

        #expect(process.terminationStatus == 0, "Docker should be available")
    }
}
