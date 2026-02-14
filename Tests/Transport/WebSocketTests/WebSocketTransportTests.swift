import Testing
import Foundation
import NIOCore
import NIOSSL
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
            try await clientConn.write(ByteBuffer(bytes: message))
            let received = try await serverConn.read()
            #expect(String(buffer: received) == "message \(i)")
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
        try await clientConn.write(ByteBuffer(bytes: largeMessage))

        // WebSocket delivers full frames, so a single read should return all data
        let received = try await serverConn.read()
        #expect(Data(buffer: received) == largeMessage)

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
            try await clientConn.write(ByteBuffer(bytes: message))
            let received = try await serverConn.read()
            #expect(String(buffer: received) == "conn \(i)")
        }

        // Clean up
        for conn in clientConns + serverConns {
            do {
                try await conn.close()
            } catch {
                Issue.record("Failed to close connection during cleanup: \(error)")
            }
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
            do {
                try await conn.close()
            } catch {
                Issue.record("Failed to close connection during cleanup: \(error)")
            }
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
            try await clientConn.write(ByteBuffer(bytes: Data("should fail".utf8)))
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
        try await clientConn.write(ByteBuffer(bytes: message))

        // Small delay to ensure data is buffered on server side
        try await Task.sleep(for: .milliseconds(50))

        // Server should receive the data
        let received = try await serverConn.read()
        #expect(Data(buffer: received) == message)

        // Clean up
        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - Address Tests

    @Test("canDial returns true for WS addresses", .timeLimit(.minutes(1)))
    func testCanDialWS() {
        let transport = WebSocketTransport()
        let peerID = KeyPair.generateEd25519().peerID

        #expect(transport.canDial(.ws(host: "127.0.0.1", port: 4001)))
        #expect(transport.canDial(.ws(host: "192.168.1.1", port: 80)))
        #expect(transport.canDial(Multiaddr(uncheckedProtocols: [.dns4("localhost"), .tcp(4001), .ws])))
        #expect(transport.canDial(Multiaddr(uncheckedProtocols: [.dns("example.com"), .tcp(80), .ws])))
        #expect(transport.canDial(Multiaddr(uncheckedProtocols: [.ip4("127.0.0.1"), .tcp(4001), .ws, .p2p(peerID)])))
        // TCP-only (no /ws) should fail
        #expect(!transport.canDial(.tcp(host: "127.0.0.1", port: 4001)))
        // Memory should fail
        #expect(!transport.canDial(.memory(id: "test")))
    }

    @Test("canListen returns true for WS addresses", .timeLimit(.minutes(1)))
    func testCanListenWS() {
        let transport = WebSocketTransport()
        let peerID = KeyPair.generateEd25519().peerID

        #expect(transport.canListen(.ws(host: "0.0.0.0", port: 4001)))
        #expect(transport.canListen(.ws(host: "127.0.0.1", port: 0)))
        #expect(!transport.canListen(Multiaddr(uncheckedProtocols: [.dns4("localhost"), .tcp(4001), .ws])))
        #expect(!transport.canListen(Multiaddr(uncheckedProtocols: [.ip4("127.0.0.1"), .tcp(4001), .ws, .p2p(peerID)])))
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
        #expect(protocols.contains(["dns", "tcp", "ws"]))
        #expect(protocols.contains(["dns4", "tcp", "ws"]))
        #expect(protocols.contains(["dns6", "tcp", "ws"]))
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

    // MARK: - WSS (Secure WebSocket) Tests

    @Test("protocols property includes WSS protocols")
    func testProtocolsIncludesWSS() {
        let transport = WebSocketTransport()
        let protocols = transport.protocols

        #expect(protocols.contains(["ip4", "tcp", "wss"]))
        #expect(protocols.contains(["ip6", "tcp", "wss"]))
        #expect(protocols.contains(["dns", "tcp", "wss"]))
        #expect(protocols.contains(["dns4", "tcp", "wss"]))
        #expect(protocols.contains(["dns6", "tcp", "wss"]))
        // Note: /tls/ws format is NOT supported because `tls` is not a valid
        // Multiaddr protocol. Use /wss format instead.
    }

    @Test("canDial allows WSS only for DNS hostnames")
    func testCanDialWSS() {
        let transport = WebSocketTransport()

        // IP literal WSS is rejected to preserve hostname verification semantics.
        let wssAddr = Multiaddr.wss(host: "127.0.0.1", port: 443)
        #expect(!transport.canDial(wssAddr))

        // IPv6 literal WSS is also rejected.
        let wss6Addr = Multiaddr.wss(host: "::1", port: 443)
        #expect(!transport.canDial(wss6Addr))

        // DNS WSS
        let dnsWss = Multiaddr(uncheckedProtocols: [.dns4("localhost"), .tcp(443), .wss])
        #expect(transport.canDial(dnsWss))
    }

    @Test("canListen returns false for WSS addresses without server TLS configuration")
    func testCanListenWSS() {
        let transport = WebSocketTransport()

        #expect(!transport.canListen(Multiaddr.wss(host: "0.0.0.0", port: 443)))
        #expect(!transport.canListen(Multiaddr.wss(host: "127.0.0.1", port: 0)))
        #expect(!transport.canListen(Multiaddr(uncheckedProtocols: [.dns4("localhost"), .tcp(443), .wss])))
    }

    @Test("Listen WSS without server TLS configuration throws explicit error", .timeLimit(.minutes(1)))
    func testListenWSSRequiresServerTLSConfiguration() async throws {
        let transport = WebSocketTransport()

        do {
            _ = try await transport.listen(.wss(host: "127.0.0.1", port: 0))
            Issue.record("Expected secureListenerRequiresServerTLSConfiguration")
        } catch let error as WebSocketTransportError {
            if case .secureListenerRequiresServerTLSConfiguration = error {
                // Expected
            } else {
                Issue.record("Expected secureListenerRequiresServerTLSConfiguration, got \(error)")
            }
        }
    }

    @Test("Dial WSS rejects insecure client TLS configuration", .timeLimit(.minutes(1)))
    func testDialWSSRejectsInsecureClientTLSConfiguration() async throws {
        var insecureClient = TLSConfiguration.makeClientConfiguration()
        insecureClient.certificateVerification = .none

        let transport = WebSocketTransport(
            tlsConfiguration: .init(client: insecureClient)
        )

        #expect(!transport.canDial(.wss(host: "127.0.0.1", port: 443)))

        do {
            _ = try await transport.dial(.wss(host: "127.0.0.1", port: 443))
            Issue.record("Expected insecureClientTLSConfiguration")
        } catch let error as WebSocketTransportError {
            if case .insecureClientTLSConfiguration = error {
                // Expected
            } else {
                Issue.record("Expected insecureClientTLSConfiguration, got \(error)")
            }
        }
    }

    @Test("Dial WSS rejects no-hostname-verification client TLS configuration", .timeLimit(.minutes(1)))
    func testDialWSSRejectsNoHostnameVerificationTLSConfiguration() async throws {
        var insecureClient = TLSConfiguration.makeClientConfiguration()
        insecureClient.certificateVerification = .noHostnameVerification

        let transport = WebSocketTransport(
            tlsConfiguration: .init(client: insecureClient)
        )

        let dnsAddress = Multiaddr(uncheckedProtocols: [.dns4("localhost"), .tcp(443), .wss])
        #expect(!transport.canDial(dnsAddress))

        do {
            _ = try await transport.dial(dnsAddress)
            Issue.record("Expected insecureClientTLSConfiguration")
        } catch let error as WebSocketTransportError {
            if case .insecureClientTLSConfiguration = error {
                // Expected
            } else {
                Issue.record("Expected insecureClientTLSConfiguration, got \(error)")
            }
        }
    }

    @Test("WSS Multiaddr factory")
    func testWSSMultiaddrFactory() {
        let addr = Multiaddr.wss(host: "127.0.0.1", port: 443)

        #expect(addr.ipAddress == "127.0.0.1")
        #expect(addr.tcpPort == 443)
        #expect(addr.description == "/ip4/127.0.0.1/tcp/443/wss")

        let hasWSS = addr.protocols.contains(where: { if case .wss = $0 { return true } else { return false } })
        #expect(hasWSS)

        // IPv6 variant
        let addr6 = Multiaddr.wss(host: "::1", port: 443)
        #expect(addr6.tcpPort == 443)
        let hasWSS6 = addr6.protocols.contains(where: { if case .wss = $0 { return true } else { return false } })
        #expect(hasWSS6)
    }

    @Test("Dial WSS to non-existent DNS server throws connection error", .timeLimit(.minutes(1)))
    func testDialWSSConnectionRefused() async throws {
        let transport = WebSocketTransport()
        let addr = Multiaddr(uncheckedProtocols: [.dns4("localhost"), .tcp(59999), .wss])

        await #expect(throws: Error.self) {
            _ = try await transport.dial(addr)
        }
    }

    @Test("Dial WSS with IP literal is rejected", .timeLimit(.minutes(1)))
    func testDialWSSWithIPLiteralRejected() async throws {
        let transport = WebSocketTransport()

        do {
            _ = try await transport.dial(.wss(host: "127.0.0.1", port: 443))
            Issue.record("Expected secureDialRequiresDNSHostname")
        } catch let error as WebSocketTransportError {
            if case .secureDialRequiresDNSHostname = error {
                // Expected
            } else {
                Issue.record("Expected secureDialRequiresDNSHostname, got \(error)")
            }
        }
    }

    @Test("Dial WS supports dns4 hostname addresses", .timeLimit(.minutes(1)))
    func testDialWSSupportsDNS4Hostname() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))
        let port = listener.localAddress.tcpPort

        guard let port else {
            Issue.record("Expected listener tcp port")
            try await listener.close()
            return
        }

        let dnsAddress = Multiaddr(uncheckedProtocols: [.dns4("localhost"), .tcp(port), .ws])

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(dnsAddress)
        let serverConn = try await acceptTask

        let payload = Data("ws-dns-hostname".utf8)
        try await clientConn.write(ByteBuffer(bytes: payload))
        let read = try await serverConn.read()
        #expect(Data(buffer: read) == payload)

        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }
}
