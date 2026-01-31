import Testing
import Foundation
@testable import P2PCore
@testable import P2PTransport
@testable import P2PTransportWebSocket

@Suite("WebSocket Transport Tests")
struct WebSocketTransportTests {

    // MARK: - Basic Connection Tests

    @Test("Basic dial and listen", .timeLimit(.minutes(1)))
    func testBasicConnection() async throws {
        let transport = WebSocketTransport()

        // Start listener on ephemeral port
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress
        #expect(listenAddr.tcpPort != nil)
        #expect(listenAddr.tcpPort! > 0)

        // Verify address contains /ws
        let hasWS = listenAddr.protocols.contains(where: { if case .ws = $0 { return true } else { return false } })
        #expect(hasWS)

        // Dial and accept concurrently
        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Verify addresses
        #expect(clientConn.remoteAddress.ipAddress == "127.0.0.1")
        #expect(serverConn.remoteAddress.ipAddress != nil)

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    @Test("Bidirectional communication", .timeLimit(.minutes(1)))
    func testBidirectionalCommunication() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Client sends to server
        let clientMessage = Data("hello from client".utf8)
        try await clientConn.write(clientMessage)
        let receivedAtServer = try await serverConn.read()
        #expect(receivedAtServer == clientMessage)

        // Server sends to client
        let serverMessage = Data("hello from server".utf8)
        try await serverConn.write(serverMessage)
        let receivedAtClient = try await clientConn.read()
        #expect(receivedAtClient == serverMessage)

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    @Test("Multiple messages in sequence", .timeLimit(.minutes(1)))
    func testMultipleMessages() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Send 5 sequential messages
        for i in 1...5 {
            let message = Data("message \(i)".utf8)
            try await clientConn.write(message)
            let received = try await serverConn.read()
            #expect(String(decoding: received, as: UTF8.self) == "message \(i)")
        }

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    @Test("Large message transfer", .timeLimit(.minutes(1)))
    func testLargeMessage() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Send a large message (64KB)
        let largeMessage = Data(repeating: 0xAB, count: 64 * 1024)
        try await clientConn.write(largeMessage)

        // WebSocket delivers full frames, so a single read should return all data
        let received = try await serverConn.read()
        #expect(received == largeMessage)

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - Multiple Connection Tests

    @Test("Multiple connections to same listener", .timeLimit(.minutes(1)))
    func testMultipleConnections() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        // Create 3 connections
        var clientConns: [any RawConnection] = []
        var serverConns: [any RawConnection] = []

        for i in 0..<3 {
            async let acceptTask = listener.accept()
            let clientConn = try await transport.dial(listenAddr)
            let serverConn = try await acceptTask

            clientConns.append(clientConn)
            serverConns.append(serverConn)

            // Verify each connection works
            let message = Data("conn \(i)".utf8)
            try await clientConn.write(message)
            let received = try await serverConn.read()
            #expect(String(decoding: received, as: UTF8.self) == "conn \(i)")
        }

        // Clean up
        for conn in clientConns + serverConns {
            try? await conn.close()
        }
        try await listener.close()
    }

    @Test("Concurrent dial and accept", .timeLimit(.minutes(1)))
    func testConcurrentDialAndAccept() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        let connectionCount = 5

        // Accept task that handles multiple connections
        let acceptTask = Task {
            var serverConns: [any RawConnection] = []
            for _ in 0..<connectionCount {
                let conn = try await listener.accept()
                serverConns.append(conn)
            }
            return serverConns
        }

        // Dial concurrently
        let clientConns = try await withThrowingTaskGroup(of: (any RawConnection).self) { group in
            for _ in 0..<connectionCount {
                group.addTask {
                    try await transport.dial(listenAddr)
                }
            }

            var conns: [any RawConnection] = []
            for try await conn in group {
                conns.append(conn)
            }
            return conns
        }

        let serverConns = try await acceptTask.value

        #expect(clientConns.count == connectionCount)
        #expect(serverConns.count == connectionCount)

