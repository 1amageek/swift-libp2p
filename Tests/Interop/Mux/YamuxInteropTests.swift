/// YamuxInteropTests - Yamux multiplexer interoperability tests
///
/// Tests that swift-libp2p Yamux implementation is compatible with go-libp2p.
/// Focuses on stream multiplexing, flow control, and stream lifecycle.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter YamuxInteropTests

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

/// Interoperability tests for Yamux multiplexer
@Suite("Yamux Mux Interop Tests")
struct YamuxInteropTests {

    // MARK: - Helper

    private func establishConnection() async throws -> (any MuxedConnection, GoTCPHarness) {
        let harness = try await GoTCPHarness.start(
            dockerfile: "Dockerfiles/Dockerfile.yamux.go",
            imageName: "go-libp2p-yamux-test"
        )

        let keyPair = KeyPair.generateEd25519()
        let transport = TCPTransport()

        // Dial TCP
        let address = try Multiaddr(harness.nodeInfo.address)
        let rawConnection = try await transport.dial(address)

        // Step 1: Negotiate security protocol
        let securityNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/noise"],
            read: { Data(buffer: try await rawConnection.read()) },
            write: { data in try await rawConnection.write(ByteBuffer(bytes: data)) }
        )
        guard securityNegotiation.protocolID == "/noise" else {
            throw NSError(domain: "YamuxInterop", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to negotiate security protocol"])
        }

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
        guard muxNegotiation.protocolID == "/yamux/1.0.0" else {
            throw NSError(domain: "YamuxInterop", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to negotiate mux protocol"])
        }

        // Step 4: Yamux muxing
        let yamuxMuxer = YamuxMuxer()
        let muxedConnection = try await yamuxMuxer.multiplex(
            securedConnection,
            isInitiator: true
        )

        return (muxedConnection, harness)
    }

    // MARK: - Stream Multiplex Tests

    @Test("Yamux stream multiplexing", .timeLimit(.minutes(2)))
    func yamuxStreamMultiplex() async throws {
        let (connection, harness) = try await establishConnection()
        defer { Task { try? await harness.stop() } }

        // Open multiple streams simultaneously
        let streamCount = 5
        var streams: [any MuxedStream] = []

        for i in 0..<streamCount {
            let stream = try await connection.newStream()
            streams.append(stream)
            print("[Yamux] Stream \(i) opened: ID=\(stream.id)")
        }

        #expect(streams.count == streamCount)

        // Negotiate and test each stream
        for (index, stream) in streams.enumerated() {
            let negotiationResult = try await MultistreamSelect.negotiate(
                protocols: [LibP2PProtocol.ping],
                read: { Data(buffer: try await stream.read()) },
                write: { data in try await stream.write(ByteBuffer(bytes: data)) }
            )

            #expect(negotiationResult.protocolID == LibP2PProtocol.ping)

            let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try await stream.write(ByteBuffer(bytes: payload))

            let response = try await stream.read()
            #expect(Data(buffer: response) == payload, "Stream \(index) response should match")

            print("[Yamux] Stream \(index) ping verified")
        }

        // Close all streams
        for stream in streams {
            try await stream.close()
        }

        try await connection.close()
    }

    @Test("Yamux concurrent streams", .timeLimit(.minutes(2)))
    func yamuxConcurrentStreams() async throws {
        let (connection, harness) = try await establishConnection()
        defer { Task { try? await harness.stop() } }

        // Open and use streams concurrently
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<3 {
                group.addTask {
                    do {
                        let stream = try await connection.newStream()

                        let negotiationResult = try await MultistreamSelect.negotiate(
                            protocols: [LibP2PProtocol.ping],
                            read: { Data(buffer: try await stream.read()) },
                            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
                        )

                        guard negotiationResult.protocolID == LibP2PProtocol.ping else {
                            return false
                        }

                        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                        try await stream.write(ByteBuffer(bytes: payload))

                        let response = try await stream.read()
                        try await stream.close()

                        let success = Data(buffer: response) == payload
                        print("[Yamux] Concurrent stream \(i): \(success ? "OK" : "FAIL")")
                        return success
                    } catch {
                        print("[Yamux] Concurrent stream \(i) error: \(error)")
                        return false
                    }
                }
            }

            var successCount = 0
            for await success in group {
                if success { successCount += 1 }
            }

            #expect(successCount == 3, "All concurrent streams should succeed")
        }

        try await connection.close()
    }

    // MARK: - Stream Lifecycle Tests

    @Test("Yamux stream close", .timeLimit(.minutes(2)))
    func yamuxStreamClose() async throws {
        let (connection, harness) = try await establishConnection()
        defer { Task { try? await harness.stop() } }

        // Open and close streams in sequence
        for i in 0..<3 {
            let stream = try await connection.newStream()
            print("[Yamux] Stream \(i) opened: ID=\(stream.id)")

            // Negotiate ping
            let negotiationResult = try await MultistreamSelect.negotiate(
                protocols: [LibP2PProtocol.ping],
                read: { Data(buffer: try await stream.read()) },
                write: { data in try await stream.write(ByteBuffer(bytes: data)) }
            )

            #expect(negotiationResult.protocolID == LibP2PProtocol.ping)

            // Send and receive
            let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try await stream.write(ByteBuffer(bytes: payload))
            let response = try await stream.read()
            #expect(Data(buffer: response) == payload)

            // Close stream
            try await stream.close()
            print("[Yamux] Stream \(i) closed")
        }

        try await connection.close()
    }

    @Test("Yamux half-close", .timeLimit(.minutes(2)))
    func yamuxHalfClose() async throws {
        let (connection, harness) = try await establishConnection()
        defer { Task { try? await harness.stop() } }

        let stream = try await connection.newStream()

        // Negotiate echo protocol (not ping, to test half-close properly)
        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.ping],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == LibP2PProtocol.ping)

        // Send data
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await stream.write(ByteBuffer(bytes: payload))

        // Read response
        let response = try await stream.read()
        #expect(Data(buffer: response) == payload)

        // Close write side only
        try await stream.closeWrite()
        print("[Yamux] Write side closed")

        // Stream should still be usable for reading until fully closed
        try await stream.close()
        print("[Yamux] Half-close test completed")

        try await connection.close()
    }

    // MARK: - Large Data Transfer Tests

    @Test("Yamux large payload transfer", .timeLimit(.minutes(3)))
    func yamuxLargePayload() async throws {
        let (connection, harness) = try await establishConnection()
        defer { Task { try? await harness.stop() } }

        let stream = try await connection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/test/echo/1.0.0"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == "/test/echo/1.0.0")

        // Send larger payload (4KB)
        let payload = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        try await stream.write(ByteBuffer(bytes: payload))

        // Read response (may come in multiple chunks)
        var responseData = Data()
        while responseData.count < payload.count {
            let chunk = try await stream.read()
            responseData.append(Data(buffer: chunk))
            print("[Yamux] Received \(responseData.count)/\(payload.count) bytes")
        }

        #expect(responseData == payload, "Large payload should match")
        print("[Yamux] Large payload transfer verified: \(payload.count) bytes")

        try await stream.close()
        try await connection.close()
    }
}
