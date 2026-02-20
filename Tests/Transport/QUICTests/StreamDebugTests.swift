/// Debug tests to isolate stream issues in QUIC transport.
///
/// Run with: swift test --filter StreamDebugTests

import Testing
import Foundation
import NIOCore
@testable import P2PTransportQUIC
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
import QUIC

@Suite("Stream Debug Tests")
struct StreamDebugTests {

    // MARK: - Step 1: Verify Connection Establishment

    @Test("Connection is established and isEstablished returns true", .timeLimit(.minutes(1)))
    func connectionEstablished() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // Start server
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        print("Server listening on: \(listener.localAddress)")

        // Accept connection in background
        let acceptTask = Task { () -> (any MuxedConnection)? in
            for await connection in listener.connections {
                print("Server accepted connection from: \(connection.remotePeer)")
                return connection
            }
            return nil
        }

        // Connect from client
        print("Client connecting...")
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        print("Client connected!")
        print("Client local peer: \(clientConnection.localPeer)")
        print("Client remote peer: \(clientConnection.remotePeer)")

        // Wait for server to accept
        guard let serverConnection = await acceptTask.value else {
            Issue.record("Server did not receive connection")
            return
        }

        print("Server connection established!")
        print("Server local peer: \(serverConnection.localPeer)")
        print("Server remote peer: \(serverConnection.remotePeer)")

        // Check connection status
        if let quicMuxed = clientConnection as? QUICMuxedConnection,
           let managedConn = getManagedConnection(from: quicMuxed) {
            print("Client QUIC connection isEstablished: \(managedConn.isEstablished)")
        }

        // Verify PeerIDs
        #expect(clientConnection.localPeer == clientKeyPair.peerID)
        #expect(clientConnection.remotePeer == serverKeyPair.peerID)
        #expect(serverConnection.localPeer == serverKeyPair.peerID)
        #expect(serverConnection.remotePeer == clientKeyPair.peerID)

        // Small delay to allow any async operations to complete
        try await Task.sleep(for: .milliseconds(100))

        // Cleanup
        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()

