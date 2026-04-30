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
    private func withWSHarness<T: Sendable>(
        _ operation: @Sendable (GoWebSocketHarness) async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?

        for attempt in 1...2 {
            let harness = try await GoWebSocketHarness.start()
            do {
                let result = try await operation(harness)
                do {
                    try await harness.stop()
                } catch {
                    // Best effort cleanup only.
                }
                return result
            } catch {
                lastError = error
                do {
                    try await harness.stop()
                } catch {
                    // Best effort cleanup only.
                }

                if attempt == 1 {
                    print("[WS] Retrying after transient interop failure: \(error)")
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        if let lastError {
            throw lastError
        }

        throw CancellationError()
    }

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p node via WebSocket", .timeLimit(.minutes(2)))
    func connectToGoViaWS() async throws {
        try await withWSHarness { harness in
            let nodeInfo = harness.nodeInfo
            print("[WS] Node info: \(nodeInfo)")

            let keyPair = KeyPair.generateEd25519()
            let transport = WebSocketTransport()
            let address = try Multiaddr(nodeInfo.address)
            let rawConnection = try await transport.dial(address)

            print("[WS] Raw connection established")

            let securityNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { Data(buffer: try await rawConnection.read()) },
                write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
            )

            #expect(securityNegotiation.protocolID == "/noise")
            print("[WS] Security protocol negotiated: \(securityNegotiation.protocolID)")

            let noiseUpgrader = NoiseUpgrader()
            let securedConnection = try await noiseUpgrader.secure(
                rawConnection,
                localKeyPair: keyPair,
                as: .initiator,
                expectedPeer: nil,
                initialBuffer: ByteBuffer(bytes: securityNegotiation.remainder)
            )

            print("[WS] Noise handshake completed")
            print("[WS] Remote peer: \(securedConnection.remotePeer)")

            #expect(securedConnection.remotePeer.description.contains(nodeInfo.peerID.prefix(8)))

            try await securedConnection.close()
        }
    }

    @Test("WebSocket connection with Yamux muxing", .timeLimit(.minutes(2)))
    func wsWithYamuxMuxing() async throws {
        try await withWSHarness { harness in
            let nodeInfo = harness.nodeInfo
            let keyPair = KeyPair.generateEd25519()
            let transport = WebSocketTransport()
            let address = try Multiaddr(nodeInfo.address)
            let rawConnection = try await transport.dial(address)

            let securityNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { Data(buffer: try await rawConnection.read()) },
                write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
            )
            #expect(securityNegotiation.protocolID == "/noise")
            print("[WS+Yamux] Security negotiated: /noise")

            let noiseUpgrader = NoiseUpgrader()
            let securedConnection = try await noiseUpgrader.secure(
                rawConnection,
                localKeyPair: keyPair,
                as: .initiator,
                expectedPeer: nil,
                initialBuffer: ByteBuffer(bytes: securityNegotiation.remainder)
            )
            print("[WS+Yamux] Noise handshake completed")

            let muxNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/yamux/1.0.0"],
                read: { Data(buffer: try await securedConnection.read()) },
                write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
            )
            #expect(muxNegotiation.protocolID == "/yamux/1.0.0")
            print("[WS+Yamux] Mux negotiated: /yamux/1.0.0")

            let yamuxMuxer = YamuxMuxer()
            let muxedConnection = try await yamuxMuxer.multiplex(
                securedConnection,
                isInitiator: true
            )

            print("[WS+Yamux] Muxed connection established")

            let stream = try await muxedConnection.newStream()
            print("[WS+Yamux] Stream opened: \(stream.id)")

            try await stream.close()
            try await muxedConnection.close()
        }
    }

    // MARK: - Identify Tests

    @Test("Identify go-libp2p node via WebSocket", .timeLimit(.minutes(2)))
    func identifyGoViaWS() async throws {
        try await withWSHarness { harness in
            let nodeInfo = harness.nodeInfo
            let keyPair = KeyPair.generateEd25519()
            let transport = WebSocketTransport()
            let address = try Multiaddr(nodeInfo.address)
            let rawConnection = try await transport.dial(address)

            let securityNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { Data(buffer: try await rawConnection.read()) },
                write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
            )
            #expect(securityNegotiation.protocolID == "/noise")

            let noiseUpgrader = NoiseUpgrader()
            let securedConnection = try await noiseUpgrader.secure(
                rawConnection,
                localKeyPair: keyPair,
                as: .initiator,
                expectedPeer: nil,
                initialBuffer: ByteBuffer(bytes: securityNegotiation.remainder)
            )

            let muxNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/yamux/1.0.0"],
                read: { Data(buffer: try await securedConnection.read()) },
                write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
            )
            #expect(muxNegotiation.protocolID == "/yamux/1.0.0")

            let yamuxMuxer = YamuxMuxer()
            let muxedConnection = try await yamuxMuxer.multiplex(
                securedConnection,
                isInitiator: true
            )

            let stream = try await muxedConnection.newStream()

            let negotiationResult = try await MultistreamSelect.negotiate(
                protocols: [ProtocolID.identify],
                read: { Data(buffer: try await stream.read()) },
                write: { data in try await stream.write(ByteBuffer(bytes: data)) }
            )

            #expect(negotiationResult.protocolID == ProtocolID.identify)

            let bytes: Data
            if !negotiationResult.remainder.isEmpty {
                bytes = negotiationResult.remainder
            } else {
                try await Task.sleep(for: .seconds(1))
                let data = try await stream.read()
                bytes = Data(buffer: data)
            }

            let (_, prefixBytes) = try Varint.decode(bytes)
            let protobufData = bytes.dropFirst(prefixBytes)
            let info = try IdentifyProtobuf.decode(Data(protobufData))

            #expect(info.agentVersion != nil)
            #expect(info.protocolVersion != nil)
            #expect(info.publicKey != nil)

            print("[WS] Identify agent: \(info.agentVersion ?? "unknown")")
            print("[WS] Identify protocols: \(info.protocols)")

            try await stream.close()
            try await muxedConnection.close()
        }
    }

    // MARK: - Ping Tests

    @Test("Ping go-libp2p node via WebSocket", .timeLimit(.minutes(2)))
    func pingGoViaWS() async throws {
        try await withWSHarness { harness in
            let nodeInfo = harness.nodeInfo
            let keyPair = KeyPair.generateEd25519()
            let transport = WebSocketTransport()
            let address = try Multiaddr(nodeInfo.address)
            let rawConnection = try await transport.dial(address)

            let securityNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { Data(buffer: try await rawConnection.read()) },
                write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
            )
            #expect(securityNegotiation.protocolID == "/noise")

            let noiseUpgrader = NoiseUpgrader()
            let securedConnection = try await noiseUpgrader.secure(
                rawConnection,
                localKeyPair: keyPair,
                as: .initiator,
                expectedPeer: nil,
                initialBuffer: ByteBuffer(bytes: securityNegotiation.remainder)
            )

            let muxNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/yamux/1.0.0"],
                read: { Data(buffer: try await securedConnection.read()) },
                write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
            )
            #expect(muxNegotiation.protocolID == "/yamux/1.0.0")

            let yamuxMuxer = YamuxMuxer()
            let muxedConnection = try await yamuxMuxer.multiplex(
                securedConnection,
                isInitiator: true
            )

            let stream = try await muxedConnection.newStream()

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

            #expect(Data(buffer: response) == payload, "Ping response should match sent payload")
            #expect(rtt < .seconds(5), "RTT should be reasonable")

            print("[WS] Ping RTT: \(rtt)")

            try await stream.close()
            try await muxedConnection.close()
        }
    }
}
