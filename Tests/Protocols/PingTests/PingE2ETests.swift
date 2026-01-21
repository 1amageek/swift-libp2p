/// PingE2ETests - End-to-end tests for Ping protocol over QUIC
///
/// Tests the Ping protocol with actual QUIC network connections.
/// Ping protocol uses 32-byte random payloads that are echoed back.

import Testing
import Foundation
@testable import P2PTransportQUIC
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
import QUIC

/// Ping payload size per libp2p spec
private let pingPayloadSize = 32

@Suite("Ping E2E Tests")
struct PingE2ETests {

    // MARK: - Basic Ping Tests

    @Test("Ping echo over QUIC", .timeLimit(.minutes(1)))
    func pingEcho() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // Start server
        let listener = try await transport.listenSecured(
            "/ip4/127.0.0.1/udp/0/quic-v1",
            localKeyPair: serverKeyPair
        )

        // Server task: accept stream and echo back data
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConn in listener.connections {
                // Accept stream from client
                let stream = try await serverConn.acceptStream()

                // Read data
                let data = try await stream.read()

                // Echo back if correct size
                if data.count == pingPayloadSize {
                    try await stream.write(data)
                }

                try await stream.closeWrite()

                return serverConn
            }
            return nil
        }

        // Client: connect and send ping
        let clientConn = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        // Generate random ping payload
        let payload = Data((0..<pingPayloadSize).map { _ in UInt8.random(in: 0...255) })

        // Open stream and send ping
        let stream = try await clientConn.newStream()
        let startTime = ContinuousClock.now

        try await stream.write(payload)
        try await stream.closeWrite()

        // Read response
        let response = try await stream.read()

        let endTime = ContinuousClock.now
        let rtt = endTime - startTime

        // Verify response matches payload
        #expect(response == payload)
        #expect(rtt < .seconds(1), "RTT should be less than 1 second for localhost")

        // Cleanup
        let serverConn = try? await serverTask.value
        try await stream.close()
        try await clientConn.close()
        try? await serverConn?.close()
        try await listener.close()
    }

    @Test("Ping measures RTT correctly", .timeLimit(.minutes(1)))
    func pingRTT() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            "/ip4/127.0.0.1/udp/0/quic-v1",
            localKeyPair: serverKeyPair
        )

        // Server: echo with artificial delay
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConn in listener.connections {
                let stream = try await serverConn.acceptStream()

                let data = try await stream.read()

                if data.count == pingPayloadSize {
                    // Add small delay to make RTT measurable
                    try await Task.sleep(for: .milliseconds(10))
                    try await stream.write(data)
                }

                try await stream.closeWrite()

                return serverConn
            }
            return nil
        }

        let clientConn = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        let payload = Data((0..<pingPayloadSize).map { _ in UInt8.random(in: 0...255) })

        let stream = try await clientConn.newStream()
        let startTime = ContinuousClock.now

        try await stream.write(payload)
        try await stream.closeWrite()

        let response = try await stream.read()

        let rtt = ContinuousClock.now - startTime

        // RTT should be at least 10ms due to server delay
        #expect(rtt >= .milliseconds(10))
        #expect(rtt < .seconds(1))
        #expect(response == payload)

        // Cleanup
        let serverConn = try? await serverTask.value
        try await stream.close()
        try await clientConn.close()
        try? await serverConn?.close()
        try await listener.close()
    }

    @Test("Multiple sequential pings", .timeLimit(.minutes(1)))
    func multipleSequentialPings() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            "/ip4/127.0.0.1/udp/0/quic-v1",
            localKeyPair: serverKeyPair
        )

        let pingCount = 5

        // Server: handle multiple streams
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConn in listener.connections {
                // Accept and echo multiple streams
                for _ in 0..<pingCount {
                    let stream = try await serverConn.acceptStream()
                    let data = try await stream.read()
                    try await stream.write(data)
                    try await stream.closeWrite()
                }
                return serverConn
            }
            return nil
        }

        let clientConn = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        var rtts: [Duration] = []

        for _ in 0..<pingCount {
            let payload = Data((0..<pingPayloadSize).map { _ in UInt8.random(in: 0...255) })

            // Open a new stream for each ping
            let stream = try await clientConn.newStream()
            let startTime = ContinuousClock.now

            try await stream.write(payload)
            try await stream.closeWrite()

            let response = try await stream.read()

            let rtt = ContinuousClock.now - startTime
            rtts.append(rtt)

            #expect(response == payload)

            try await stream.close()
        }

        // Verify we got all pings
        #expect(rtts.count == pingCount)

        // Calculate stats
        let totalNanos = rtts.reduce(0) { $0 + $1.components.attoseconds / 1_000_000_000 }
        let avgNanos = totalNanos / Int64(pingCount)
        let avgRTT = Duration.nanoseconds(avgNanos)

        #expect(avgRTT < .seconds(1))

        // Cleanup
        let serverConn = try? await serverTask.value
        try await clientConn.close()
        try? await serverConn?.close()
        try await listener.close()
    }

    @Test("Ping with exact 32-byte payload", .timeLimit(.minutes(1)))
    func pingExact32Bytes() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            "/ip4/127.0.0.1/udp/0/quic-v1",
            localKeyPair: serverKeyPair
        )

        // Server: only echo exactly 32-byte payloads
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConn in listener.connections {
                let stream = try await serverConn.acceptStream()
                let data = try await stream.read()

                // Only echo if exactly 32 bytes
                if data.count == 32 {
                    try await stream.write(data)
                }

                try await stream.closeWrite()

                return serverConn
            }
            return nil
        }

        let clientConn = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        // Test with exactly 32 bytes
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        #expect(payload.count == 32)

        let stream = try await clientConn.newStream()
        try await stream.write(payload)
        try await stream.closeWrite()

        let response = try await stream.read()

        #expect(response == payload)

        // Cleanup
        let serverConn = try? await serverTask.value
        try await stream.close()
        try await clientConn.close()
        try? await serverConn?.close()
        try await listener.close()
    }

    @Test("Ping payload mismatch detection", .timeLimit(.minutes(1)))
    func pingPayloadMismatch() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            "/ip4/127.0.0.1/udp/0/quic-v1",
            localKeyPair: serverKeyPair
        )

        // Server: return corrupted data (simulates bad echo)
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConn in listener.connections {
                let stream = try await serverConn.acceptStream()
                let data = try await stream.read()

                if data.count == pingPayloadSize {
                    // Corrupt the response
                    var corrupted = data
                    corrupted[0] = ~corrupted[0]
                    try await stream.write(corrupted)
                }

                try await stream.closeWrite()

                return serverConn
            }
            return nil
        }

        let clientConn = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        let payload = Data((0..<pingPayloadSize).map { _ in UInt8.random(in: 0...255) })

        let stream = try await clientConn.newStream()
        try await stream.write(payload)
        try await stream.closeWrite()

        let response = try await stream.read()

        // Response should NOT match (simulating error detection)
        #expect(response != payload)

        // Cleanup
        let serverConn = try? await serverTask.value
        try await stream.close()
        try await clientConn.close()
        try? await serverConn?.close()
        try await listener.close()
    }
}
