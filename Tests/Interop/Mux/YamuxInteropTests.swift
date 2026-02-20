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
@Suite("Yamux Mux Interop Tests", .serialized)
struct YamuxInteropTests {

    // MARK: - Helper

    private struct EstablishedYamuxSession {
        let connection: any MuxedConnection
        let harness: GoTCPHarness
        let transport: TCPTransport
    }

    private enum TestTimeoutError: Error {
        case operationTimedOut(String)
    }

    private let ioTimeoutSeconds: UInt64 = 10
    private let echoProtocolID = "/test/echo/1.0.0"

    private func withTimeout<T: Sendable>(
        seconds timeoutSeconds: UInt64,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await body()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw TestTimeoutError.operationTimedOut(operation)
            }

            guard let result = try await group.next() else {
                throw TestTimeoutError.operationTimedOut(operation)
            }
            group.cancelAll()
            return result
        }
    }

    private func establishConnection() async throws -> EstablishedYamuxSession {
        let harness = try await GoTCPHarness.start()

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

        return EstablishedYamuxSession(connection: muxedConnection, harness: harness, transport: transport)
    }

    private func openStream(
        on connection: any MuxedConnection,
        operation: String
    ) async throws -> any MuxedStream {
        try await withTimeout(seconds: ioTimeoutSeconds, operation: operation) {
            try await connection.newStream()
        }
    }

    private func negotiateProtocol(
        _ protocolID: String,
        on stream: any MuxedStream,
        operation: String
    ) async throws {
        let negotiationResult = try await withTimeout(seconds: ioTimeoutSeconds, operation: operation) {
            try await MultistreamSelect.negotiate(
                protocols: [protocolID],
                read: { Data(buffer: try await stream.read()) },
                write: { data in try await stream.write(ByteBuffer(bytes: data)) }
            )
        }
        #expect(negotiationResult.protocolID == protocolID)
    }

    private func writePayload(
        _ payload: Data,
        to stream: any MuxedStream,
        operation: String
    ) async throws {
        try await withTimeout(seconds: ioTimeoutSeconds, operation: operation) {
            try await stream.write(ByteBuffer(bytes: payload))
        }
    }

    private func readBuffer(
        from stream: any MuxedStream,
        operation: String
    ) async throws -> ByteBuffer {
        try await withTimeout(seconds: ioTimeoutSeconds, operation: operation) {
            try await stream.read()
        }
    }

    private func closeStream(
        _ stream: any MuxedStream,
        operation: String
    ) async throws {
        try await withTimeout(seconds: ioTimeoutSeconds, operation: operation) {
            try await stream.close()
        }
    }

    // MARK: - Stream Multiplex Tests

    @Test("Yamux stream multiplexing", .timeLimit(.minutes(2)))
    func yamuxStreamMultiplex() async throws {
        let session = try await establishConnection()
        let connection = session.connection
        let harness = session.harness
        defer { Task { do { try await harness.stop() } catch { } } }
        _ = session.transport

        // Open and verify multiple streams in sequence.
        // Opening all streams first can leave protocol negotiation pending too long
        // and trigger remote-side stream resets.
        let streamCount = 4
        var streams: [any MuxedStream] = []

        do {
            for index in 0..<streamCount {
                let stream = try await openStream(on: connection, operation: "open stream \(index)")
                streams.append(stream)
                print("[Yamux] Stream \(index) opened: ID=\(stream.id)")

                try await negotiateProtocol(
                    echoProtocolID,
                    on: stream,
                    operation: "echo negotiation stream \(index)"
                )

                let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                try await writePayload(payload, to: stream, operation: "echo write stream \(index)")

                let response = try await readBuffer(from: stream, operation: "echo response stream \(index)")
                #expect(Data(buffer: response) == payload, "Stream \(index) response should match")
                try await closeStream(stream, operation: "close stream \(index)")
                print("[Yamux] Stream \(index) echo verified")
            }
            #expect(streams.count == streamCount)
        } catch {
            let harnessLogs = await harness.logs()
            print("[Yamux] Harness logs before failure:\n\(harnessLogs)")
            throw error
        }

        try await connection.close()
    }

    @Test("Yamux concurrent streams", .timeLimit(.minutes(2)))
    func yamuxConcurrentStreams() async throws {
        let session = try await establishConnection()
        let connection = session.connection
        let harness = session.harness
        defer { Task { do { try await harness.stop() } catch { } } }
        _ = session.transport

        // Open and use streams concurrently
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<3 {
                group.addTask {
                    do {
                        let stream = try await openStream(on: connection, operation: "open concurrent stream \(i)")
                        try await negotiateProtocol(
                            echoProtocolID,
                            on: stream,
                            operation: "concurrent echo negotiation stream \(i)"
                        )

                        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
                        try await writePayload(payload, to: stream, operation: "concurrent echo write stream \(i)")
                        let response = try await readBuffer(from: stream, operation: "concurrent echo response stream \(i)")
                        try await closeStream(stream, operation: "close concurrent stream \(i)")

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
        let session = try await establishConnection()
        let connection = session.connection
        let harness = session.harness
        defer { Task { do { try await harness.stop() } catch { } } }
        _ = session.transport

        // Open and close streams in sequence
        for i in 0..<3 {
            let stream = try await openStream(on: connection, operation: "open stream close test \(i)")
            print("[Yamux] Stream \(i) opened: ID=\(stream.id)")

            try await negotiateProtocol(
                echoProtocolID,
                on: stream,
                operation: "stream close echo negotiation \(i)"
            )

            // Send and receive
            let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try await writePayload(payload, to: stream, operation: "stream close echo write \(i)")
            let response = try await readBuffer(from: stream, operation: "stream close echo response \(i)")
            #expect(Data(buffer: response) == payload)

            // Close stream
            try await closeStream(stream, operation: "stream close operation \(i)")
            print("[Yamux] Stream \(i) closed")
        }

        try await connection.close()
    }

    @Test("Yamux half-close", .timeLimit(.minutes(2)))
    func yamuxHalfClose() async throws {
        let session = try await establishConnection()
        let connection = session.connection
        let harness = session.harness
        defer { Task { do { try await harness.stop() } catch { } } }
        _ = session.transport

        let stream = try await openStream(on: connection, operation: "open half-close stream")

        // Negotiate echo protocol to keep protocol behavior deterministic.
        try await negotiateProtocol(
            echoProtocolID,
            on: stream,
            operation: "half-close echo negotiation"
        )

        // Send data
        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await writePayload(payload, to: stream, operation: "half-close echo write")

        // Read response
        let response = try await readBuffer(from: stream, operation: "half-close echo response")
        #expect(Data(buffer: response) == payload)

        // Close write side only
        try await withTimeout(seconds: ioTimeoutSeconds, operation: "half-close write side") {
            try await stream.closeWrite()
        }
        print("[Yamux] Write side closed")

        // Stream should still be usable for reading until fully closed
        try await closeStream(stream, operation: "half-close final close")
        print("[Yamux] Half-close test completed")

        try await connection.close()
    }

    // MARK: - Large Data Transfer Tests

    @Test("Yamux large payload transfer", .timeLimit(.minutes(3)))
    func yamuxLargePayload() async throws {
        let session = try await establishConnection()
        let connection = session.connection
        let harness = session.harness
        defer { Task { do { try await harness.stop() } catch { } } }
        _ = session.transport

        let stream = try await openStream(on: connection, operation: "open large payload stream")
        try await negotiateProtocol(
            echoProtocolID,
            on: stream,
            operation: "large payload negotiation"
        )

        // Send larger payload (4KB)
        let payload = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        try await writePayload(payload, to: stream, operation: "large payload write")

        // Read response (may come in multiple chunks)
        var responseData = Data()
        while responseData.count < payload.count {
            let chunk = try await readBuffer(from: stream, operation: "large payload chunk read")
            responseData.append(Data(buffer: chunk))
            print("[Yamux] Received \(responseData.count)/\(payload.count) bytes")
        }

        #expect(responseData == payload, "Large payload should match")
        print("[Yamux] Large payload transfer verified: \(payload.count) bytes")

        try await closeStream(stream, operation: "close large payload stream")
        try await connection.close()
    }
}
