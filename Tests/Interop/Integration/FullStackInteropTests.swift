/// FullStackInteropTests - Full stack integration tests
///
/// Tests complete protocol stacks (Transport + Security + Mux + Protocol)
/// with go-libp2p and rust-libp2p implementations.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter FullStackInteropTests

import Testing
import Foundation
import NIOCore
@testable import P2PTransportQUIC
@testable import P2PTransportTCP
@testable import P2PSecurityNoise
@testable import P2PMuxYamux
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
@testable import P2PNegotiation
@testable import P2PProtocols
@testable import P2PIdentify

/// Full stack integration tests
@Suite("Full Stack Interop Tests", .serialized)
struct FullStackInteropTests {

    // MARK: - TCP + Noise + Yamux + Ping

    @Test("TCP + Noise + Yamux + Ping stack", .timeLimit(.minutes(3)))
    func tcpNoiseYamuxPing() async throws {
        // Start go-libp2p TCP node
        let harness = try await GoTCPHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        print("[FullStack] TCP node: \(nodeInfo.address)")

        let keyPair = KeyPair.generateEd25519()

        // Layer 1: TCP Transport
        let transport = TCPTransport()
        let rawConnection = try await transport.dial(try Multiaddr(nodeInfo.address))
        print("[FullStack] TCP connection established")

        // Layer 2a: Negotiate Noise security protocol
        let securityNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/noise"],
            read: { Data(buffer: try await rawConnection.read()) },
            write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(securityNegotiation.protocolID == "/noise")
        print("[FullStack] Security protocol negotiated: /noise")

        // Layer 2b: Noise handshake (pass remainder from multistream-select)
        let noiseUpgrader = NoiseUpgrader()
        let securedConnection = try await noiseUpgrader.secure(
            rawConnection,
            localKeyPair: keyPair,
            as: .initiator,
            expectedPeer: nil,
            initialBuffer: securityNegotiation.remainder
        )
        print("[FullStack] Noise handshake completed")

        // Layer 3a: Negotiate Yamux mux protocol
        let muxNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/yamux/1.0.0"],
            read: { Data(buffer: try await securedConnection.read()) },
            write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
        )
        #expect(muxNegotiation.protocolID == "/yamux/1.0.0")
        print("[FullStack] Mux protocol negotiated: /yamux/1.0.0")

        // Layer 3b: Yamux Muxer
        let yamuxMuxer = YamuxMuxer()
        let muxedConnection = try await yamuxMuxer.multiplex(
            securedConnection,
            isInitiator: true
        )
        print("[FullStack] Yamux muxing established")

