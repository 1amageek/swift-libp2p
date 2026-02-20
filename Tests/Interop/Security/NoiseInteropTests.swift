/// NoiseInteropTests - Noise security protocol interoperability tests
///
/// Tests that swift-libp2p Noise implementation is compatible with go-libp2p.
/// Focuses on the Noise XX handshake pattern and encrypted communication.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter NoiseInteropTests

import Testing
import Foundation
import NIOCore
@testable import P2PTransportTCP
@testable import P2PSecurityNoise
@testable import P2PMuxYamux
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
@testable import P2PNegotiation
@testable import P2PProtocols

/// Interoperability tests for Noise security protocol
@Suite("Noise Security Interop Tests", .serialized)
struct NoiseInteropTests {

    // MARK: - Handshake Tests

    @Test("Noise XX handshake with go-libp2p", .timeLimit(.minutes(2)))
    func noiseHandshakeWithGo() async throws {
        // Start go-libp2p Noise node
        let harness = try await GoTCPHarness.start(
            dockerfile: "Dockerfiles/Dockerfile.noise.go",
            imageName: "go-libp2p-noise-test"
        )
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        print("[Noise] Testing handshake with: \(nodeInfo.peerID)")

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
        print("[Noise] Security protocol negotiated")

        // Step 2: Perform Noise XX handshake (pass remainder from multistream-select)
        let noiseUpgrader = NoiseUpgrader()
        let securedConnection = try await noiseUpgrader.secure(
            rawConnection,
            localKeyPair: keyPair,
            as: .initiator,
            expectedPeer: nil,
            initialBuffer: securityNegotiation.remainder
        )

        // Verify handshake completed
        #expect(securedConnection.remotePeer.description.contains("12D3KooW"))
        print("[Noise] Handshake successful, remote peer: \(securedConnection.remotePeer)")

        try await securedConnection.close()
    }

    @Test("Noise key exchange verification", .timeLimit(.minutes(2)))
    func noiseKeyExchange() async throws {
        let harness = try await GoTCPHarness.start(
            dockerfile: "Dockerfiles/Dockerfile.noise.go",
            imageName: "go-libp2p-noise-test"
        )
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = TCPTransport()

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

        // Verify the remote peer ID matches the expected peer ID
        let expectedPeerIDPrefix = String(nodeInfo.peerID.prefix(12))
        let actualPeerIDPrefix = String(securedConnection.remotePeer.description.prefix(12))
        #expect(expectedPeerIDPrefix == actualPeerIDPrefix, "Peer ID should match after key exchange")

        print("[Noise] Key exchange verified: \(securedConnection.remotePeer)")

        try await securedConnection.close()
    }

    // MARK: - Encrypted Communication Tests

    @Test("Encrypted ping over Noise", .timeLimit(.minutes(2)))
    func encryptedPing() async throws {
        let harness = try await GoTCPHarness.start(
            dockerfile: "Dockerfiles/Dockerfile.noise.go",
            imageName: "go-libp2p-noise-test"
        )
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

        // Open stream and negotiate ping
        let stream = try await muxedConnection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.ping],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == LibP2PProtocol.ping)

        // Send encrypted ping payload
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await stream.write(ByteBuffer(bytes: payload))

        // Read encrypted response
        let response = try await stream.read()

        // Verify decrypted response matches original payload
        #expect(Data(buffer: response) == payload, "Encrypted ping response should match")

        print("[Noise] Encrypted communication verified")

        try await stream.close()
        try await muxedConnection.close()
    }

    @Test("Multiple encrypted messages", .timeLimit(.minutes(2)))
    func multipleEncryptedMessages() async throws {
        let harness = try await GoTCPHarness.start(
            dockerfile: "Dockerfiles/Dockerfile.noise.go",
            imageName: "go-libp2p-noise-test"
        )
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

        // Test multiple ping-pong exchanges
        for i in 0..<3 {
            let stream = try await muxedConnection.newStream()

            let negotiationResult = try await MultistreamSelect.negotiate(
                protocols: [LibP2PProtocol.ping],
                read: { Data(buffer: try await stream.read()) },
                write: { data in try await stream.write(ByteBuffer(bytes: data)) }
            )

            #expect(negotiationResult.protocolID == LibP2PProtocol.ping)

            let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try await stream.write(ByteBuffer(bytes: payload))

            let response = try await stream.read()
            #expect(Data(buffer: response) == payload, "Message \(i) should match")

            try await stream.close()
            print("[Noise] Message \(i + 1) verified")
        }

        try await muxedConnection.close()
    }
}
