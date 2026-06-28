/// End-to-end tests for WebRTC Direct transport.
///
/// These tests verify actual WebRTC Direct connections between client and server,
/// including DTLS handshake, PeerID verification, and stream multiplexing
/// over real UDP sockets on localhost.

import Testing
import Foundation
import NIOCore
@testable import P2PTransportWebRTC
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux

private enum WebRTCTestTimeout: Error {
    case step(String)
}

private actor WebRTCTestTimeoutGate<T: Sendable> {
    private let continuation: CheckedContinuation<T, Error>
    private var didResume = false

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(throwing: error)
    }
}

private func withWebRTCStepTimeout<T: Sendable>(
    _ step: String,
    timeout: Duration = .seconds(10),
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = WebRTCTestTimeoutGate<T>(continuation)
        let task = Task {
            try await operation()
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
                task.cancel()
                await gate.resume(throwing: WebRTCTestTimeout.step(step))
            } catch is CancellationError {
                // The operation completed before the timeout.
            } catch {
                await gate.resume(throwing: error)
            }
        }
        Task {
            do {
                let result = try await task.value
                timer.cancel()
                await gate.resume(returning: result)
            } catch {
                timer.cancel()
                await gate.resume(throwing: error)
            }
        }
    }
}

@Suite(
    "WebRTC E2E Tests",
    .serialized,
    .enabled(if: webRTCLiveNetworkTestsEnabled, "Set SWIFT_LIBP2P_ENABLE_LIVE_NETWORK_TESTS=1")
)
struct WebRTCE2ETests {

    // MARK: - Basic Connection Tests

    @Test("Client-server handshake succeeds", .timeLimit(.minutes(1)))
    func clientServerHandshake() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // Start server on random port
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        // Get the actual listening address (includes certhash)
        let serverAddress = listener.localAddress

        // Accept connection in background
        let acceptTask = Task { () -> (any MuxedConnection)? in
            for await connection in listener.connections {
                return connection
            }
            return nil
        }

        // Connect from client
        let clientConnection = try await transport.dialSecured(
            serverAddress,
            localKeyPair: clientKeyPair
        )

        // Wait for server to accept
        guard let serverConnection = await acceptTask.value else {
            Issue.record("Server did not receive connection")
            return
        }

        // Verify PeerIDs on client side
        #expect(clientConnection.localPeer == clientKeyPair.peerID)
        #expect(clientConnection.remotePeer == serverKeyPair.peerID)

        // Verify PeerIDs on server side
        #expect(serverConnection.localPeer == serverKeyPair.peerID)
        #expect(serverConnection.remotePeer == clientKeyPair.peerID)

