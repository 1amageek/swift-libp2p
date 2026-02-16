import Testing
import Foundation
import NIOCore
import NIOEmbedded
import NIOWebSocket
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

    // MARK: - Buffer Overflow Tests (DoS Protection)
    // NOTE: WebSocket silently drops frames on overflow (unlike TCP which closes connection).
    // This is a design inconsistency documented in CONTEXT.md.

    @Test("WS buffer overflow silently drops frames without closing", .timeLimit(.minutes(1)))
    func testWSBufferOverflowSilentlyDropsFrames() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listener.localAddress)
        let serverConn = try await acceptTask

        // Send many frames to fill server buffer close to 1MB
        let chunk = ByteBuffer(repeating: 0xCC, count: 64 * 1024)
        for _ in 0..<16 { // 1MB exactly (fits within limit since check is >)
            try await clientConn.write(chunk)
        }
        try await Task.sleep(for: .milliseconds(200))

        // This frame should be dropped (buffer full)
        try await clientConn.write(ByteBuffer(string: "dropped"))
        try await Task.sleep(for: .milliseconds(100))

        // Drain the buffer by reading all 16 chunks
        var totalRead = 0
        while totalRead < 1024 * 1024 {
            let data = try await serverConn.read()
            totalRead += data.readableBytes
        }

        // Connection should still be alive after overflow (unlike TCP)
        let afterOverflow = ByteBuffer(string: "still alive")
        try await clientConn.write(afterOverflow)
        let received = try await serverConn.read()
        #expect(String(buffer: received) == "still alive")

        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - WebSocket Close Frame Handshake (RFC 6455)

    @Test("Close frame handshake closes both sides", .timeLimit(.minutes(1)))
    func testCloseFrameHandshake() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listener.localAddress)
        let serverConn = try await acceptTask

        // Verify communication works first
        try await clientConn.write(ByteBuffer(string: "before close"))
        let received = try await serverConn.read()
        #expect(String(buffer: received) == "before close")

        // Client sends close frame (via close())
        try await clientConn.close()
        try await Task.sleep(for: .milliseconds(100))

        // Server should see connection closed
        await #expect(throws: Error.self) {
            _ = try await serverConn.read()
        }

        try await serverConn.close()
        try await listener.close()
    }

    @Test("Server-initiated close frame handshake", .timeLimit(.minutes(1)))
    func testServerInitiatedCloseFrameHandshake() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listener.localAddress)
        let serverConn = try await acceptTask

        try await serverConn.close()
        try await Task.sleep(for: .milliseconds(100))

        await #expect(throws: Error.self) {
            _ = try await clientConn.read()
        }

        try await clientConn.close()
        try await listener.close()
    }

    // MARK: - Ping/Pong Auto-Response (RFC 6455, EmbeddedChannel)

    @Test("Ping auto-responds with pong (server mode)", .timeLimit(.minutes(1)))
    func testPingPongAutoResponse() async throws {
        let channel = EmbeddedChannel()
        let handler = WebSocketFrameHandler(isClient: false)
        try await channel.pipeline.addHandler(handler)

        // Inject a ping frame
        let pingData = ByteBuffer(string: "ping-payload")
        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: pingData)
        try channel.writeInbound(pingFrame)

        // Read outbound: should be a pong
        let pongFrame = try channel.readOutbound(as: WebSocketFrame.self)
        #expect(pongFrame != nil)
        #expect(pongFrame!.opcode == .pong)
        #expect(pongFrame!.maskKey == nil) // server frames are NOT masked
        var pongData = pongFrame!.data
        #expect(pongData.readString(length: pongData.readableBytes) == "ping-payload")

        try await channel.close()
    }

    @Test("Client-side pong response is masked", .timeLimit(.minutes(1)))
    func testPingPongClientSideMasked() async throws {
        let channel = EmbeddedChannel()
        let handler = WebSocketFrameHandler(isClient: true)
        try await channel.pipeline.addHandler(handler)

        let pingData = ByteBuffer(string: "masked-ping")
        let pingFrame = WebSocketFrame(fin: true, opcode: .ping, data: pingData)
        try channel.writeInbound(pingFrame)

        let pongFrame = try channel.readOutbound(as: WebSocketFrame.self)
        #expect(pongFrame != nil)
        #expect(pongFrame!.opcode == .pong)
        #expect(pongFrame!.maskKey != nil) // client frames MUST be masked (RFC 6455)

        try await channel.close()
    }

    // MARK: - Text Frame Handling (EmbeddedChannel)

    @Test("Text frame is delivered as data", .timeLimit(.minutes(1)))
    func testTextFrameDeliveredAsData() async throws {
        let channel = EmbeddedChannel()
        let handler = WebSocketFrameHandler(isClient: false)
        try await channel.pipeline.addHandler(handler)

        let connection = WebSocketConnection(
            channel: channel,
            isClient: false,
            localAddress: nil,
            remoteAddress: .ws(host: "127.0.0.1", port: 1234)
        )
        handler.setConnection(connection)

        // Send text frame (opcode .text)
        let textData = ByteBuffer(string: "hello text frame")
        let textFrame = WebSocketFrame(fin: true, opcode: .text, data: textData)
        try channel.writeInbound(textFrame)

        let received = try await connection.read()
        #expect(String(buffer: received) == "hello text frame")

        try await channel.close()
    }

    // MARK: - RFC 6455 Masking Behavior (EmbeddedChannel)

    @Test("Client write produces masked frames", .timeLimit(.minutes(1)))
    func testClientWriteMasksFrames() async throws {
        let channel = EmbeddedChannel()
        let handler = WebSocketFrameHandler(isClient: true)
        try await channel.pipeline.addHandler(handler)

        let connection = WebSocketConnection(
            channel: channel,
            isClient: true,
            localAddress: nil,
            remoteAddress: .ws(host: "127.0.0.1", port: 5555)
        )
        handler.setConnection(connection)

        let data = ByteBuffer(string: "masked data")
        try await connection.write(data)

        // Read outbound frame
        let frame = try channel.readOutbound(as: WebSocketFrame.self)
        #expect(frame != nil)
        #expect(frame!.opcode == .binary)
        #expect(frame!.maskKey != nil) // Client frames MUST be masked

        try await channel.close()
    }

    @Test("Server write produces unmasked frames", .timeLimit(.minutes(1)))
    func testServerWriteDoesNotMaskFrames() async throws {
        let channel = EmbeddedChannel()
        let handler = WebSocketFrameHandler(isClient: false)
        try await channel.pipeline.addHandler(handler)

        let connection = WebSocketConnection(
            channel: channel,
            isClient: false,
            localAddress: nil,
            remoteAddress: .ws(host: "127.0.0.1", port: 5556)
        )
        handler.setConnection(connection)

        let data = ByteBuffer(string: "unmasked data")
        try await connection.write(data)

        let frame = try channel.readOutbound(as: WebSocketFrame.self)
        #expect(frame != nil)
        #expect(frame!.opcode == .binary)
        #expect(frame!.maskKey == nil) // Server frames MUST NOT be masked

        try await channel.close()
    }

    // MARK: - Idempotent Close

    @Test("WS double close is idempotent", .timeLimit(.minutes(1)))
    func testWSIdempotentClose() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listener.localAddress)
        _ = try await acceptTask

        try await clientConn.close()
        try await clientConn.close() // Must not throw

        try await listener.close()
    }

    // MARK: - Concurrent Read Waiters

    @Test("WS concurrent reads are served FIFO", .timeLimit(.minutes(1)))
    func testWSConcurrentReadsFIFO() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listener.localAddress)
        let serverConn = try await acceptTask

        let read1 = Task { try await serverConn.read() }
        try await Task.sleep(for: .milliseconds(10))
        let read2 = Task { try await serverConn.read() }
        try await Task.sleep(for: .milliseconds(10))
        let read3 = Task { try await serverConn.read() }
        try await Task.sleep(for: .milliseconds(10))

        try await clientConn.write(ByteBuffer(string: "ws-1"))
        try await Task.sleep(for: .milliseconds(10))
        try await clientConn.write(ByteBuffer(string: "ws-2"))
        try await Task.sleep(for: .milliseconds(10))
        try await clientConn.write(ByteBuffer(string: "ws-3"))

        let r1 = try await read1.value
        let r2 = try await read2.value
        let r3 = try await read3.value

        #expect(String(buffer: r1) == "ws-1")
        #expect(String(buffer: r2) == "ws-2")
        #expect(String(buffer: r3) == "ws-3")

        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - IPv6 WebSocket

    @Test("IPv6 WebSocket connection", .timeLimit(.minutes(1)))
    func testWSIPv6Connection() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "::1", port: 0))
        let listenAddr = listener.localAddress

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listenAddr)
        let serverConn = try await acceptTask

        let message = ByteBuffer(string: "IPv6 WS test")
        try await clientConn.write(message)
        let received = try await serverConn.read()
        #expect(String(buffer: received) == "IPv6 WS test")

        try await clientConn.close()
        try await serverConn.close()
        try await listener.close()
    }

    // MARK: - Handler Late Binding Tests (EmbeddedChannel)

    @Test("WS handler buffers data before connection is set", .timeLimit(.minutes(1)))
    func testWSHandlerBuffersDataBeforeConnectionSet() async throws {
        let channel = EmbeddedChannel()
        let handler = WebSocketFrameHandler(isClient: false)
        try await channel.pipeline.addHandler(handler)

        // Send a binary frame before setting connection
        let data = ByteBuffer(string: "early ws data")
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: data)
        try channel.writeInbound(frame)

        // Now set connection
        let connection = WebSocketConnection(
            channel: channel,
            isClient: false,
            localAddress: nil,
            remoteAddress: .ws(host: "127.0.0.1", port: 7777)
        )
        handler.setConnection(connection)

        let received = try await connection.read()
        #expect(String(buffer: received) == "early ws data")

        try await channel.close()
    }

    // MARK: - Listener Close Resource Cleanup

    @Test("WS listener close cleans up pending connections", .timeLimit(.minutes(1)))
    func testWSListenerCloseCleansPendingConnections() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))

        // Dial but do NOT accept
        let clientConn = try await transport.dial(listener.localAddress)
        try await Task.sleep(for: .milliseconds(200))

        // Close listener (should close pending connections)
        try await listener.close()
        try await Task.sleep(for: .milliseconds(100))

        await #expect(throws: Error.self) {
            _ = try await clientConn.read()
        }
    }

    // MARK: - Error Handler (EmbeddedChannel)

    @Test("WS errorCaught triggers connection close", .timeLimit(.minutes(1)))
    func testWSErrorCaughtClosesConnection() async throws {
        let channel = EmbeddedChannel()
        let handler = WebSocketFrameHandler(isClient: false)
        try await channel.pipeline.addHandler(handler)

        let connection = WebSocketConnection(
            channel: channel,
            isClient: false,
            localAddress: nil,
            remoteAddress: .ws(host: "127.0.0.1", port: 8888)
        )
        handler.setConnection(connection)

        struct TestError: Error {}
        channel.pipeline.fireErrorCaught(TestError())

        await #expect(throws: TransportError.self) {
            _ = try await connection.read()
        }
    }

    // MARK: - Buffer Then Error on Close

    @Test("WS read returns buffered data then error on close", .timeLimit(.minutes(1)))
    func testWSReadReturnsBufferThenErrorOnClose() async throws {
        let transport = WebSocketTransport()
        let listener = try await transport.listen(.ws(host: "127.0.0.1", port: 0))

        async let acceptTask = listener.accept()
        let clientConn = try await transport.dial(listener.localAddress)
        let serverConn = try await acceptTask

        let message = ByteBuffer(string: "ws last message")
        try await clientConn.write(message)
        try await Task.sleep(for: .milliseconds(100))

        try await clientConn.close()
        try await Task.sleep(for: .milliseconds(100))

        // First read: buffered data
        let received = try await serverConn.read()
        #expect(String(buffer: received) == "ws last message")

        // Second read: error
        await #expect(throws: Error.self) {
            _ = try await serverConn.read()
        }

        try await serverConn.close()
        try await listener.close()
    }
}