        // Layer 4: Ping Protocol
        let stream = try await muxedConnection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.ping],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == LibP2PProtocol.ping)
        print("[FullStack] Ping protocol negotiated")

        // Send ping
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let startTime = ContinuousClock.now
        try await stream.write(ByteBuffer(bytes: payload))

        let response = try await stream.read()
        let rtt = ContinuousClock.now - startTime

        #expect(Data(buffer: response) == payload)
        print("[FullStack] TCP+Noise+Yamux+Ping RTT: \(rtt)")

        try await stream.close()
        try await muxedConnection.close()
    }

    // MARK: - QUIC + TLS + Identify + Ping

    @Test("QUIC + TLS + Identify + Ping stack", .timeLimit(.minutes(3)))
    func quicTlsIdentifyPing() async throws {
        // Start go-libp2p QUIC node
        let harness = try await GoLibp2pHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        print("[FullStack] QUIC node: \(nodeInfo.address)")

        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // QUIC handles security (TLS) internally
        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )
        print("[FullStack] QUIC+TLS connection established")

        // Test Identify protocol
        let identifyStream = try await connection.newStream()

        let identifyNegotiation = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.identify],
            read: { Data(buffer: try await identifyStream.read()) },
            write: { data in try await identifyStream.write(ByteBuffer(bytes: data)) }
        )

        #expect(identifyNegotiation.protocolID == LibP2PProtocol.identify)

        // Get identify response
        let bytes: Data
        if !identifyNegotiation.remainder.isEmpty {
            bytes = identifyNegotiation.remainder
        } else {
            try await Task.sleep(for: .seconds(1))
            let data = try await identifyStream.read()
            bytes = Data(buffer: data)
        }

        let (_, prefixBytes) = try Varint.decode(bytes)
        let protobufData = bytes.dropFirst(prefixBytes)
        let info = try IdentifyProtobuf.decode(Data(protobufData))

        #expect(info.agentVersion != nil)
        print("[FullStack] Identify agent: \(info.agentVersion ?? "unknown")")

        try await identifyStream.close()

        // Test Ping protocol
        let pingStream = try await connection.newStream()

        let pingNegotiation = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.ping],
            read: { Data(buffer: try await pingStream.read()) },
            write: { data in try await pingStream.write(ByteBuffer(bytes: data)) }
        )

        #expect(pingNegotiation.protocolID == LibP2PProtocol.ping)

        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await pingStream.write(ByteBuffer(bytes: payload))

        let response = try await pingStream.read()
        #expect(Data(buffer: response) == payload)
        print("[FullStack] QUIC+TLS+Ping successful")

        try await pingStream.close()
        try await connection.close()
    }

    // MARK: - Multi-Protocol Session

    @Test("Multi-protocol session", .timeLimit(.minutes(3)))
    func multiProtocolSession() async throws {
        let harness = try await GoLibp2pHarness.start()
        defer { Task { do { try await harness.stop() } catch { } } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // Open multiple streams for different protocols simultaneously
        async let identifyTask = Task {
            let stream = try await connection.newStream()
            let result = try await MultistreamSelect.negotiate(
                protocols: [LibP2PProtocol.identify],
                read: { Data(buffer: try await stream.read()) },
                write: { data in try await stream.write(ByteBuffer(bytes: data)) }
            )
            try await stream.close()
            return result.protocolID
        }

        async let pingTask = Task {
            let stream = try await connection.newStream()
            let result = try await MultistreamSelect.negotiate(
                protocols: [LibP2PProtocol.ping],
                read: { Data(buffer: try await stream.read()) },
                write: { data in try await stream.write(ByteBuffer(bytes: data)) }
            )

            let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try await stream.write(ByteBuffer(bytes: payload))
            let response = try await stream.read()
            try await stream.close()

            return (result.protocolID, Data(buffer: response) == payload)
        }

        let (identifyProtocol, (pingProtocol, pingSuccess)) = try await (identifyTask.value, pingTask.value)

        #expect(identifyProtocol == LibP2PProtocol.identify)
        #expect(pingProtocol == LibP2PProtocol.ping)
        #expect(pingSuccess == true)

        print("[FullStack] Multi-protocol session successful")
        print("[FullStack] Identify: \(identifyProtocol)")
        print("[FullStack] Ping: \(pingProtocol), success: \(pingSuccess)")

        try await connection.close()
    }

    // MARK: - Cross-Implementation Tests

    @Test("Go and Rust interop comparison", .timeLimit(.minutes(4)))
    func goRustComparison() async throws {
        // Start both Go and Rust nodes
        let goHarness = try await GoLibp2pHarness.start()
        defer { Task { do { try await goHarness.stop() } catch { } } }

        let rustHarness = try await RustLibp2pHarness.start()
        defer { Task { do { try await rustHarness.stop() } catch { } } }

        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // Test Go node
        let goConnection = try await transport.dialSecured(
            Multiaddr(goHarness.nodeInfo.address),
            localKeyPair: keyPair
        )

        let goStream = try await goConnection.newStream()
        let goResult = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.ping],
            read: { Data(buffer: try await goStream.read()) },
            write: { data in try await goStream.write(ByteBuffer(bytes: data)) }
        )

        let goPayload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let goStart = ContinuousClock.now
        try await goStream.write(ByteBuffer(bytes: goPayload))
        let goResponse = try await goStream.read()
        let goRTT = ContinuousClock.now - goStart

        #expect(Data(buffer: goResponse) == goPayload)
        try await goStream.close()
        try await goConnection.close()

        // Test Rust node
        let rustConnection = try await transport.dialSecured(
            Multiaddr(rustHarness.nodeInfo.address),
            localKeyPair: keyPair
        )

        let rustStream = try await rustConnection.newStream()
        let rustResult = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.ping],
            read: { Data(buffer: try await rustStream.read()) },
            write: { data in try await rustStream.write(ByteBuffer(bytes: data)) }
        )

        let rustPayload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let rustStart = ContinuousClock.now
        try await rustStream.write(ByteBuffer(bytes: rustPayload))
        let rustResponse = try await rustStream.read()
        let rustRTT = ContinuousClock.now - rustStart

        #expect(Data(buffer: rustResponse) == rustPayload)
        try await rustStream.close()
        try await rustConnection.close()

        // Compare results
        print("[FullStack] Go implementation:")
        print("  Protocol: \(goResult.protocolID)")
        print("  RTT: \(goRTT)")

        print("[FullStack] Rust implementation:")
        print("  Protocol: \(rustResult.protocolID)")
        print("  RTT: \(rustRTT)")

        #expect(goResult.protocolID == rustResult.protocolID)
    }
}
