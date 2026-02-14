/// WebSocketListener - NIO ServerChannel wrapper for WebSocket Listener
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
@preconcurrency import NIOSSL
import Synchronization
import os

/// Debug logger for WebSocket listener
private let wsListenerLogger = Logger(subsystem: "swift-libp2p", category: "WebSocketListener")

/// A WebSocket listener wrapping a NIO ServerChannel.
public final class WebSocketListener: Listener, Sendable {

    private let serverChannel: Channel
    private let _localAddress: Multiaddr

    private let state: Mutex<ListenerState>

    private struct ListenerState: Sendable {
        var pendingConnections: [WebSocketConnection] = []
        /// Queue of waiters for concurrent accept support.
        var acceptWaiters: [CheckedContinuation<any RawConnection, Error>] = []
        var isClosed = false
    }

    public var localAddress: Multiaddr { _localAddress }

    private init(serverChannel: Channel, localAddress: Multiaddr) {
        self.serverChannel = serverChannel
        self._localAddress = localAddress
        self.state = Mutex(ListenerState())
    }

    /// Binds a new WebSocket listener.
    ///
    /// Uses a late-binding pattern via ConnectionCallback:
    /// 1. Create ConnectionCallback without listener
    /// 2. Start server (HTTP + WebSocket upgrade pipeline)
    /// 3. Create the listener
    /// 4. Set the listener callback on ConnectionCallback (delivers any queued connections)
    static func bind(
        host: String,
        port: UInt16,
        group: EventLoopGroup,
        secure: Bool = false,
        sslContext: NIOSSLContext? = nil
    ) async throws -> WebSocketListener {
        wsListenerLogger.debug("bind(): Binding to \(host):\(port)")

        let connectionCallback = ConnectionCallback()

        if secure, sslContext == nil {
            throw TransportError.unsupportedOperation("WSS listener requires TLS context")
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [connectionCallback] channel in
                return channel.eventLoop.makeCompletedFuture {
                    if let sslContext {
                        let sslHandler = NIOSSLServerHandler(context: sslContext)
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                    }
                }.flatMap {
                    Self.configureWebSocketPipeline(
                        channel: channel,
                        connectionCallback: connectionCallback,
                        secure: secure
                    )
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: true)

        let serverChannel = try await bootstrap.bind(host: host, port: Int(port)).get()

        guard let socketAddress = serverChannel.localAddress,
              let localAddr = socketAddress.toWebSocketMultiaddr(secure: secure) else {
            throw TransportError.unsupportedAddress(
                secure ? Multiaddr.wss(host: host, port: port) : Multiaddr.ws(host: host, port: port)
            )
        }

        wsListenerLogger.debug("bind(): Bound successfully to \(localAddr)")

        let listener = WebSocketListener(serverChannel: serverChannel, localAddress: localAddr)

        // Late binding: set the listener callback
        // Any connections that arrived before this point are queued and will be delivered now
        connectionCallback.setListener { connection in
            listener.connectionAccepted(connection)
        }

        wsListenerLogger.debug("bind(): Listener ready")

        return listener
    }

    private static func configureWebSocketPipeline(
        channel: Channel,
        connectionCallback: ConnectionCallback,
        secure: Bool
    ) -> EventLoopFuture<Void> {
        let wsUpgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: wsMaxFrameSize,
            shouldUpgrade: { channel, _ in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { [connectionCallback] channel, _ in
                let handler = WebSocketFrameHandler(isClient: false)
                return channel.pipeline.addHandler(handler).map {
                    let localAddr = channel.localAddress?.toWebSocketMultiaddr(secure: secure)
                    let remoteAddr = channel.remoteAddress?.toWebSocketMultiaddr(secure: secure)
                        ?? Multiaddr(uncheckedProtocols: [.ip4("0.0.0.0"), .tcp(0), secure ? .wss : .ws])

                    let connection = WebSocketConnection(
                        channel: channel,
                        isClient: false,
                        localAddress: localAddr,
                        remoteAddress: remoteAddr
                    )
                    handler.setConnection(connection)
                    connectionCallback.deliver(connection)
                }
            }
        )

        return channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (
                upgraders: [wsUpgrader],
                completionHandler: { _ in }
            )
        )
    }

