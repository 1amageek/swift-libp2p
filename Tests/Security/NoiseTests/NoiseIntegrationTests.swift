/// NoiseIntegrationTests - Integration tests for NoiseUpgrader and NoiseConnection
import Testing
import Foundation
import NIOCore
import Crypto
import Synchronization
@testable import P2PSecurityNoise
@testable import P2PSecurity
@testable import P2PCore
@testable import P2PTransport

@Suite("Noise Integration Tests", .serialized)
struct NoiseIntegrationTests {

    // MARK: - NoiseUpgrader Tests

    @Test("NoiseUpgrader completes handshake between initiator and responder", .timeLimit(.minutes(1)))
    func testNoiseUpgraderHandshake() async throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let (clientConn, serverConn) = MockPipe.create()

        let upgrader = NoiseUpgrader()

        // Run handshake concurrently
        async let initiatorResult = upgrader.secure(
            clientConn,
            localKeyPair: initiatorKeyPair,
            as: .initiator,
            expectedPeer: nil
        )

        async let responderResult = upgrader.secure(
            serverConn,
            localKeyPair: responderKeyPair,
            as: .responder,
            expectedPeer: nil
        )

        let (initiatorSecured, responderSecured) = try await (initiatorResult, responderResult)

        // Verify peer IDs
        #expect(initiatorSecured.localPeer == initiatorKeyPair.peerID)
        #expect(initiatorSecured.remotePeer == responderKeyPair.peerID)
        #expect(responderSecured.localPeer == responderKeyPair.peerID)
        #expect(responderSecured.remotePeer == initiatorKeyPair.peerID)