        // Clean up
        for conn in clientConns + serverConns {
            try? await conn.close()
        }
        try await listener.close()
    }

    // MARK: - Close Behavior Tests

    @Test("Close connection", .timeLimit(.minutes(1)))
    func testCloseConnection() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Close client side
        try await clientConn.close()

        // Server read should throw connection closed error
        await #expect(throws: TransportError.self) {
            _ = try await serverConn.read()
        }

        // Clean up
        try await serverConn.close()
        try await listener.close()
    }

    @Test("Write after close throws error", .timeLimit(.minutes(1)))
    func testWriteAfterClose() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        _ = try await acceptTask

        // Close and try to write
        try await clientConn.close()

        await #expect(throws: Error.self) {
            try await clientConn.write(Data("should fail".utf8))
        }

        try await listener.close()
    }

    @Test("Listener close rejects pending accept", .timeLimit(.minutes(1)))
    func testListenerClose() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))

        // Start accept without any connections
        let acceptTask = Task {
            try await listener.accept()
        }

        // Give accept time to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Close listener
        try await listener.close()

        // Accept should throw
        await #expect(throws: TransportError.self) {
            _ = try await acceptTask.value
        }
    }

    @Test("Buffered data before close is readable", .timeLimit(.minutes(1)))
    func testBufferedDataBeforeClose() async throws {
        let transport = WebSocketTransport()

        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Client sends data
        let message = Data("buffered message".utf8)
        try await clientConn.write(message)

        // Small delay to ensure data is buffered on server side
        try await Task.sleep(for: .milliseconds(50))

        // Server should receive the data
        let received = try await serverConn.read()
        #expect(received == message)

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - Address Tests

    @Test("canDial returns true for WS addresses", .timeLimit(.minutes(1)))
    func testCanDialWS() {
        let transport = WebSocketTransport()

        #expect(transport.canDial(.ws(host: "127.0.0.1", port: 4001)))
        #expect(transport.canDial(.ws(host: "192.168.1.1", port: 80)))
        // TCP-only (no /ws) should fail
        #expect(!transport.canDial(.tcp(host: "127.0.0.1", port: 4001)))
        // Memory should fail
        #expect(!transport.canDial(.memory(id: "test")))
    }

    @Test("canListen returns true for WS addresses", .timeLimit(.minutes(1)))
    func testCanListenWS() {
        let transport = WebSocketTransport()

        #expect(transport.canListen(.ws(host: "0.0.0.0", port: 4001)))
        #expect(transport.canListen(.ws(host: "127.0.0.1", port: 0)))
        // TCP-only should fail
        #expect(!transport.canListen(.tcp(host: "0.0.0.0", port: 4001)))
        // Memory should fail
        #expect(!transport.canListen(.memory(id: "test")))
    }

    @Test("protocols property returns WS protocols")
    func testProtocolsProperty() {
        let transport = WebSocketTransport()

        let protocols = transport.protocols
        #expect(protocols.contains(["ip4", "tcp", "ws"]))
        #expect(protocols.contains(["ip6", "tcp", "ws"]))
    }

    @Test("Unsupported address throws error", .timeLimit(.minutes(1)))
    func testUnsupportedAddress() async throws {
        let transport = WebSocketTransport()

        // Try to dial a non-WS address (memory address)
        await #expect(throws: TransportError.self) {
            _ = try await transport.dial(.memory(id: "test"))
        }

        // Try to listen on non-WS address (TCP without /ws)
        await #expect(throws: TransportError.self) {
            _ = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        }
    }

    @Test("WS Multiaddr factory", .timeLimit(.minutes(1)))
    func testWSMultiaddrFactory() throws {
        let addr = Multiaddr.ws(host: "127.0.0.1", port: 8080)

        #expect(addr.ipAddress == "127.0.0.1")
        #expect(addr.tcpPort == 8080)
        #expect(addr.description == "/ip4/127.0.0.1/tcp/8080/ws")

        let hasWS = addr.protocols.contains(where: { if case .ws = $0 { return true } else { return false } })
        #expect(hasWS)

        // IPv6 variant
        let addr6 = Multiaddr.ws(host: "::1", port: 9090)
        #expect(addr6.tcpPort == 9090)
        let hasWS6 = addr6.protocols.contains(where: { if case .ws = $0 { return true } else { return false } })
        #expect(hasWS6)
    }
}
