/// WSSInteropTests - WSS (Secure WebSocket) transport interoperability tests
///
/// Tests that swift-libp2p can communicate with go-libp2p nodes
/// over WSS (TLS + WebSocket) transport with Noise security.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter WSSInteropTests

import Testing
import Foundation
import NIOCore
import NIOSSL
@testable import P2PTransportWebSocket
@testable import P2PSecurityNoise
@testable import P2PMuxYamux
@testable import P2PMux
@testable import P2PTransport
@testable import P2PCore
@testable import P2PNegotiation
@testable import P2PProtocols
@testable import P2PIdentify

private enum WSSInteropError: Error {
    case missingCertificate
}

/// Interoperability tests for WSS transport with go-libp2p
@Suite("WSS Transport Interop Tests", .serialized)
struct WSSInteropTests {
    private func withWSSHarness<T: Sendable>(
        _ operation: @Sendable (GoWSSHarness) async throws -> T
    ) async throws -> T {
        var lastError: (any Error)?

        for attempt in 1...2 {
            let harness = try await GoWSSHarness.start()
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
                    print("[WSS] Retrying after transient interop failure: \(error)")
                    try await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        if let lastError {
            throw lastError
        }

        throw WSSInteropError.missingCertificate
    }

    private func makeWSSClientTransport(_ harness: GoWSSHarness) throws -> WebSocketTransport {
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(harness.serverCertificatePEM.utf8))
        guard !certificates.isEmpty else {
            throw WSSInteropError.missingCertificate
        }

        var clientTLS = TLSConfiguration.makeClientConfiguration()
        clientTLS.certificateVerification = .fullVerification
        clientTLS.trustRoots = .certificates(certificates)

        return WebSocketTransport(tlsConfiguration: .init(client: clientTLS))
    }

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p node via WSS", .timeLimit(.minutes(2)))
    func connectToGoViaWSS() async throws {
        try await withWSSHarness { harness in
            let nodeInfo = harness.nodeInfo
            print("[WSS] Node info: \(nodeInfo)")

            let keyPair = KeyPair.generateEd25519()
            let transport = try makeWSSClientTransport(harness)
            let address = try Multiaddr(nodeInfo.address)
            let rawConnection = try await transport.dial(address)

            print("[WSS] Raw connection established (TLS + WebSocket)")

            let securityNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { Data(buffer: try await rawConnection.read()) },
                write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
            )

            #expect(securityNegotiation.protocolID == "/noise")
            print("[WSS] Security protocol negotiated: \(securityNegotiation.protocolID)")

            let noiseUpgrader = NoiseUpgrader()
            let securedConnection = try await noiseUpgrader.secure(
                rawConnection,
                localKeyPair: keyPair,
                as: .initiator,
                expectedPeer: nil,
                initialBuffer: ByteBuffer(bytes: securityNegotiation.remainder)
            )

            print("[WSS] Noise handshake completed")
            print("[WSS] Remote peer: \(securedConnection.remotePeer)")

            #expect(securedConnection.remotePeer.description.contains(nodeInfo.peerID.prefix(8)))

            try await securedConnection.close()
        }
    }

    @Test("WSS connection with Yamux muxing", .timeLimit(.minutes(2)))
    func wssWithYamuxMuxing() async throws {
        try await withWSSHarness { harness in
            let nodeInfo = harness.nodeInfo
            let keyPair = KeyPair.generateEd25519()
            let transport = try makeWSSClientTransport(harness)
            let address = try Multiaddr(nodeInfo.address)
            let rawConnection = try await transport.dial(address)

            let securityNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { Data(buffer: try await rawConnection.read()) },
                write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
            )
            #expect(securityNegotiation.protocolID == "/noise")
            print("[WSS+Yamux] Security negotiated: /noise")

            let noiseUpgrader = NoiseUpgrader()
            let securedConnection = try await noiseUpgrader.secure(
                rawConnection,
                localKeyPair: keyPair,
                as: .initiator,
                expectedPeer: nil,
                initialBuffer: ByteBuffer(bytes: securityNegotiation.remainder)
            )
            print("[WSS+Yamux] Noise handshake completed")

            let muxNegotiation = try await MultistreamSelect.negotiate(
                protocols: ["/yamux/1.0.0"],
                read: { Data(buffer: try await securedConnection.read()) },
                write: { data in try await securedConnection.write(ByteBuffer(bytes: data)) }
            )
            #expect(muxNegotiation.protocolID == "/yamux/1.0.0")
            print("[WSS+Yamux] Mux negotiated: /yamux/1.0.0")

            let yamuxMuxer = YamuxMuxer()
            let muxedConnection = try await yamuxMuxer.multiplex(
                securedConnection,
                isInitiator: true
            )

            print("[WSS+Yamux] Muxed connection established")

            let stream = try await muxedConnection.newStream()
            print("[WSS+Yamux] Stream opened: \(stream.id)")

            try await stream.close()
            try await muxedConnection.close()
        }
    }

    // MARK: - Identify Tests

    @Test("Identify go-libp2p node via WSS", .timeLimit(.minutes(2)))
    func identifyGoViaWSS() async throws {
        try await withWSSHarness { harness in
            let nodeInfo = harness.nodeInfo
            let keyPair = KeyPair.generateEd25519()
            let transport = try makeWSSClientTransport(harness)
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

            print("[WSS] Identify agent: \(info.agentVersion ?? "unknown")")
            print("[WSS] Identify protocols: \(info.protocols)")

            try await stream.close()
            try await muxedConnection.close()
        }
    }

    // MARK: - Ping Tests

    @Test("Ping go-libp2p node via WSS", .timeLimit(.minutes(2)))
    func pingGoViaWSS() async throws {
        try await withWSSHarness { harness in
            let nodeInfo = harness.nodeInfo
            let keyPair = KeyPair.generateEd25519()
            let transport = try makeWSSClientTransport(harness)
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

            print("[WSS] Ping RTT: \(rtt)")

            try await stream.close()
            try await muxedConnection.close()
        }
    }
}
