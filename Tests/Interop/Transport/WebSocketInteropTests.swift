/// WebSocketInteropTests - WebSocket transport interoperability tests
///
/// Tests that swift-libp2p can communicate with go-libp2p nodes
/// over WebSocket transport with Noise security.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter WebSocketInteropTests

import Testing
import Foundation
import NIOCore
@testable import P2PTransportWebSocket
@testable import P2PSecurityNoise
@testable import P2PMuxYamux
@testable import P2PMux
@testable import P2PTransport
@testable import P2PCore
@testable import P2PNegotiation
@testable import P2PProtocols
@testable import P2PIdentify

/// Interoperability tests for WebSocket transport with go-libp2p
@Suite("WebSocket Transport Interop Tests", .serialized)
struct WebSocketInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p node via WebSocket", .timeLimit(.minutes(2)))
    func connectToGoViaWS() async throws {
        // Start go-libp2p WebSocket node
        let harness = try await GoWebSocketHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        print("[WS] Node info: \(nodeInfo)")

        // Create Swift client
        let keyPair = KeyPair.generateEd25519()
        let transport = WebSocketTransport()

        // Dial the WebSocket address
        let address = try Multiaddr(nodeInfo.address)
        let rawConnection = try await transport.dial(address)

        print("[WS] Raw connection established")

        // Step 1: Negotiate security protocol via multistream-select
        // libp2p requires negotiating /noise before starting the handshake
        let securityNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/noise"],
            read: { Data(buffer: try await rawConnection.read()) },
            write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
        )

        #expect(securityNegotiation.protocolID == "/noise")
        print("[WS] Security protocol negotiated: \(securityNegotiation.protocolID)")

        // Step 2: Perform Noise handshake (pass remainder from multistream-select)
        let noiseUpgrader = NoiseUpgrader()
        let securedConnection = try await noiseUpgrader.secure(
            rawConnection,
            localKeyPair: keyPair,
            as: .initiator,
            expectedPeer: nil,
            initialBuffer: securityNegotiation.remainder
        )

        print("[WS] Noise handshake completed")
        print("[WS] Remote peer: \(securedConnection.remotePeer)")

        // Verify connection is established
        #expect(securedConnection.remotePeer.description.contains(nodeInfo.peerID.prefix(8)))

        // Cleanup
        try await securedConnection.close()
    }

    @Test("WebSocket connection with Yamux muxing", .timeLimit(.minutes(2)))
    func wsWithYamuxMuxing() async throws {
        let harness = try await GoWebSocketHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = WebSocketTransport()

        // Dial WebSocket
        let address = try Multiaddr(nodeInfo.address)
        let rawConnection = try await transport.dial(address)

        // Step 1: Negotiate security protocol
        let securityNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/noise"],
            read: { Data(buffer: try await rawConnection.read()) },
            write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(securityNegotiation.protocolID == "/noise")
        print("[WS+Yamux] Security negotiated: /noise")

        // Step 2: Noise handshake (pass remainder from multistream-select)
        let noiseUpgrader = NoiseUpgrader()
        let securedConnection = try await noiseUpgrader.secure(
            rawConnection,
            localKeyPair: keyPair,
            as: .initiator,
            expectedPeer: nil,
            initialBuffer: securityNegotiation.remainder
        )
        print("[WS+Yamux] Noise handshake completed")

        // Step 3: Negotiate mux protocol
        let muxNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/yamux/1.0.0"],
            read: { Data(buffer: try await securedConnection.read()) },
            write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(muxNegotiation.protocolID == "/yamux/1.0.0")
        print("[WS+Yamux] Mux negotiated: /yamux/1.0.0")

        // Step 4: Yamux muxing
        let yamuxMuxer = YamuxMuxer()
        let muxedConnection = try await yamuxMuxer.multiplex(
            securedConnection,
            isInitiator: true
        )

        print("[WS+Yamux] Muxed connection established")

        // Open a stream
        let stream = try await muxedConnection.newStream()
        print("[WS+Yamux] Stream opened: \(stream.id)")

        // Close stream and connection
        try await stream.close()
        try await muxedConnection.close()
    }

    // MARK: - Identify Tests

    @Test("Identify go-libp2p node via WebSocket", .timeLimit(.minutes(2)))
    func identifyGoViaWS() async throws {
        let harness = try await GoWebSocketHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = WebSocketTransport()

        // Dial WebSocket
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
            protocols: [LibP2PProtocol.identify],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == LibP2PProtocol.identify)

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

        print("[WS] Identify agent: \(info.agentVersion ?? "unknown")")
        print("[WS] Identify protocols: \(info.protocols)")

        try await stream.close()
        try await muxedConnection.close()
    }

    // MARK: - Ping Tests

    @Test("Ping go-libp2p node via WebSocket", .timeLimit(.minutes(2)))
    func pingGoViaWS() async throws {
        let harness = try await GoWebSocketHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = WebSocketTransport()

        // Dial WebSocket
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
            protocols: [LibP2PProtocol.ping],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == LibP2PProtocol.ping)

        // Generate 32-byte random payload
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let startTime = ContinuousClock.now

        try await stream.write(ByteBuffer(bytes: payload))

        // Read echo response
        let response = try await stream.read()
        let rtt = ContinuousClock.now - startTime

        #expect(Data(buffer: response) == payload, "Ping response should match sent payload")
        #expect(rtt < .seconds(5), "RTT should be reasonable")

        print("[WS] Ping RTT: \(rtt)")

        try await stream.close()
        try await muxedConnection.close()
    }
}
