/// End-to-end tests for WebRTC Direct transport.
///
/// These tests verify actual WebRTC Direct connections between client and server,
/// including DTLS handshake, PeerID verification, and stream multiplexing
/// over real UDP sockets on localhost.

import Testing
import Foundation
@testable import P2PTransportWebRTC
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux

@Suite("WebRTC E2E Tests")
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
                let stream = try await serverConnection.acceptStream()

                // Read data
                let received = try await stream.read()

                // Echo back with modification
                try await stream.write(received + Data(" - echoed".utf8))

                // Close write side
                try await stream.closeWrite()

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
        let clientStream = try await clientConnection.newStream()

        // Send data
        let testData = Data("Hello WebRTC".utf8)
        try await clientStream.write(testData)
        try await clientStream.closeWrite()

        // Read response
        let response = try await clientStream.read()
        #expect(response == Data("Hello WebRTC - echoed".utf8))

        // Cleanup
        let serverConnection = try await serverTask.value
        try await clientStream.close()
        try await clientConnection.close()
        try? await serverConnection?.close()
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
                for _ in 0..<3 {
                    let stream = try await serverConnection.acceptStream()
                    let data = try await stream.read()
                    try await stream.write(data)
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
            let stream = try await clientConnection.newStream()
            let testData = Data("Stream \(i)".utf8)
            try await stream.write(testData)
            try await stream.closeWrite()

            let response = try await stream.read()
            #expect(response == testData)
            try await stream.close()
        }

        // Cleanup
        let serverConnection = try await serverTask.value
        try await clientConnection.close()
        try? await serverConnection?.close()
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
                    let stream = try await serverConnection.newStream()
                    try await stream.write(Data("Server stream \(i)".utf8))
                    try await stream.closeWrite()
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
                let data = try await stream.read()
                messages.append(data)
                try await stream.close()
                count += 1
                if count >= 3 {
                    break
                }
            }
            return messages
        }

        // Wait for all streams
        let serverConnection = try await serverTask.value
        let messages = try await collectTask.value

        // Verify
        #expect(messages.count == 3)

        // Cleanup
        try await clientConnection.close()
        try? await serverConnection?.close()
        try await listener.close()
    }

    // MARK: - Error Handling Tests

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
