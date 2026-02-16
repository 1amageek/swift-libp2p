import Testing
import Foundation
import NIOCore
@testable import P2PCore
@testable import P2PTransport
@testable import P2PTransportMemory

@Suite("Memory Transport Tests", .serialized)
struct MemoryTransportTests {

    // MARK: - Basic Connection Tests

    @Test("Basic dial and listen")
    func testBasicConnection() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        // Start listener
        let listener = try await transport.listen(.memory(id: "server"))
        #expect(listener.localAddress.memoryID == "server")

        // Dial and accept concurrently
        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(.memory(id: "server"))
        let serverConn = try await acceptTask

        // Verify addresses
        #expect(clientConn.remoteAddress.memoryID == "server")
        #expect(serverConn.remoteAddress.memoryID != "server") // dialer's synthetic address

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    @Test("Bidirectional communication")
    func testBidirectionalCommunication() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "echo"))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(.memory(id: "echo"))
        let serverConn = try await acceptTask

        // Client sends to server
        let clientMessage = Data("hello from client".utf8)
        try await clientConn.write(ByteBuffer(bytes: clientMessage))
        let receivedAtServer = try await serverConn.read()
        #expect(Data(buffer: receivedAtServer) == clientMessage)

        // Server sends to client
        let serverMessage = Data("hello from server".utf8)
        try await serverConn.write(ByteBuffer(bytes: serverMessage))
        let receivedAtClient = try await clientConn.read()
        #expect(Data(buffer: receivedAtClient) == serverMessage)

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    @Test("Multiple messages in sequence")
    func testMultipleMessages() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "multi"))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(.memory(id: "multi"))
        let serverConn = try await acceptTask

        // Send multiple messages
        for i in 1...5 {
            let message = Data("message \(i)".utf8)
            try await clientConn.write(ByteBuffer(bytes: message))
            let received = try await serverConn.read()
            #expect(String(buffer: received) == "message \(i)")
        }

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - Multiple Connections Tests

    @Test("Multiple connections to same listener")
    func testMultipleConnections() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "multi-conn"))

        // Create 3 connections
        var clientConns: [any RawConnection] = []
        var serverConns: [any RawConnection] = []

        for i in 0..<3 {
            async let acceptTask = listener.accept()
            let clientConn = try await transport.dial(.memory(id: "multi-conn"))
            let serverConn = try await acceptTask

            clientConns.append(clientConn)
            serverConns.append(serverConn)

            // Verify each connection works
            let message = Data("conn \(i)".utf8)
            try await clientConn.write(ByteBuffer(bytes: message))
            let received = try await serverConn.read()
            #expect(String(buffer: received) == "conn \(i)")
        }

        // Clean up
        for conn in clientConns + serverConns {
            try? await conn.close()
        }
        try await listener.close()
    }

    @Test("Multiple listeners on different addresses")
    func testMultipleListeners() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener1 = try await transport.listen(.memory(id: "server-1"))
        let listener2 = try await transport.listen(.memory(id: "server-2"))

        // Connect to each
        async let accept1 = listener1.accept()
        let conn1 = try await transport.dial(.memory(id: "server-1"))
        let server1 = try await accept1

        async let accept2 = listener2.accept()
        let conn2 = try await transport.dial(.memory(id: "server-2"))
        let server2 = try await accept2

        // Verify isolation
        try await conn1.write(ByteBuffer(bytes: Data("to-1".utf8)))
        try await conn2.write(ByteBuffer(bytes: Data("to-2".utf8)))

        let received1 = try await server1.read()
        let received2 = try await server2.read()

        #expect(String(buffer: received1) == "to-1")
        #expect(String(buffer: received2) == "to-2")

        // Clean up
        try await conn1.close()
        try await conn2.close()
        try await server1.close()
        try await server2.close()
        try await listener1.close()
        try await listener2.close()
    }

    // MARK: - Close Behavior Tests

    @Test("Connection close propagates EOF")
    func testClosePropagatesEOF() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "close-test"))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(.memory(id: "close-test"))
        let serverConn = try await acceptTask

        // Close client side
        try await clientConn.close()

        // Server should receive empty data (EOF)
        let received = try await serverConn.read()
        #expect(received.readableBytes == 0)

        // Clean up
        try await serverConn.close()
        try await listener.close()
    }

    @Test("Write after close throws error")
    func testWriteAfterClose() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "write-after-close"))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(.memory(id: "write-after-close"))
        _ = try await acceptTask

        // Close and try to write
        try await clientConn.close()

        await #expect(throws: TransportError.self) {
            try await clientConn.write(ByteBuffer(bytes: Data("should fail".utf8)))
        }

        try await listener.close()
    }

    @Test("Listener close rejects pending accept")
    func testListenerCloseRejectsPendingAccept() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "listener-close"))

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

    // MARK: - Error Handling Tests

    @Test("Dial to non-existent listener fails")
    func testDialToNonExistentListener() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        await #expect(throws: TransportError.self) {
            _ = try await transport.dial(.memory(id: "does-not-exist"))
        }
    }

    @Test("Listen on same address twice fails")
    func testDuplicateListenerFails() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        // Must hold strong reference to the listener
        let listener1 = try await transport.listen(.memory(id: "duplicate"))
        _ = listener1  // Silence unused warning

        await #expect(throws: TransportError.self) {
            _ = try await transport.listen(.memory(id: "duplicate"))
        }
    }

    // MARK: - canDial/canListen Tests

    @Test("canDial returns true for memory addresses")
    func testCanDialMemory() {
        let transport = MemoryTransport(hub: MemoryHub())

        #expect(transport.canDial(.memory(id: "test")))
        #expect(!transport.canDial(.tcp(host: "127.0.0.1", port: 4001)))
    }

    @Test("canListen returns true for memory addresses")
    func testCanListenMemory() {
        let transport = MemoryTransport(hub: MemoryHub())

        #expect(transport.canListen(.memory(id: "test")))
        #expect(!transport.canListen(.tcp(host: "127.0.0.1", port: 4001)))
    }

    // MARK: - Hub Tests

    @Test("Hub reset clears all listeners")
    func testHubReset() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        // Must hold strong references to listeners
        let listener1 = try await transport.listen(.memory(id: "server-1"))
        let listener2 = try await transport.listen(.memory(id: "server-2"))
        _ = (listener1, listener2)  // Silence unused warnings

        #expect(hub.listenerCount == 2)

        hub.reset()

        #expect(hub.listenerCount == 0)

        // Should be able to listen on same addresses again
        let listener3 = try await transport.listen(.memory(id: "server-1"))
        _ = listener3  // Silence unused warning
        #expect(hub.listenerCount == 1)
    }

    @Test("Isolated hubs don't share listeners")
    func testIsolatedHubs() async throws {
        let hub1 = MemoryHub()
        let hub2 = MemoryHub()

        let transport1 = MemoryTransport(hub: hub1)
        let transport2 = MemoryTransport(hub: hub2)

        // Listen on same ID in different hubs - must hold strong references
        let listener1 = try await transport1.listen(.memory(id: "same-id"))
        let listener2 = try await transport2.listen(.memory(id: "same-id"))
        _ = (listener1, listener2)  // Silence unused warnings

        // Neither should see the other
        #expect(hub1.listenerCount == 1)
        #expect(hub2.listenerCount == 1)

        // Create a new hub to verify isolation
        let hub3 = MemoryHub()
        await #expect(throws: TransportError.self) {
            // A new hub has no listeners, so dial should fail
            _ = try await MemoryTransport(hub: hub3).dial(.memory(id: "same-id"))
        }
    }

    // MARK: - Multiaddr Tests

    @Test("Memory Multiaddr encoding/decoding")
    func testMemoryMultiaddr() throws {
        let addr = Multiaddr.memory(id: "test-server")

        #expect(addr.description == "/memory/test-server")
        #expect(addr.memoryID == "test-server")

        // Round-trip through string
        let parsed = try Multiaddr("/memory/test-server")
        #expect(parsed == addr)
        #expect(parsed.memoryID == "test-server")

        // Round-trip through bytes
        let fromBytes = try Multiaddr(bytes: addr.bytes)
        #expect(fromBytes == addr)
    }

    // MARK: - Remote Close Detection Tests

    @Test("Write after remote close throws error")
    func testWriteAfterRemoteClose() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "remote-close-test"))
        let clientConn = try await transport.dial(.memory(id: "remote-close-test"))
        let serverConn = try await listener.accept()

        // Server closes the connection
        try await serverConn.close()

        // Client should get an error when trying to write
        await #expect(throws: TransportError.self) {
            try await clientConn.write(ByteBuffer(bytes: Data("after close".utf8)))
        }
    }

    // MARK: - Concurrent Access Detection Tests

    @Test("Concurrent reads throw error")
    func testConcurrentReadsThrowError() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "concurrent-read-test"))
        let clientConn = try await transport.dial(.memory(id: "concurrent-read-test"))
        _ = try await listener.accept()

        // Start first read (will wait for data)
        let firstReadTask = Task {
            try await clientConn.read()
        }

        // Give the first read time to start waiting
        try await Task.sleep(for: .milliseconds(10))

        // Second read should throw error
        await #expect(throws: TransportError.self) {
            try await clientConn.read()
        }

        // Clean up: cancel the waiting task
        firstReadTask.cancel()
    }

    @Test("Concurrent accepts throw error")
    func testConcurrentAcceptsThrowError() async throws {
        let hub = MemoryHub()
        let transport = MemoryTransport(hub: hub)

        let listener = try await transport.listen(.memory(id: "concurrent-accept-test"))

        // Start first accept (will wait for connection)
        let firstAcceptTask = Task {
            try await listener.accept()
        }

        // Give the first accept time to start waiting
        try await Task.sleep(for: .milliseconds(10))

        // Second accept should throw error
        await #expect(throws: TransportError.self) {
            try await listener.accept()
        }

        // Clean up: close listener to cancel waiting task
        try await listener.close()
        _ = try? await firstAcceptTask.value
    }
}
