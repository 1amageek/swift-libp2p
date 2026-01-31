/// WebRTC UDP Socket
///
/// Manages a NIO DatagramChannel and routes incoming UDP datagrams
/// to the appropriate WebRTCConnection based on remote address.
///
/// Two modes:
/// - Dial mode (1:1): All datagrams route to a single connection.
/// - Listen mode (1:N): Routing table maps remote address → connection.
///   Unknown peers trigger the onNewPeer callback, which creates a new
///   connection via WebRTCListener.acceptConnection().

import Foundation
import Synchronization
import NIOCore
import WebRTC

/// UDP socket manager with address-based routing.
final class WebRTCUDPSocket: Sendable {

    private let channel: any NIOCore.Channel
    private let routingState: Mutex<RoutingState>

    struct RoutingState: Sendable {
        /// Maps remote address key ("host:port") to WebRTCConnection.
        var routes: [String: WebRTCConnection] = [:]
        /// Callback for unknown peers (listen mode only).
        /// Set via `setOnNewPeer` after construction.
        var onNewPeer: (@Sendable (SocketAddress) -> Void)?
        var isClosed: Bool = false
    }

    /// The local address of the bound UDP socket.
    var localAddress: SocketAddress? { channel.localAddress }

    /// Creates a UDP socket manager.
    ///
    /// - Parameter channel: The NIO DatagramChannel.
    init(channel: any NIOCore.Channel) {
        self.channel = channel
        self.routingState = Mutex(RoutingState())
    }

    /// Sets the callback for unknown peers (listen mode).
    ///
    /// Called when a datagram arrives from an address not in the routing table.
    /// Must be called before datagrams arrive for correct behavior.
    func setOnNewPeer(_ callback: @escaping @Sendable (SocketAddress) -> Void) {
        routingState.withLock { $0.onNewPeer = callback }
    }

    /// Registers a connection for the given remote address.
    func addRoute(remoteAddress: SocketAddress, connection: WebRTCConnection) {
        let key = remoteAddress.addressKey
        routingState.withLock { $0.routes[key] = connection }
    }

    /// Removes the route for the given remote address.
    func removeRoute(remoteAddress: SocketAddress) {
        let key = remoteAddress.addressKey
        routingState.withLock { _ = $0.routes.removeValue(forKey: key) }
    }

    /// Removes the route entry whose connection matches the given reference.
    ///
    /// Used for cleanup when a MuxedConnection closes in listen mode.
    /// Uses ObjectIdentifier for identity comparison (WebRTCConnection is a reference type).
    func removeRoute(for connection: WebRTCConnection) {
        let target = ObjectIdentifier(connection)
        routingState.withLock { state in
            state.routes = state.routes.filter { _, conn in
                ObjectIdentifier(conn) != target
            }
        }
    }

    /// Creates a SendHandler that writes UDP datagrams to the given remote address.
    ///
    /// The returned closure captures the channel and remote address,
    /// and writes each Data payload as an AddressedEnvelope.
    ///
    /// Thread safety: NIO Channel.writeAndFlush is thread-safe per NIO documentation.
    /// All Channel methods can be called from any thread. This is consistent with
    /// TCPConnection.write() which also calls channel.writeAndFlush directly.
    func makeSendHandler(remoteAddress: SocketAddress) -> WebRTCConnection.SendHandler {
        let channel = self.channel
        return { data in
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let envelope = AddressedEnvelope(remoteAddress: remoteAddress, data: buffer)
            channel.writeAndFlush(envelope, promise: nil)
        }
    }

    /// Handles an incoming UDP datagram by routing it to the appropriate connection.
    ///
    /// If the remote address is known, delivers to the existing connection.
    /// If unknown and onNewPeer is set (listen mode), calls onNewPeer to create
    /// a new connection, then re-checks the routing table to deliver the first datagram.
    func handleDatagram(from remoteAddress: SocketAddress, data: Data) {
        let key = remoteAddress.addressKey

        // Single lock: check route AND get onNewPeer
        let (existingConnection, onNewPeer) = routingState.withLock { state in
            (state.routes[key], state.onNewPeer)
        }

        // Fast path: known peer
        if let connection = existingConnection {
            do {
                try connection.receive(data)
            } catch {
                routingState.withLock { _ = $0.routes.removeValue(forKey: key) }
            }
            return
        }

        // Slow path: unknown peer in listen mode
        guard let onNewPeer else { return }
        onNewPeer(remoteAddress)

        // After onNewPeer, the listener should have registered a route.
        // Re-check and deliver the first datagram.
        let newConnection = routingState.withLock { $0.routes[key] }
        if let connection = newConnection {
            do {
                try connection.receive(data)
            } catch {
                routingState.withLock { _ = $0.routes.removeValue(forKey: key) }
            }
        }
    }

    /// Called when the NIO channel encounters an error.
    ///
    /// Marks the socket as closed and clears routes.
    /// Connections will learn about the error on their next operation.
    func handleChannelError(_ error: Error) {
        routingState.withLock { state in
            state.isClosed = true
            state.routes.removeAll()
        }
    }

    /// Closes the UDP socket and marks it as closed.
    func close() {
        let alreadyClosed = routingState.withLock { state -> Bool in
            if state.isClosed { return true }
            state.isClosed = true
            state.routes.removeAll()
            return false
        }
        guard !alreadyClosed else { return }
        channel.close(promise: nil)
    }
}