    public func accept() async throws -> any RawConnection {
        let localAddr = self._localAddress
        wsListenerLogger.debug("accept(): Waiting for connection on \(localAddr)")
        let conn = try await withCheckedThrowingContinuation { continuation in
            enum AcceptResult {
                case closed
                case connection(WebSocketConnection)
                case waiting(Int)
            }

            let result: AcceptResult = state.withLock { s in
                if s.isClosed {
                    return .closed
                }

                if !s.pendingConnections.isEmpty {
                    let connection = s.pendingConnections.removeFirst()
                    return .connection(connection)
                } else {
                    let waiterCount = s.acceptWaiters.count + 1
                    s.acceptWaiters.append(continuation)
                    return .waiting(waiterCount)
                }
            }

            switch result {
            case .closed:
                wsListenerLogger.debug("accept(): Listener is closed")
                continuation.resume(throwing: TransportError.listenerClosed)
            case .connection(let conn):
                wsListenerLogger.debug("accept(): Returning pending connection")
                continuation.resume(returning: conn)
            case .waiting(let count):
                wsListenerLogger.debug("accept(): No pending connections, adding waiter (total: \(count))")
            }
        }
        wsListenerLogger.debug("accept(): Connection accepted from \(conn.remoteAddress)")
        return conn
    }

    public func close() async throws {
        let (waiters, pending) = state.withLock { s -> ([CheckedContinuation<any RawConnection, Error>], [WebSocketConnection]) in
            s.isClosed = true
            let w = s.acceptWaiters
            let p = s.pendingConnections
            s.acceptWaiters.removeAll()
            s.pendingConnections.removeAll()
            return (w, p)
        }

        // Resume all waiters with error
        for waiter in waiters {
            waiter.resume(throwing: TransportError.listenerClosed)
        }

        // Close pending connections to prevent resource leaks
        for conn in pending {
            do {
                try await conn.close()
            } catch {
                wsListenerLogger.warning("close(): Failed to close pending connection: \(error)")
            }
        }

        try await serverChannel.close()
    }

    // Called by ConnectionCallback when a new WebSocket connection is accepted
    fileprivate func connectionAccepted(_ connection: WebSocketConnection) {
        let remoteAddr = connection.remoteAddress
        wsListenerLogger.debug("connectionAccepted(): New connection from \(remoteAddr)")

        enum AcceptAction {
            case deliverToWaiter(CheckedContinuation<any RawConnection, Error>)
            case queued(Int)
            case rejected
        }

        let action: AcceptAction = state.withLock { s in
            guard !s.isClosed else {
                return .rejected
            }

            if !s.acceptWaiters.isEmpty {
                return .deliverToWaiter(s.acceptWaiters.removeFirst())
            } else {
                s.pendingConnections.append(connection)
                return .queued(s.pendingConnections.count)
            }
        }

        switch action {
        case .deliverToWaiter(let waiter):
            wsListenerLogger.debug("connectionAccepted(): Delivering to waiting accept()")
            waiter.resume(returning: connection)
        case .queued(let count):
            wsListenerLogger.debug("connectionAccepted(): Queuing connection (pending: \(count))")
        case .rejected:
            wsListenerLogger.debug("connectionAccepted(): Rejected (listener closed)")
            Task {
                do {
                    try await connection.close()
                } catch {
                    wsListenerLogger.warning("connectionAccepted(): Failed to close rejected connection: \(error)")
                }
            }
        }
    }
}

// MARK: - ConnectionCallback

/// Late-binding callback for delivering WebSocket connections from the NIO upgrade
/// pipeline to the listener.
///
/// This enables the following pattern:
/// 1. ConnectionCallback is created before ServerBootstrap.bind()
/// 2. The NIO upgrade pipeline handler captures connectionCallback
/// 3. After bind completes, the listener is created
/// 4. setListener() is called, flushing any connections that arrived during setup
private final class ConnectionCallback: Sendable {
    private let state: Mutex<CallbackState>

    private struct CallbackState: Sendable {
        var listener: (@Sendable (WebSocketConnection) -> Void)?
        var pending: [WebSocketConnection] = []
    }

    init() {
        self.state = Mutex(CallbackState())
    }

    /// Sets the listener callback. Flushes any buffered connections.
    func setListener(_ callback: @escaping @Sendable (WebSocketConnection) -> Void) {
        let pending: [WebSocketConnection] = state.withLock { s in
            s.listener = callback
            let p = s.pending
            s.pending.removeAll()
            return p
        }

        for conn in pending {
            wsListenerLogger.debug("ConnectionCallback.setListener: Delivering pending connection")
            callback(conn)
        }
    }

    /// Delivers a connection to the listener, or buffers it if listener is not yet set.
    func deliver(_ connection: WebSocketConnection) {
        let callback: (@Sendable (WebSocketConnection) -> Void)? = state.withLock { s in
            if let cb = s.listener {
                return cb
            } else {
                s.pending.append(connection)
                return nil
            }
        }

        if let callback {
            callback(connection)
        }
    }
}