        try await initiatorSecured.close()
        try await responderSecured.close()
    }

    @Test("NoiseUpgrader protocol ID is /noise")
    func testNoiseUpgraderProtocolID() {
        let upgrader = NoiseUpgrader()
        #expect(upgrader.protocolID == "/noise")
    }

    // MARK: - NoiseConnection Tests

    @Test("NoiseConnection read and write roundtrip", .timeLimit(.minutes(1)))
    func testNoiseConnectionReadWrite() async throws {
        let (initiator, responder) = try await createSecuredPair()

        let testData = Data("Hello, Noise Connection!".utf8)

        try await initiator.write(ByteBuffer(bytes: testData))
        let received = try await responder.read()

        #expect(Data(buffer: received) == testData)

        try await initiator.close()
        try await responder.close()
    }

    @Test("NoiseConnection handles multiple messages", .timeLimit(.minutes(1)))
    func testNoiseConnectionMultipleMessages() async throws {
        let (initiator, responder) = try await createSecuredPair()

        let messages = [
            Data("First message".utf8),
            Data("Second message".utf8),
            Data("Third message".utf8),
        ]

        for msg in messages {
            try await initiator.write(ByteBuffer(bytes: msg))
        }

        for expected in messages {
            let received = try await responder.read()
            #expect(Data(buffer: received) == expected)
        }

        try await initiator.close()
        try await responder.close()
    }

    @Test("NoiseConnection bidirectional communication", .timeLimit(.minutes(1)))
    func testNoiseConnectionBidirectional() async throws {
        let (initiator, responder) = try await createSecuredPair()

        // Initiator sends
        let msg1 = Data("From initiator".utf8)
        try await initiator.write(ByteBuffer(bytes: msg1))
        let recv1 = try await responder.read()
        #expect(Data(buffer: recv1) == msg1)

        // Responder sends
        let msg2 = Data("From responder".utf8)
        try await responder.write(ByteBuffer(bytes: msg2))
        let recv2 = try await initiator.read()
        #expect(Data(buffer: recv2) == msg2)

        // Alternate
        let msg3 = Data("Another from initiator".utf8)
        try await initiator.write(ByteBuffer(bytes: msg3))
        let recv3 = try await responder.read()
        #expect(Data(buffer: recv3) == msg3)

        try await initiator.close()
        try await responder.close()
    }

    @Test("NoiseConnection supports concurrent full-duplex exchange", .timeLimit(.minutes(1)))
    func testNoiseConnectionConcurrentFullDuplex() async throws {
        let (initiator, responder) = try await createSecuredPair()

        let initiatorMessage = Data("initiator-concurrent".utf8)
        let responderMessage = Data("responder-concurrent".utf8)

        async let initiatorTask: Void = {
            try await initiator.write(ByteBuffer(bytes: initiatorMessage))
            let received = try await initiator.read()
            #expect(Data(buffer: received) == responderMessage)
        }()

        async let responderTask: Void = {
            try await responder.write(ByteBuffer(bytes: responderMessage))
            let received = try await responder.read()
            #expect(Data(buffer: received) == initiatorMessage)
        }()

        _ = try await (initiatorTask, responderTask)

        try await initiator.close()
        try await responder.close()
    }

    @Test("NoiseConnection handles large data spanning multiple frames", .timeLimit(.minutes(1)))
    func testNoiseConnectionLargeData() async throws {
        let (initiator, responder) = try await createSecuredPair()

        // Create data larger than max frame size
        let largeData = Data((0..<100000).map { UInt8($0 % 256) })

        try await initiator.write(ByteBuffer(bytes: largeData))

        // Read may return data in chunks, so we need to accumulate
        var received = Data()
        while received.count < largeData.count {
            let chunk = try await responder.read()
            received.append(Data(buffer: chunk))
        }

        #expect(received == largeData)

        try await initiator.close()
        try await responder.close()
    }

    @Test("NoiseConnection handles empty data", .timeLimit(.minutes(1)))
    func testNoiseConnectionEmptyData() async throws {
        let (initiator, responder) = try await createSecuredPair()

        // Writing empty data should work
        try await initiator.write(ByteBuffer())
        let received = try await responder.read()
        #expect(received.readableBytes == 0)

        try await initiator.close()
        try await responder.close()
    }

    // MARK: - Expected Peer Tests

    @Test("NoiseUpgrader succeeds when expected peer matches", .timeLimit(.minutes(1)))
    func testExpectedPeerMatch() async throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let (clientConn, serverConn) = MockPipe.create()

        let upgrader = NoiseUpgrader()

        // Initiator expects specific responder
        async let initiatorResult = upgrader.secure(
            clientConn,
            localKeyPair: initiatorKeyPair,
            as: .initiator,
            expectedPeer: responderKeyPair.peerID
        )

        async let responderResult = upgrader.secure(
            serverConn,
            localKeyPair: responderKeyPair,
            as: .responder,
            expectedPeer: initiatorKeyPair.peerID
        )

        let (initiatorSecured, responderSecured) = try await (initiatorResult, responderResult)

        #expect(initiatorSecured.remotePeer == responderKeyPair.peerID)
        #expect(responderSecured.remotePeer == initiatorKeyPair.peerID)

        try await initiatorSecured.close()
        try await responderSecured.close()
    }

    @Test("NoiseUpgrader fails when initiator's expected peer doesn't match", .timeLimit(.minutes(1)))
    func testExpectedPeerMismatchInitiator() async throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()
        let wrongPeerKeyPair = KeyPair.generateEd25519()

        let (clientConn, serverConn) = MockPipe.create()

        let upgrader = NoiseUpgrader()

        // Initiator expects wrong peer
        async let initiatorResult: Void = {
            do {
                _ = try await upgrader.secure(
                    clientConn,
                    localKeyPair: initiatorKeyPair,
                    as: .initiator,
                    expectedPeer: wrongPeerKeyPair.peerID
                )
                Issue.record("Expected peer mismatch error")
            } catch {
                // Expected - close connection to unblock responder
                do {
                    try await clientConn.close()
                } catch {
                    // Best-effort cleanup for expected failure path.
                }
            }
        }()

        async let responderResult: Void = {
            do {
                _ = try await upgrader.secure(
                    serverConn,
                    localKeyPair: responderKeyPair,
                    as: .responder,
                    expectedPeer: nil
                )
            } catch {
                // May fail due to connection close - expected
            }
        }()

        await initiatorResult
        await responderResult
    }

    // MARK: - Helper Methods

    /// Creates a secured connection pair for testing.
    private func createSecuredPair() async throws -> (any SecuredConnection, any SecuredConnection) {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let (clientConn, serverConn) = MockPipe.create()

        let upgrader = NoiseUpgrader()

        async let initiatorResult = upgrader.secure(
            clientConn,
            localKeyPair: initiatorKeyPair,
            as: .initiator,
            expectedPeer: nil
        )

        async let responderResult = upgrader.secure(
            serverConn,
            localKeyPair: responderKeyPair,
            as: .responder,
            expectedPeer: nil
        )

        return try await (initiatorResult, responderResult)
    }
}

