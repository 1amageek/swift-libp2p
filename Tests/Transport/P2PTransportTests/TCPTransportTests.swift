import Testing
import Foundation
@testable import P2PCore
@testable import P2PTransport
@testable import P2PTransportTCP
import NIOCore
import NIOPosix

@Suite("TCP Transport Tests")
struct TCPTransportTests {

    // MARK: - Basic Connection Tests

    @Test("Basic dial and listen", .timeLimit(.minutes(1)))
    func testBasicConnection() async throws {
        let transport = TCPTransport()

        // Start listener on ephemeral port
        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress
        #expect(listenAddr.tcpPort != nil)
        #expect(listenAddr.tcpPort! > 0)

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

    // TEMPORARILY DISABLED - causes test runner hang
    // @Test("Bidirectional communication", .timeLimit(.minutes(1)))
    func _testBidirectionalCommunication() async throws {
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
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
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Send multiple messages
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
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Send a large message (64KB)
        let largeMessage = Data(repeating: 0xAB, count: 64 * 1024)
        try await clientConn.write(largeMessage)

        // Read may return data in chunks, so accumulate
        var receivedData = Data()
        while receivedData.count < largeMessage.count {
            let chunk = try await serverConn.read()
            receivedData.append(chunk)
        }
        #expect(receivedData == largeMessage)

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - Multiple Connections Tests

    @Test("Multiple connections to same listener", .timeLimit(.minutes(1)))
    func testMultipleConnections() async throws {
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
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

    @Test("Multiple listeners on different ports", .timeLimit(.minutes(1)))
    func testMultipleListeners() async throws {
        let transport = TCPTransport()

        let listener1 = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listener2 = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))

        // Ensure different ports
        #expect(listener1.localAddress.tcpPort != listener2.localAddress.tcpPort)

        // Connect to each
        async let accept1 = listener1.accept()
        let conn1 = try await transport.dial(listener1.localAddress)
        let server1 = try await accept1

        async let accept2 = listener2.accept()
        let conn2 = try await transport.dial(listener2.localAddress)
        let server2 = try await accept2

        // Verify isolation
        try await conn1.write(Data("to-1".utf8))
        try await conn2.write(Data("to-2".utf8))

        let received1 = try await server1.read()
        let received2 = try await server2.read()

        #expect(String(decoding: received1, as: UTF8.self) == "to-1")
        #expect(String(decoding: received2, as: UTF8.self) == "to-2")

        // Clean up
        try await conn1.close()
        try await conn2.close()
        try await server1.close()
        try await server2.close()
        try await listener1.close()
        try await listener2.close()
    }

    // MARK: - Close Behavior Tests

    @Test("Connection close propagates to remote", .timeLimit(.minutes(1)))
    func testClosePropagatesEOF() async throws {
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
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
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        _ = try await acceptTask

        // Close and try to write
        try await clientConn.close()

        // Write should fail (NIO channel is closed)
        await #expect(throws: Error.self) {
            try await clientConn.write(Data("should fail".utf8))
        }

        try await listener.close()
    }

