/// Tests for WebRTCUDPSocket
///
/// Uses NIO's EmbeddedChannel to verify routing-table behavior and the
/// channel-error teardown path without real network I/O.

import Testing
import Foundation
import NIOCore
import NIOEmbedded
import Synchronization
@testable import P2PTransportWebRTC
@testable import WebRTC

@Suite("WebRTC UDP Socket Tests")
struct WebRTCUDPSocketTests {

    private struct TestChannelError: Error {}

    private func makeConnection() throws -> WebRTCConnection {
        let cert = try WebRTCCertificate.generateSelfSigned()
        return WebRTCConnection.asServer(certificate: cert, sendHandler: { _ in })
    }

    @Test("handleChannelError closes the NIO channel")
    func channelErrorClosesChannel() throws {
        let channel = EmbeddedChannel()
        let socket = WebRTCUDPSocket(channel: channel)

        let closed = Mutex(false)
        channel.closeFuture.whenComplete { _ in closed.withLock { $0 = true } }

        socket.handleChannelError(TestChannelError())
        // Flush the embedded event loop so the queued close is processed
        channel.embeddedEventLoop.run()
        #expect(closed.withLock { $0 })

        // Subsequent error and close() must be no-ops, not double-closes
        socket.handleChannelError(TestChannelError())
        socket.close()
    }

    @Test("handleChannelError closes all routed connections")
    func channelErrorClosesRoutedConnections() throws {
        let channel = EmbeddedChannel()
        let socket = WebRTCUDPSocket(channel: channel)
        let conn1 = try makeConnection()
        let conn2 = try makeConnection()
        socket.addRoute(
            remoteAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 1111),
            connection: conn1
        )
        socket.addRoute(
            remoteAddress: try SocketAddress(ipAddress: "127.0.0.1", port: 2222),
            connection: conn2
        )

        socket.handleChannelError(TestChannelError())

        guard case .closed = conn1.state else {
            Issue.record("conn1 should be closed, got \(conn1.state)")
            return
        }
        guard case .closed = conn2.state else {
            Issue.record("conn2 should be closed, got \(conn2.state)")
            return
        }
    }

    @Test("addRoute is rejected after the socket is closed")
    func addRouteAfterCloseIsRejected() throws {
        let channel = EmbeddedChannel()
        let socket = WebRTCUDPSocket(channel: channel)
        let conn = try makeConnection()
        let addr = try SocketAddress(ipAddress: "127.0.0.1", port: 3333)

        #expect(socket.addRoute(remoteAddress: addr, connection: conn))
        socket.close()
        #expect(!socket.addRoute(remoteAddress: addr, connection: conn))
    }

    @Test("terminal connection's route is removed on receive failure")
    func terminalReceiveRemovesRoute() throws {
        let channel = EmbeddedChannel()
        let socket = WebRTCUDPSocket(channel: channel)
        let conn = try makeConnection()
        conn.close() // terminal: receive() now throws

        let addr = try SocketAddress(ipAddress: "127.0.0.1", port: 4444)
        socket.addRoute(remoteAddress: addr, connection: conn)

        let newPeerCalls = Mutex(0)
        socket.setOnNewPeer { _ in newPeerCalls.withLock { $0 += 1 } }

        // Fast path: receive throws, the route is dropped without
        // treating the sender as a new peer
        socket.handleDatagram(from: addr, data: Data([0x16, 0x00]))
        #expect(newPeerCalls.withLock { $0 } == 0)

        // The route is gone: the next datagram takes the new-peer path
        socket.handleDatagram(from: addr, data: Data([0x16, 0x00]))
        #expect(newPeerCalls.withLock { $0 } == 1)
    }

    @Test("removeRoute(for:) removes only the matching connection")
    func removeRouteByIdentity() throws {
        let channel = EmbeddedChannel()
        let socket = WebRTCUDPSocket(channel: channel)
        let conn1 = try makeConnection()
        let conn2 = try makeConnection()
        let addr1 = try SocketAddress(ipAddress: "127.0.0.1", port: 5555)
        let addr2 = try SocketAddress(ipAddress: "127.0.0.1", port: 6666)
        socket.addRoute(remoteAddress: addr1, connection: conn1)
        socket.addRoute(remoteAddress: addr2, connection: conn2)

        socket.removeRoute(for: conn1)

        let newPeers = Mutex<[String]>([])
        socket.setOnNewPeer { address in
            newPeers.withLock { $0.append(address.addressKey) }
        }

        // addr1 lost its route; addr2 is still routed to conn2
        socket.handleDatagram(from: addr1, data: Data([0xFF]))
        socket.handleDatagram(from: addr2, data: Data([0xFF]))
        #expect(newPeers.withLock { $0 } == [addr1.addressKey])
    }
}