// MARK: - Mock Implementations

/// A mock raw connection for testing.
/// Uses direct peer reference instead of closures for simplicity and thread safety.
final class MockRawConnection: RawConnection, Sendable {
    let localAddress: Multiaddr? = nil
    let remoteAddress: Multiaddr

    private let state: Mutex<ConnectionState>
    private let peerRef: Mutex<MockRawConnection?>

    private struct ConnectionState: Sendable {
        var buffer: [ByteBuffer] = []
        var isClosed = false
        var waitingContinuation: CheckedContinuation<ByteBuffer, any Error>?
    }

    init(remoteAddress: Multiaddr) {
        self.remoteAddress = remoteAddress
        self.state = Mutex(ConnectionState())
        self.peerRef = Mutex(nil)
    }

    /// Links this connection to its peer. Must be called after both connections are created.
    func link(to peer: MockRawConnection) {
        peerRef.withLock { $0 = peer }
    }

    /// Receives data from the peer connection.
    func receive(_ data: ByteBuffer) {
        state.withLock { state in
            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(returning: data)
            } else {
                state.buffer.append(data)
            }
        }
    }

    func read() async throws -> ByteBuffer {
        // Check buffer first
        let buffered: ByteBuffer? = state.withLock { state in
            if !state.buffer.isEmpty {
                return state.buffer.removeFirst()
            }
            return nil
        }

        if let data = buffered {
            return data
        }

        // Wait for data
        return try await withCheckedThrowingContinuation { continuation in
            let shouldThrow = state.withLock { state -> Bool in
                if state.isClosed {
                    return true
                }
                if !state.buffer.isEmpty {
                    continuation.resume(returning: state.buffer.removeFirst())
                    return false
                }
                state.waitingContinuation = continuation
                return false
            }

            if shouldThrow {
                continuation.resume(throwing: MockConnectionError.connectionClosed)
            }
        }
    }

    func write(_ data: ByteBuffer) async throws {
        let isClosed = state.withLock { $0.isClosed }
        guard !isClosed else {
            throw MockConnectionError.connectionClosed
        }

        let peer = peerRef.withLock { $0 }
        peer?.receive(data)
    }

    func close() async throws {
        state.withLock { state in
            state.isClosed = true
            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(throwing: MockConnectionError.connectionClosed)
            }
        }
        // Notify peer that this connection is closed
        // This will unblock any read() waiting on the peer side
        let peer = peerRef.withLock { $0 }
        peer?.receiveClose()
    }

    /// Called when peer connection is closed.
    private func receiveClose() {
        state.withLock { state in
            state.isClosed = true
            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(throwing: MockConnectionError.connectionClosed)
            }
        }
    }
}

/// Creates a pair of connected mock raw connections.
enum MockPipe {
    static func create() -> (client: MockRawConnection, server: MockRawConnection) {
        let clientAddress = Multiaddr.tcp(host: "127.0.0.1", port: 1234)
        let serverAddress = Multiaddr.tcp(host: "127.0.0.1", port: 5678)

        let client = MockRawConnection(remoteAddress: serverAddress)
        let server = MockRawConnection(remoteAddress: clientAddress)

        // Link connections bidirectionally
        client.link(to: server)
        server.link(to: client)

        return (client, server)
    }
}

enum MockConnectionError: Error {
    case connectionClosed
}