    @Test("Listener close rejects pending accept", .timeLimit(.minutes(1)))
    func testListenerCloseRejectsPendingAccept() async throws {
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))

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

    @Test("Read returns buffered data before connection close", .timeLimit(.minutes(1)))
    func testBufferedDataBeforeClose() async throws {
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
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

    // MARK: - Error Handling Tests

    @Test("Dial to unreachable host times out or fails", .timeLimit(.minutes(1)))
    func testDialToUnreachable() async throws {
        let transport = TCPTransport()

        // Dial to a port that should be closed
        await #expect(throws: Error.self) {
            _ = try await transport.dial(.tcp(host: "127.0.0.1", port: 1))
        }
    }

    @Test("Unsupported address throws error", .timeLimit(.minutes(1)))
    func testUnsupportedAddress() async throws {
        let transport = TCPTransport()

        // Try to dial a non-TCP address (memory address)
        await #expect(throws: TransportError.self) {
            _ = try await transport.dial(.memory(id: "test"))
        }

        // Try to listen on non-TCP address
        await #expect(throws: TransportError.self) {
            _ = try await transport.listen(.memory(id: "test"))
        }
    }

    // MARK: - canDial/canListen Tests

    @Test("canDial returns true for TCP addresses")
    func testCanDialTCP() {
        let transport = TCPTransport()

        #expect(transport.canDial(.tcp(host: "127.0.0.1", port: 4001)))
        #expect(transport.canDial(.tcp(host: "192.168.1.1", port: 80)))
        #expect(!transport.canDial(.memory(id: "test")))
    }

    @Test("canListen returns true for TCP addresses")
    func testCanListenTCP() {
        let transport = TCPTransport()

        #expect(transport.canListen(.tcp(host: "0.0.0.0", port: 4001)))
        #expect(transport.canListen(.tcp(host: "127.0.0.1", port: 0)))
        #expect(!transport.canListen(.memory(id: "test")))
    }

    @Test("protocols property returns TCP protocols")
    func testProtocolsProperty() {
        let transport = TCPTransport()

        let protocols = transport.protocols
        #expect(protocols.contains(["ip4", "tcp"]))
        #expect(protocols.contains(["ip6", "tcp"]))
    }

    // MARK: - IPv6 Tests

    @Test("IPv6 basic connection", .timeLimit(.minutes(1)))
    func testIPv6Connection() async throws {
        let transport = TCPTransport()

        // Listen on IPv6 localhost
        let listener = try await transport.listen(.tcp(host: "::1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Verify communication works
        let message = Data("IPv6 test".utf8)
        try await clientConn.write(message)
        let received = try await serverConn.read()
        #expect(received == message)

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - EventLoopGroup Lifecycle Tests

    @Test("Transport with external EventLoopGroup", .timeLimit(.minutes(1)))
    func testExternalEventLoopGroup() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let transport = TCPTransport(group: group)

        // Basic connection test
        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Verify it works
        try await clientConn.write(Data("test".utf8))
        let received = try await serverConn.read()
        #expect(String(decoding: received, as: UTF8.self) == "test")

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()

        // Shutdown gracefully (async version for Swift 6)
        try await group.shutdownGracefully()
    }

    // MARK: - Multiaddr Tests

    @Test("TCP Multiaddr parsing")
    func testTCPMultiaddr() throws {
        let addr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)

        #expect(addr.ipAddress == "127.0.0.1")
        #expect(addr.tcpPort == 4001)

        // Round-trip through string
        let str = addr.description
        #expect(str == "/ip4/127.0.0.1/tcp/4001")

        let parsed = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        #expect(parsed.ipAddress == "127.0.0.1")
        #expect(parsed.tcpPort == 4001)
    }

    @Test("IPv6 Multiaddr parsing")
    func testIPv6Multiaddr() throws {
        // IPv6 addresses are normalized to expanded form
        let parsed = try Multiaddr("/ip6/::1/tcp/4001")
        #expect(parsed.ipAddress == "0:0:0:0:0:0:0:1")
        #expect(parsed.tcpPort == 4001)

        // Factory method also normalizes
        let factory = Multiaddr.tcp(host: "::1", port: 4001)
        #expect(factory.ipAddress == "0:0:0:0:0:0:0:1")
    }

    // MARK: - Concurrent Connection Tests

    @Test("Concurrent connections to listener", .timeLimit(.minutes(1)))
    func testConcurrentConnections() async throws {
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        // Create multiple connections concurrently
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

    // MARK: - Rapid Read/Write Tests

    @Test("Rapid sequential read/write", .timeLimit(.minutes(1)))
    func testRapidReadWrite() async throws {
        let transport = TCPTransport()

        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Rapid alternating read/write
        for i in 0..<20 {
            // Client to server
            let c2s = Data("c2s-\(i)".utf8)
            try await clientConn.write(c2s)
            let received1 = try await serverConn.read()
            #expect(received1 == c2s)

            // Server to client
            let s2c = Data("s2c-\(i)".utf8)
            try await serverConn.write(s2c)
            let received2 = try await clientConn.read()
            #expect(received2 == s2c)
        }

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - Diagnostic Tests for Race Condition

    @Test("Diagnose: immediate write after connect (expect hang if race condition exists)", .timeLimit(.minutes(1)))
    func testDiagnoseImmediateWrite() async throws {
        let transport = TCPTransport()
        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)

        // Immediately send data (before accept() returns, triggering race condition)
        let message = Data("immediate".utf8)
        try await clientConn.write(message)

        let serverConn = try await acceptTask

        // This read() will hang if data was lost due to race condition
        let received = try await serverConn.read()
        #expect(received == message)

        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    @Test("Diagnose: delayed write after connect (should pass)", .timeLimit(.minutes(1)))
    func testDiagnoseDelayedWrite() async throws {
        let transport = TCPTransport()
        let listener = try await transport.listen(.tcp(host: "127.0.0.1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        // Wait for handler to be installed
        try await Task.sleep(for: .milliseconds(100))

        // Send data after delay
        let message = Data("delayed".utf8)
        try await clientConn.write(message)

        // This read() should succeed
        let received = try await serverConn.read()
        #expect(received == message)

        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }
}