        print("Test completed successfully!")
    }

    // MARK: - Step 2: Open Stream Immediately After Connection

    @Test("Can open stream immediately after connection", .timeLimit(.minutes(1)))
    func openStreamImmediately() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        // Server task - just accept connection
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await connection in listener.connections {
                print("[Server] Got connection from: \(connection.remotePeer)")
                return connection
            }
            return nil
        }

        // Client connects
        print("[Client] Connecting...")
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )
        print("[Client] Connected!")

        // Wait for server
        guard let serverConnection = await serverTask.value else {
            Issue.record("Server did not accept connection")
            return
        }

        // Small delay
        try await Task.sleep(for: .milliseconds(100))

        // Try to open stream from client
        print("[Client] Opening stream...")
        do {
            let stream = try await clientConnection.newStream()
            print("[Client] Stream opened! ID: \(stream)")
            try await stream.close()
        } catch {
            print("[Client] Failed to open stream: \(error)")
            throw error
        }

        // Cleanup
        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()

        print("Test completed!")
    }

    // MARK: - Step 3: Debug underlying QUIC connection

    @Test("Check underlying QUIC connection state", .timeLimit(.minutes(1)))
    func checkQUICState() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        let serverTask = Task { () -> (any MuxedConnection)? in
            for await connection in listener.connections {
                return connection
            }
            return nil
        }

        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        guard let serverConnection = await serverTask.value else {
            Issue.record("Server did not accept connection")
            return
        }

        // Check the underlying QUIC connection
        if let quicMuxed = clientConnection as? QUICMuxedConnection {
            // Use reflection to get internal state
            let mirror = Mirror(reflecting: quicMuxed)
            for child in mirror.children {
                print("QUICMuxedConnection.\(child.label ?? "?"): \(type(of: child.value))")
            }

            if let managedConn = getManagedConnection(from: quicMuxed) {
                print("ManagedConnection.isEstablished: \(managedConn.isEstablished)")
                print("ManagedConnection.handshakeState: \(managedConn.handshakeState)")
            }
        }

        // Cleanup
        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()
    }

    // MARK: - Step 4: Write to stream

    @Test("Can write to stream after opening", .timeLimit(.minutes(1)))
    func writeToStream() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        // Server just accepts connection
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await connection in listener.connections {
                print("[Server] Got connection")
                return connection
            }
            return nil
        }

        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )
        print("[Client] Connected")

        guard let serverConnection = await serverTask.value else {
            Issue.record("Server did not accept connection")
            return
        }

        try await Task.sleep(for: .milliseconds(100))

        // Open stream
        print("[Client] Opening stream...")
        let stream = try await clientConnection.newStream()
        print("[Client] Stream opened")

        // Write data
        print("[Client] Writing data...")
        let testData = Data("Hello QUIC".utf8)
        try await stream.write(ByteBuffer(bytes: testData))
        print("[Client] Data written")

        // Close write
        print("[Client] Closing write side...")
        try await stream.closeWrite()
        print("[Client] Write side closed")

        // Cleanup
        try await stream.close()
        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()

        print("Test completed!")
    }

    // MARK: - Step 5: Server accepts stream

    @Test("Server can accept stream from client", .timeLimit(.minutes(1)))
    func serverAcceptsStream() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        // Server accepts connection and stream
        let serverTask = Task { () -> (any MuxedConnection, MuxedStream)? in
            print("[Server] Waiting for connection...")
            for await connection in listener.connections {
                print("[Server] Got connection, waiting for stream...")
                let stream = try await connection.acceptStream()
                print("[Server] Got stream!")
                return (connection, stream)
            }
            return nil
        }

        // Client connects and opens stream
        print("[Client] Connecting...")
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )
        print("[Client] Connected, opening stream...")

        let clientStream = try await clientConnection.newStream()
        print("[Client] Stream opened, writing data...")

        // Write some data to trigger the stream to be visible on server
        try await clientStream.write(ByteBuffer(bytes: Data("Hello".utf8)))
        print("[Client] Data written")

        // Wait for server to accept stream
        print("[Main] Waiting for server to accept stream...")
        guard let (serverConnection, serverStream) = try? await serverTask.value else {
            Issue.record("Server did not accept stream")
            try await clientConnection.close()
            try await listener.close()
            return
        }
        print("[Main] Server accepted stream!")

        // Cleanup
        try await clientStream.close()
        try await serverStream.close()
        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()

        print("Test completed!")
    }

    // MARK: - Step 6: Full echo

    @Test("Full echo roundtrip", .timeLimit(.minutes(1)))
    func fullEchoRoundtrip() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        // Server echoes back data
        let serverTask = Task { () -> (any MuxedConnection)? in
            print("[Server] Waiting for connection...")
            for await connection in listener.connections {
                print("[Server] Got connection, waiting for stream...")
                do {
                    let stream = try await connection.acceptStream()
                    print("[Server] Got stream, reading data...")

                    let data = try await stream.read()
                    print("[Server] Read \(data.readableBytes) bytes: \(String(buffer: data))")

                    print("[Server] Echoing back...")
                    var echoBuffer = data
                    echoBuffer.writeBytes(Data(" - echoed".utf8))
                    try await stream.write(echoBuffer)

                    print("[Server] Closing write side...")
                    try await stream.closeWrite()

                    print("[Server] Done!")
                    return connection
                } catch {
                    print("[Server] Error: \(error)")
                    throw error
                }
            }
            return nil
        }

        // Client
        print("[Client] Connecting...")
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )
        print("[Client] Connected, opening stream...")

        let clientStream = try await clientConnection.newStream()
        print("[Client] Stream opened, writing data...")

        let testData = Data("Hello QUIC".utf8)
        try await clientStream.write(ByteBuffer(bytes: testData))
        print("[Client] Data written, closing write side...")

        try await clientStream.closeWrite()
        print("[Client] Write side closed, reading response...")

        let response = try await clientStream.read()
        print("[Client] Got response: \(String(buffer: response))")

        #expect(Data(buffer: response) == Data("Hello QUIC - echoed".utf8))

        // Wait for server
        let serverConnection: (any MuxedConnection)?
        do {
            serverConnection = try await serverTask.value
        } catch {
            serverConnection = nil
        }

        // Cleanup
        try await clientStream.close()
        try await clientConnection.close()
        if let unwrappedServerConnection = serverConnection {
            do { try await unwrappedServerConnection.close() } catch { }
        }
        try await listener.close()

        print("Test completed!")
    }

    // MARK: - Step 7: Multiple streams debug

    @Test("Multiple streams sequential echo", .timeLimit(.minutes(1)))
    func multipleStreamsSequential() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        // Server echoes back data on multiple streams
        let serverTask = Task { () -> (any MuxedConnection)? in
            print("[Server] Waiting for connection...")
            for await connection in listener.connections {
                print("[Server] Got connection")

                // Handle 3 streams
                for i in 0..<3 {
                    print("[Server] Waiting for stream \(i)...")
                    do {
                        let stream = try await connection.acceptStream()
                        print("[Server] Got stream \(i), reading...")

                        let data = try await stream.read()
                        print("[Server] Stream \(i): Read '\(String(buffer: data))'")

                        try await stream.write(data)
                        print("[Server] Stream \(i): Echoed back")

                        try await stream.close()
                        print("[Server] Stream \(i): Closed")
                    } catch {
                        print("[Server] Stream \(i): ERROR - \(error)")
                        throw error
                    }
                }

                return connection
            }
            return nil
        }

        // Client
        print("[Client] Connecting...")
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )
        print("[Client] Connected!")

        // Open 3 streams sequentially
        for i in 0..<3 {
            print("[Client] Opening stream \(i)...")
            let stream = try await clientConnection.newStream()
            print("[Client] Stream \(i) opened")

            let testData = Data("Stream \(i)".utf8)
            try await stream.write(ByteBuffer(bytes: testData))
            print("[Client] Stream \(i): Wrote data")

            try await stream.closeWrite()
            print("[Client] Stream \(i): Closed write")

            let response = try await stream.read()
            print("[Client] Stream \(i): Got response '\(String(buffer: response))'")

            #expect(Data(buffer: response) == testData)

            try await stream.close()
            print("[Client] Stream \(i): Closed")
        }

        // Wait for server
        let serverConnection: (any MuxedConnection)?
        do {
            serverConnection = try await serverTask.value
        } catch {
            serverConnection = nil
        }

        // Cleanup
        try await clientConnection.close()
        if let unwrappedServerConnection = serverConnection {
            do { try await unwrappedServerConnection.close() } catch { }
        }
        try await listener.close()

        print("Test completed!")
    }

    // MARK: - Helper

    private func getManagedConnection(from muxed: QUICMuxedConnection) -> ManagedConnection? {
        let mirror = Mirror(reflecting: muxed)
        for child in mirror.children {
            if let conn = child.value as? ManagedConnection {
                return conn
            }
            // Check for protocol existential
            if child.label == "quicConnection" {
                let valueMirror = Mirror(reflecting: child.value)
                for subChild in valueMirror.children {
                    if let managed = subChild.value as? ManagedConnection {
                        return managed
                    }
                }
                // Try direct cast (might work through protocol)
                if let managed = child.value as? ManagedConnection {
                    return managed
                }
            }
        }
        return nil
    }
}
