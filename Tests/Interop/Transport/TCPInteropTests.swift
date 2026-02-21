/// TCPInteropTests - TCP transport interoperability tests
///
/// Tests that swift-libp2p can communicate with go-libp2p nodes
/// over TCP transport with Noise security.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter TCPInteropTests

import Testing
import Foundation
import NIOCore
@testable import P2PTransportTCP
@testable import P2PSecurityNoise
@testable import P2PMuxYamux
@testable import P2PMux
@testable import P2PTransport
@testable import P2PCore
@testable import P2PNegotiation
@testable import P2PProtocols
@testable import P2PIdentify

/// Interoperability tests for TCP transport with go-libp2p
@Suite("TCP Transport Interop Tests", .serialized)
struct TCPInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p node via TCP", .timeLimit(.minutes(2)))
    func connectToGoViaTCP() async throws {
        // Start go-libp2p TCP node
        let harness = try await GoTCPHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        print("[TCP] Node info: \(nodeInfo)")

        // Create Swift client
        let keyPair = KeyPair.generateEd25519()
        let transport = TCPTransport()

        // Dial the TCP address
        let address = try Multiaddr(nodeInfo.address)
        let rawConnection = try await transport.dial(address)

        print("[TCP] Raw connection established")

        // Step 1: Negotiate security protocol via multistream-select
        // libp2p requires negotiating /noise before starting the handshake
        let securityNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/noise"],
            read: { Data(buffer: try await rawConnection.read()) },
            write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
        )

        #expect(securityNegotiation.protocolID == "/noise")
        print("[TCP] Security protocol negotiated: \(securityNegotiation.protocolID)")

        // Step 2: Perform Noise handshake (pass remainder from multistream-select)
        let noiseUpgrader = NoiseUpgrader()
        let securedConnection = try await noiseUpgrader.secure(
            rawConnection,
            localKeyPair: keyPair,
            as: .initiator,
            expectedPeer: nil,
            initialBuffer: securityNegotiation.remainder
        )

        print("[TCP] Noise handshake completed")
        print("[TCP] Remote peer: \(securedConnection.remotePeer)")

        // Verify connection is established
        #expect(securedConnection.remotePeer.description.contains(nodeInfo.peerID.prefix(8)))

        // Cleanup
        try await securedConnection.close()
    }

    @Test("TCP connection with Yamux muxing", .timeLimit(.minutes(2)))
    func tcpWithYamuxMuxing() async throws {
        let harness = try await GoTCPHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = TCPTransport()

        // Dial TCP
        let address = try Multiaddr(nodeInfo.address)
        let rawConnection = try await transport.dial(address)

        // Step 1: Negotiate security protocol
        let securityNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/noise"],
            read: { Data(buffer: try await rawConnection.read()) },
            write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(securityNegotiation.protocolID == "/noise")
        print("[TCP+Yamux] Security negotiated: /noise")

        // Step 2: Noise handshake (pass remainder from multistream-select)
        let noiseUpgrader = NoiseUpgrader()
        let securedConnection = try await noiseUpgrader.secure(
            rawConnection,
            localKeyPair: keyPair,
            as: .initiator,
            expectedPeer: nil,
            initialBuffer: securityNegotiation.remainder
        )
        print("[TCP+Yamux] Noise handshake completed")

        // Step 3: Negotiate mux protocol
        let muxNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/yamux/1.0.0"],
            read: { Data(buffer: try await securedConnection.read()) },
            write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(muxNegotiation.protocolID == "/yamux/1.0.0")
        print("[TCP+Yamux] Mux negotiated: /yamux/1.0.0")

        // Step 4: Yamux muxing
        let yamuxMuxer = YamuxMuxer()
        let muxedConnection = try await yamuxMuxer.multiplex(
            securedConnection,
            isInitiator: true
        )

        print("[TCP+Yamux] Muxed connection established")

        // Open a stream
        let stream = try await muxedConnection.newStream()
        print("[TCP+Yamux] Stream opened: \(stream.id)")

        // Close stream and connection
        try await stream.close()
        try await muxedConnection.close()
    }

    // MARK: - Identify Tests

    @Test("Identify go-libp2p node via TCP", .timeLimit(.minutes(2)))
    func identifyGoViaTCP() async throws {
        let harness = try await GoTCPHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = TCPTransport()

        // Dial TCP
        let address = try Multiaddr(nodeInfo.address)
        let rawConnection = try await transport.dial(address)

        // Step 1: Negotiate security protocol
        let securityNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/noise"],
            read: { Data(buffer: try await rawConnection.read()) },
            write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(securityNegotiation.protocolID == "/noise")

        // Step 2: Noise handshake (pass remainder from multistream-select)
        let noiseUpgrader = NoiseUpgrader()
        let securedConnection = try await noiseUpgrader.secure(
            rawConnection,
            localKeyPair: keyPair,
            as: .initiator,
            expectedPeer: nil,
            initialBuffer: securityNegotiation.remainder
        )

        // Step 3: Negotiate mux protocol
        let muxNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/yamux/1.0.0"],
            read: { Data(buffer: try await securedConnection.read()) },
            write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(muxNegotiation.protocolID == "/yamux/1.0.0")

        // Step 4: Yamux muxing
        let yamuxMuxer = YamuxMuxer()
        let muxedConnection = try await yamuxMuxer.multiplex(
            securedConnection,
            isInitiator: true
        )

        // Open stream and negotiate identify protocol
        let stream = try await muxedConnection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [ProtocolID.identify],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == ProtocolID.identify)

        // Use remainder from negotiation if available
        let bytes: Data
        if !negotiationResult.remainder.isEmpty {
            bytes = negotiationResult.remainder
        } else {
            try await Task.sleep(for: .seconds(1))
            let data = try await stream.read()
            bytes = Data(buffer: data)
        }

        // Decode identify response
        let (_, prefixBytes) = try Varint.decode(bytes)
        let protobufData = bytes.dropFirst(prefixBytes)
        let info = try IdentifyProtobuf.decode(Data(protobufData))

        // Verify response
        #expect(info.agentVersion != nil)
        #expect(info.protocolVersion != nil)
        #expect(info.publicKey != nil)

        print("[TCP] Identify agent: \(info.agentVersion ?? "unknown")")
        print("[TCP] Identify protocols: \(info.protocols)")

        try await stream.close()
        try await muxedConnection.close()
    }

    // MARK: - Ping Tests

    @Test("Ping go-libp2p node via TCP", .timeLimit(.minutes(2)))
    func pingGoViaTCP() async throws {
        let harness = try await GoTCPHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = TCPTransport()

        // Dial TCP
        let address = try Multiaddr(nodeInfo.address)
        let rawConnection = try await transport.dial(address)

        // Step 1: Negotiate security protocol
        let securityNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/noise"],
            read: { Data(buffer: try await rawConnection.read()) },
            write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(securityNegotiation.protocolID == "/noise")

        // Step 2: Noise handshake (pass remainder from multistream-select)
        let noiseUpgrader = NoiseUpgrader()
        let securedConnection = try await noiseUpgrader.secure(
            rawConnection,
            localKeyPair: keyPair,
            as: .initiator,
            expectedPeer: nil,
            initialBuffer: securityNegotiation.remainder
        )

        // Step 3: Negotiate mux protocol
        let muxNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/yamux/1.0.0"],
            read: { Data(buffer: try await securedConnection.read()) },
            write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(muxNegotiation.protocolID == "/yamux/1.0.0")

        // Step 4: Yamux muxing
        let yamuxMuxer = YamuxMuxer()
        let muxedConnection = try await yamuxMuxer.multiplex(
            securedConnection,
            isInitiator: true
        )

        // Open stream and negotiate ping protocol
        let stream = try await muxedConnection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [ProtocolID.ping],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == ProtocolID.ping)

        // Generate 32-byte random payload
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let startTime = ContinuousClock.now

        try await stream.write(ByteBuffer(bytes: payload))

        // Read echo response
        let response = try await stream.read()
        let rtt = ContinuousClock.now - startTime

        #expect(Data(buffer: response) == payload, "Ping response should match sent payload")
        #expect(rtt < .seconds(5), "RTT should be reasonable")

        print("[TCP] Ping RTT: \(rtt)")

        try await stream.close()
        try await muxedConnection.close()
    }
}