        // Cleanup
        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()
    }

    @Test("Multiple clients can connect to same server", .timeLimit(.minutes(1)))
    func multipleClients() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let client1KeyPair = KeyPair.generateEd25519()
        let client2KeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // Start server
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )
        let serverAddress = listener.localAddress

        // Accept connections in background
        let acceptTask = Task { () -> [any MuxedConnection] in
            var connections: [any MuxedConnection] = []
            var count = 0
            for await conn in listener.connections {
                connections.append(conn)
                count += 1
                if count >= 2 { break }
            }
            return connections
        }

        // Connect both clients
        let client1Connection = try await transport.dialSecured(
            serverAddress,
            localKeyPair: client1KeyPair
        )
        let client2Connection = try await transport.dialSecured(
            serverAddress,
            localKeyPair: client2KeyPair
        )

        // Wait for server to accept both
        let serverConnections = await acceptTask.value

        // Verify we have 2 server connections
        #expect(serverConnections.count == 2)

        // Verify client PeerIDs are different
        #expect(client1Connection.localPeer != client2Connection.localPeer)

        // Cleanup
        try await client1Connection.close()
        try await client2Connection.close()
        for conn in serverConnections {
            try await conn.close()
        }
        try await listener.close()
    }

    // MARK: - Stream Tests

    @Test("Can open and use bidirectional stream", .timeLimit(.minutes(1)))
    func bidirectionalStream() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // Start server
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        // Accept and handle in background
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                // Accept stream from client
                let stream = try await withWebRTCStepTimeout("bidirectional server accept stream") {
                    try await serverConnection.acceptStream()
                }

                // Read data
                let received = try await withWebRTCStepTimeout("bidirectional server read") {
                    try await stream.read()
                }

                // Echo back with modification
                var echoBuffer = received
                echoBuffer.writeBytes(Data(" - echoed".utf8))
                let echoToSend = echoBuffer
                try await withWebRTCStepTimeout("bidirectional server write") {
                    try await stream.write(echoToSend)
                }

                // Close write side
                try await withWebRTCStepTimeout("bidirectional server close write") {
                    try await stream.closeWrite()
                }

                return serverConnection
            }
            return nil
        }

        // Client connects and sends data
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        // Open stream
        let clientStream = try await withWebRTCStepTimeout("bidirectional client new stream") {
            try await clientConnection.newStream()
        }

        // Send data
        let testData = Data("Hello WebRTC".utf8)
        try await withWebRTCStepTimeout("bidirectional client write") {
            try await clientStream.write(ByteBuffer(bytes: testData))
        }
        try await withWebRTCStepTimeout("bidirectional client close write") {
            try await clientStream.closeWrite()
        }

        // Read response
        let response = try await withWebRTCStepTimeout("bidirectional client read") {
            try await clientStream.read()
        }
        #expect(Data(buffer: response) == Data("Hello WebRTC - echoed".utf8))

        // Cleanup
        let serverConnection = try await withWebRTCStepTimeout("bidirectional server task completion", timeout: .seconds(10)) {
            try await serverTask.value
        }
        try await clientStream.close()
        try await clientConnection.close()
        if let unwrappedServerConnection = serverConnection {
            do { try await unwrappedServerConnection.close() } catch { }
        }
        try await listener.close()
    }

    @Test("Can open multiple streams on same connection", .timeLimit(.minutes(1)))
    func multipleStreams() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // Start server
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        // Server handles multiple streams
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                // Accept and echo 3 streams
                for index in 0..<3 {
                    let stream = try await withWebRTCStepTimeout("multiple server accept \(index)") {
                        try await serverConnection.acceptStream()
                    }
                    let data = try await withWebRTCStepTimeout("multiple server read \(index)") {
                        try await stream.read()
                    }
                    try await withWebRTCStepTimeout("multiple server write \(index)") {
                        try await stream.write(data)
                    }
                    try await stream.close()
                }
                return serverConnection
            }
            return nil
        }

        // Client
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        // Open 3 streams
        for i in 0..<3 {
            let stream = try await withWebRTCStepTimeout("multiple client new stream \(i)") {
                try await clientConnection.newStream()
            }
            let testData = Data("Stream \(i)".utf8)
            try await withWebRTCStepTimeout("multiple client write \(i)") {
                try await stream.write(ByteBuffer(bytes: testData))
            }
            try await withWebRTCStepTimeout("multiple client close write \(i)") {
                try await stream.closeWrite()
            }

            let response = try await withWebRTCStepTimeout("multiple client read \(i)") {
                try await stream.read()
            }
            #expect(Data(buffer: response) == testData)
            try await stream.close()
        }

        // Cleanup
        let serverConnection = try await withWebRTCStepTimeout("multiple server task completion", timeout: .seconds(10)) {
            try await serverTask.value
        }
        try await clientConnection.close()
        if let unwrappedServerConnection = serverConnection {
            do { try await unwrappedServerConnection.close() } catch { }
        }
        try await listener.close()
    }

    @Test("Many sequential bidirectional streams keep payload ordering", .timeLimit(.minutes(1)))
    func manySequentialBidirectionalStreams() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()
        let streamCount = 12

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                for index in 0..<streamCount {
                    let stream = try await withWebRTCStepTimeout("server accept stream \(index)") {
                        try await serverConnection.acceptStream()
                    }
                    let received = try await withWebRTCStepTimeout("server read stream \(index)") {
                        try await stream.read()
                    }
                    var response = ByteBuffer()
                    response.writeBytes(Data("echo-\(index):".utf8))
                    response.writeBytes(Data(buffer: received))
                    let responseToSend = response
                    try await withWebRTCStepTimeout("server write stream \(index)") {
                        try await stream.write(responseToSend)
                    }
                    try await withWebRTCStepTimeout("server close write stream \(index)") {
                        try await stream.closeWrite()
                    }
                    try await stream.close()
                }
                return serverConnection
            }
            return nil
        }

        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        for index in 0..<streamCount {
            let stream = try await withWebRTCStepTimeout("client new stream \(index)") {
                try await clientConnection.newStream()
            }
            let payload = Data(repeating: UInt8((index % 251) + 1), count: 64 + (index * 137))
            try await withWebRTCStepTimeout("client write stream \(index)") {
                try await stream.write(ByteBuffer(bytes: payload))
            }
            try await withWebRTCStepTimeout("client close write stream \(index)") {
                try await stream.closeWrite()
            }
            let response = try await withWebRTCStepTimeout("client read stream \(index)") {
                try await stream.read()
            }
            #expect(Data(buffer: response) == Data("echo-\(index):".utf8) + payload)
            try await stream.close()
        }

        let serverConnection = try await withWebRTCStepTimeout("server sequential task completion", timeout: .seconds(10)) {
            try await serverTask.value
        }
        try await clientConnection.close()
        if let serverConnection {
            do { try await serverConnection.close() } catch { }
        }
        try await listener.close()
    }

    @Test("Concurrent bidirectional streams do not cross-talk", .timeLimit(.minutes(1)))
    func concurrentBidirectionalStreamsDoNotCrossTalk() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()
        let streamCount = 6

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for index in 0..<streamCount {
                        let stream = try await withWebRTCStepTimeout("server concurrent accept \(index)") {
                            try await serverConnection.acceptStream()
                        }
                        group.addTask {
                            let received = try await withWebRTCStepTimeout("server concurrent read \(index)") {
                                try await stream.read()
                            }
                            var response = ByteBuffer()
                            response.writeBytes(Data("ack:".utf8))
                            response.writeBytes(Data(buffer: received))
                            let responseToSend = response
                            try await withWebRTCStepTimeout("server concurrent write \(index)") {
                                try await stream.write(responseToSend)
                            }
                            try await withWebRTCStepTimeout("server concurrent close write \(index)") {
                                try await stream.closeWrite()
                            }
                            try await stream.close()
                        }
                    }
                    try await group.waitForAll()
                }
                return serverConnection
            }
            return nil
        }

        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<streamCount {
                group.addTask {
                    let stream = try await withWebRTCStepTimeout("client concurrent new stream \(index)") {
                        try await clientConnection.newStream()
                    }
                    let payload = Data("payload-\(index)".utf8)
                    try await withWebRTCStepTimeout("client concurrent write \(index)") {
                        try await stream.write(ByteBuffer(bytes: payload))
                    }
                    try await withWebRTCStepTimeout("client concurrent close write \(index)") {
                        try await stream.closeWrite()
                    }
                    let response = try await withWebRTCStepTimeout("client concurrent read \(index)") {
                        try await stream.read()
                    }
                    #expect(Data(buffer: response) == Data("ack:".utf8) + payload)
                    try await stream.close()
                }
            }
            try await group.waitForAll()
        }

        let serverConnection = try await withWebRTCStepTimeout("server concurrent task completion", timeout: .seconds(10)) {
            try await serverTask.value
        }
        try await clientConnection.close()
        if let serverConnection {
            do { try await serverConnection.close() } catch { }
        }
        try await listener.close()
    }

    @Test("Server initiated streams are full duplex", .timeLimit(.minutes(1)))
    func serverInitiatedStreamsAreFullDuplex() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()
        let streamCount = 4

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                for index in 0..<streamCount {
                    let stream = try await withWebRTCStepTimeout("server initiated new stream \(index)") {
                        try await serverConnection.newStream()
                    }
                    let greeting = Data("server-\(index)".utf8)
                    try await withWebRTCStepTimeout("server initiated write \(index)") {
                        try await stream.write(ByteBuffer(bytes: greeting))
                    }
                    let reply = try await withWebRTCStepTimeout("server initiated read reply \(index)") {
                        try await stream.read()
                    }
                    #expect(Data(buffer: reply) == Data("client-\(index)".utf8))
                    try await withWebRTCStepTimeout("server initiated close write \(index)") {
                        try await stream.closeWrite()
                    }
                    try await stream.close()
                }
                return serverConnection
            }
            return nil
        }

        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        for index in 0..<streamCount {
            let stream = try await withWebRTCStepTimeout("client inbound stream \(index)") {
                try await clientConnection.acceptStream()
            }
            let greeting = try await withWebRTCStepTimeout("client inbound read \(index)") {
                try await stream.read()
            }
            #expect(Data(buffer: greeting) == Data("server-\(index)".utf8))
            try await withWebRTCStepTimeout("client inbound reply \(index)") {
                try await stream.write(ByteBuffer(bytes: Data("client-\(index)".utf8)))
            }
            try await withWebRTCStepTimeout("client inbound close write \(index)") {
                try await stream.closeWrite()
            }
            try await stream.close()
        }

        let serverConnection = try await withWebRTCStepTimeout("server initiated task completion", timeout: .seconds(10)) {
            try await serverTask.value
        }
        try await clientConnection.close()
        if let serverConnection {
            do { try await serverConnection.close() } catch { }
        }
        try await listener.close()
    }

    // MARK: - Connection Stream Tests

    @Test("Server can iterate over incoming connections", .timeLimit(.minutes(1)))
    func connectionStream() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // Start server
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        // Server iterates connections and returns received PeerIDs
        let serverTask = Task { () -> [PeerID] in
            var receivedPeerIDs: [PeerID] = []
            var count = 0
            for await connection in listener.connections {
                receivedPeerIDs.append(connection.remotePeer)
                count += 1
                if count >= 2 {
                    break
                }
            }
            return receivedPeerIDs
        }

        // Connect 2 clients
        let client1 = KeyPair.generateEd25519()
        let client2 = KeyPair.generateEd25519()

        let conn1 = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: client1
        )
        let conn2 = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: client2
        )

        // Wait for server to receive
        let receivedPeerIDs = await serverTask.value

        // Verify both clients were received
        #expect(receivedPeerIDs.contains(client1.peerID))
        #expect(receivedPeerIDs.contains(client2.peerID))

        // Cleanup
        try await conn1.close()
        try await conn2.close()
        try await listener.close()
    }

    @Test("Sequential reconnects release listener routes", .timeLimit(.minutes(1)))
    func sequentialReconnectsReleaseListenerRoutes() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()
        let clientCount = 5

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        let serverTask = Task { () -> [PeerID] in
            var peers: [PeerID] = []
            for await serverConnection in listener.connections {
                let stream = try await withWebRTCStepTimeout("server reconnect accept \(peers.count)") {
                    try await serverConnection.acceptStream()
                }
                let data = try await withWebRTCStepTimeout("server reconnect read \(peers.count)") {
                    try await stream.read()
                }
                try await withWebRTCStepTimeout("server reconnect write \(peers.count)") {
                    try await stream.write(data)
                }
                try await stream.close()
                peers.append(serverConnection.remotePeer)
                try await serverConnection.close()
                if peers.count == clientCount {
                    break
                }
            }
            return peers
        }

        var expectedPeers: [PeerID] = []
        for index in 0..<clientCount {
            let clientKeyPair = KeyPair.generateEd25519()
            expectedPeers.append(clientKeyPair.peerID)
            let clientConnection = try await withWebRTCStepTimeout("client reconnect dial \(index)") {
                try await transport.dialSecured(listener.localAddress, localKeyPair: clientKeyPair)
            }
            let stream = try await withWebRTCStepTimeout("client reconnect stream \(index)") {
                try await clientConnection.newStream()
            }
            let payload = Data("reconnect-\(index)".utf8)
            try await withWebRTCStepTimeout("client reconnect write \(index)") {
                try await stream.write(ByteBuffer(bytes: payload))
            }
            try await withWebRTCStepTimeout("client reconnect close write \(index)") {
                try await stream.closeWrite()
            }
            let response = try await withWebRTCStepTimeout("client reconnect read \(index)") {
                try await stream.read()
            }
            #expect(Data(buffer: response) == payload)
            try await stream.close()
            try await clientConnection.close()
        }

        let observedPeers = try await withWebRTCStepTimeout("server reconnect task completion", timeout: .seconds(10)) {
            try await serverTask.value
        }
        #expect(observedPeers == expectedPeers)
        try await listener.close()
    }

    @Test("Client can iterate over inbound streams", .timeLimit(.minutes(1)))
    func inboundStreamIteration() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // Start server
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        // Server opens streams to client
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                // Open 3 streams to client
                for i in 0..<3 {
                    let stream = try await withWebRTCStepTimeout("inbound server new stream \(i)") {
                        try await serverConnection.newStream()
                    }
                    try await withWebRTCStepTimeout("inbound server write \(i)") {
                        try await stream.write(ByteBuffer(bytes: Data("Server stream \(i)".utf8)))
                    }
                    try await withWebRTCStepTimeout("inbound server close write \(i)") {
                        try await stream.closeWrite()
                    }
                }
                return serverConnection
            }
            return nil
        }

        // Client
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        // Collect messages from server-initiated streams
        let collectTask = Task { () -> [Data] in
            var messages: [Data] = []
            var count = 0
            for await stream in clientConnection.inboundStreams {
                let data = try await withWebRTCStepTimeout("inbound client read \(count)") {
                    try await stream.read()
                }
                messages.append(Data(buffer: data))
                try await stream.close()
                count += 1
                if count >= 3 {
                    break
                }
            }
            return messages
        }

        // Wait for all streams
        let serverConnection = try await withWebRTCStepTimeout("inbound server task completion", timeout: .seconds(10)) {
            try await serverTask.value
        }
        let messages = try await withWebRTCStepTimeout("inbound collect task completion", timeout: .seconds(10)) {
            try await collectTask.value
        }

        // Verify
        #expect(messages.count == 3)

        // Cleanup
        try await clientConnection.close()
        if let unwrappedServerConnection = serverConnection {
            do { try await unwrappedServerConnection.close() } catch { }
        }
        try await listener.close()
    }

    // MARK: - Error Handling Tests

    @Test("Dial with mismatched /p2p PeerID is rejected", .timeLimit(.minutes(1)))
    func peerIDMismatchRejected() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        // Pin a PeerID that the server's certificate cannot prove
        let wrongPeer = KeyPair.generateEd25519().peerID
        let pinnedAddress = Multiaddr(
            uncheckedProtocols: listener.localAddress.protocols + [.p2p(wrongPeer)]
        )

        do {
            _ = try await transport.dialSecured(pinnedAddress, localKeyPair: clientKeyPair)
            Issue.record("Expected peerIDMismatch error")
        } catch let error as WebRTCTransportError {
            guard case .peerIDMismatch(let expected, let actual) = error else {
                Issue.record("Expected peerIDMismatch, got \(error)")
                return
            }
            #expect(expected == wrongPeer)
            #expect(actual == serverKeyPair.peerID)
        }

        try await listener.close()
    }

    @Test("Dial with wrong certhash digest fails instead of hanging", .timeLimit(.minutes(1)))
    func wrongCerthashDigestRejected() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        // Well-formed sha2-256 multihash whose digest does not match the
        // server's certificate fingerprint
        let port = try #require(listener.localAddress.udpPort)
        let wrongHash = Data([0x12, 0x20] + Array(repeating: UInt8(0xCD), count: 32))
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"), .udp(port), .webrtcDirect, .certhash(wrongHash)
        ])

        do {
            _ = try await transport.dialSecured(addr, localKeyPair: clientKeyPair)
            Issue.record("Expected dial to fail on fingerprint mismatch")
        } catch let error as WebRTCTransportError {
            switch error {
            case .dtlsHandshakeFailed, .handshakeTimeout, .connectionClosed:
                break // fingerprint mismatch surfaces as a handshake failure
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }

        try await listener.close()
    }

    @Test("Listen on unassigned address throws socketBindFailed", .timeLimit(.minutes(1)))
    func bindFailureThrowsSocketBindFailed() async throws {
        let keyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // TEST-NET-3 address is not assigned to any local interface
        do {
            _ = try await transport.listenSecured(
                try Multiaddr("/ip4/203.0.113.7/udp/0/webrtc-direct"),
                localKeyPair: keyPair
            )
            Issue.record("Expected bind to fail")
        } catch let error as WebRTCTransportError {
            guard case .socketBindFailed = error else {
                Issue.record("Expected socketBindFailed, got \(error)")
                return
            }
        }
    }

    @Test("Dial with unresolvable socket address throws invalidAddress", .timeLimit(.minutes(1)))
    func unresolvableSocketAddressThrowsInvalidAddress() async throws {
        let keyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // A zoned IPv6 literal is a valid multiaddr component (validation
        // strips the zone) but NIO's SocketAddress cannot parse it, so the
        // dial must fail with a typed invalidAddress error. Malformed IPs
        // like 999.0.0.1 cannot reach the dial path at all: every validated
        // Multiaddr constructor rejects them (covered by MultiaddrTests).
        let certhash = Data([0x12, 0x20] + Array(repeating: UInt8(0xAB), count: 32))
        let addr = try Multiaddr(protocols: [
            .ip6("fe80::1%zone0"), .udp(4001), .webrtcDirect, .certhash(certhash)
        ])

        do {
            _ = try await transport.dialSecured(addr, localKeyPair: keyPair)
            Issue.record("Expected invalidAddress")
        } catch let error as WebRTCTransportError {
            guard case .invalidAddress = error else {
                Issue.record("Expected invalidAddress, got \(error)")
                return
            }
        }
    }

    @Test("Closed listener finishes its connections stream", .timeLimit(.minutes(1)))
    func closedListenerFinishesConnectionsStream() async throws {
        let keyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: keyPair
        )

        try await listener.close()
        // close() is idempotent
        try await listener.close()

        // The stream must finish, not hang (the time limit is the guard)
        var received = 0
        for await _ in listener.connections { received += 1 }
        #expect(received == 0)
    }

    @Test("Connection survives late data on a locally closed stream", .timeLimit(.minutes(1)))
    func lateDataOnClosedStreamDoesNotPoisonConnection() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
            localKeyPair: serverKeyPair
        )

        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                // First stream: read once, then close locally. Closing is
                // local-only, so the client can keep sending afterwards.
                let first = try await withWebRTCStepTimeout("late-data server accept first") {
                    try await serverConnection.acceptStream()
                }
                _ = try await withWebRTCStepTimeout("late-data server read first") {
                    try await first.read()
                }
                try await withWebRTCStepTimeout("late-data server write first ack") {
                    try await first.write(ByteBuffer(bytes: Data([0x01])))
                }
                try await withWebRTCStepTimeout("late-data server close first write") {
                    try await first.closeWrite()
                }
                try await first.close()

                // Second stream: must work even after late data arrived
                // for the closed first stream
                let second = try await withWebRTCStepTimeout("late-data server accept second") {
                    try await serverConnection.acceptStream()
                }
                let data = try await withWebRTCStepTimeout("late-data server read second") {
                    try await second.read()
                }
                try await withWebRTCStepTimeout("late-data server write second") {
                    try await second.write(data)
                }
                try await withWebRTCStepTimeout("late-data server close second write") {
                    try await second.closeWrite()
                }
                return serverConnection
            }
            return nil
        }

        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        let firstStream = try await clientConnection.newStream()
        try await firstStream.write(ByteBuffer(bytes: Data("first".utf8)))

        // Wait until the server has consumed the first payload and closed
        // its local side of the first stream.
        _ = try await withWebRTCStepTimeout("late-data first ack") {
            try await firstStream.read()
        }

        // Late data for the closed channel — must be dropped server-side
        // without poisoning the connection's pending buffers
        for index in 0..<8 {
            try await withWebRTCStepTimeout("late write \(index)") {
                try await firstStream.write(ByteBuffer(bytes: Data(repeating: 0xEE, count: 32 * 1024)))
            }
        }

        // A fresh stream must still work end-to-end
        let secondStream = try await withWebRTCStepTimeout("new second stream") {
            try await clientConnection.newStream()
        }
        let payload = Data("second".utf8)
        try await withWebRTCStepTimeout("second stream write") {
            try await secondStream.write(ByteBuffer(bytes: payload))
        }
        try await withWebRTCStepTimeout("second stream closeWrite") {
            try await secondStream.closeWrite()
        }
        let echoed = try await withWebRTCStepTimeout("second stream read", timeout: .seconds(10)) {
            try await secondStream.read()
        }
        #expect(Data(buffer: echoed) == payload)

        // Cleanup
        let serverConnection = try await withWebRTCStepTimeout("server task completion", timeout: .seconds(10)) {
            try await serverTask.value
        }
        try await clientConnection.close()
        if let serverConnection {
            do { try await serverConnection.close() } catch { }
        }
        try await listener.close()
    }

    @Test("Invalid multiaddr throws unsupportedAddress", .timeLimit(.minutes(1)))
    func invalidMultiaddrThrows() async throws {
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = WebRTCTransport()

        // TCP address is not WebRTC
        do {
            _ = try await transport.dialSecured(
                try Multiaddr("/ip4/127.0.0.1/tcp/4433"),
                localKeyPair: clientKeyPair
            )
            Issue.record("Expected error to be thrown")
        } catch let error as TransportError {
            // Expected - verify it's an unsupported address error
            if case .unsupportedAddress = error {
                // Success
            } else {
                Issue.record("Expected unsupportedAddress error, got \(error)")
            }
        } catch {
            Issue.record("Expected TransportError, got \(error)")
        }
    }
}
