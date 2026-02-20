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
///
/// Uses NIO's typed WebSocket server upgrader and async bind API.
/// Incoming connections are delivered through `NIOAsyncChannel`'s inbound stream,
/// processed in a background accept loop, and queued for `accept()` callers.
public final class WebSocketListener: Listener, Sendable {

    private let serverChannel: Channel
    private let _localAddress: Multiaddr

    private let state: Mutex<ListenerState>

    /// Background task that iterates the NIOAsyncChannel inbound stream.
    /// Cancelled by `close()` to terminate the accept loop and close the server channel.
    private let acceptTask: Mutex<Task<Void, Never>?>

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
        self.acceptTask = Mutex(nil)
    }

    /// Binds a new WebSocket listener.
    ///
    /// Uses NIO's async `ServerBootstrap.bind()` with a typed WebSocket upgrade pipeline:
    /// 1. Bind server socket → `NIOAsyncChannel<EventLoopFuture<WebSocketUpgradeResult>, Never>`
    /// 2. Create the listener
    /// 3. Start background task iterating inbound connections
    /// 4. For each upgrade result, create `WebSocketConnection` and deliver to `accept()` waiters
    static func bind(
        host: String,
        port: UInt16,
        group: EventLoopGroup,
        secure: Bool = false,
        sslContext: NIOSSLContext? = nil
    ) async throws -> WebSocketListener {
        wsListenerLogger.debug("bind(): Binding to \(host):\(port)")

        if secure, sslContext == nil {
            throw TransportError.unsupportedOperation("WSS listener requires TLS context")
        }

        // Async bind with typed WebSocket upgrade pipeline
        let asyncServerChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: true)
            .bind(host: host, port: Int(port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    // TLS handler (secure only)
                    if let sslContext {
                        let sslHandler = NIOSSLServerHandler(context: sslContext)
                        try channel.pipeline.syncOperations.addHandler(sslHandler)
                    }

                    // Typed WebSocket server upgrader
                    let wsUpgrader = NIOTypedWebSocketServerUpgrader<WebSocketUpgradeResult>(
                        maxFrameSize: wsMaxFrameSize,
                        shouldUpgrade: { channel, _ in
                            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                let handler = WebSocketFrameHandler(isClient: false)
                                try channel.pipeline.syncOperations.addHandler(handler)
                                return WebSocketUpgradeResult.websocket(channel, handler)
                            }
                        }
                    )

                    let serverUpgradeConfig = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [wsUpgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.close(promise: nil)
                            return channel.eventLoop.makeSucceededFuture(.notUpgraded)
                        }
                    )

                    return try channel.pipeline.syncOperations
                        .configureUpgradableHTTPServerPipeline(
                            configuration: .init(upgradeConfiguration: serverUpgradeConfig)
                        )
                }
            }

        let serverChannel = asyncServerChannel.channel
        guard let socketAddress = serverChannel.localAddress,
              let localAddr = socketAddress.toWebSocketMultiaddr(secure: secure) else {
            throw TransportError.unsupportedAddress(
                secure ? Multiaddr.wss(host: host, port: port) : Multiaddr.ws(host: host, port: port)
            )
        }

        wsListenerLogger.debug("bind(): Bound successfully to \(localAddr)")

        let listener = WebSocketListener(serverChannel: serverChannel, localAddress: localAddr)

        // Start background accept loop
        let task = Task<Void, Never> {
            do {
                try await asyncServerChannel.executeThenClose { inbound in
                    for try await upgradeResult in inbound {
                        do {
                            switch try await upgradeResult.get() {
                            case .websocket(let ch, let handler):
                                let local = ch.localAddress?.toWebSocketMultiaddr(secure: secure)
                                let remote = ch.remoteAddress?.toWebSocketMultiaddr(secure: secure)
                                    ?? Multiaddr(uncheckedProtocols: [
                                        .ip4("0.0.0.0"), .tcp(0), secure ? .wss : .ws,
                                    ])

                                let connection = WebSocketConnection(
                                    channel: ch,
                                    isClient: false,
                                    localAddress: local,
                                    remoteAddress: remote
                                )
                                handler.setConnection(connection)
                                listener.connectionAccepted(connection)

                            case .notUpgraded:
                                break
                            }
                        } catch {
                            wsListenerLogger.warning("bind(): Upgrade failed: \(error)")
                        }
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    wsListenerLogger.error("bind(): Accept loop error: \(error)")
                }
            }
            // executeThenClose has closed the server channel
            listener.acceptLoopEnded()
        }
        listener.acceptTask.withLock { $0 = task }

        wsListenerLogger.debug("bind(): Listener ready")

        return listener
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

        // Cancel the accept task → executeThenClose exits → server channel closes automatically
        let task = acceptTask.withLock { t -> Task<Void, Never>? in
            let current = t
            t = nil
            return current
        }
        task?.cancel()
        await task?.value
    }

    // MARK: - Internal

    /// Called by the background accept loop when a new WebSocket connection is accepted.
    private func connectionAccepted(_ connection: WebSocketConnection) {
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

    /// Called when the background accept loop ends (server channel closed).
    /// Ensures any remaining waiters are woken with an error.
    private func acceptLoopEnded() {
        let waiters = state.withLock { s -> [CheckedContinuation<any RawConnection, Error>] in
            s.isClosed = true
            let w = s.acceptWaiters
            s.acceptWaiters.removeAll()
            return w
        }
        for waiter in waiters {
            waiter.resume(throwing: TransportError.listenerClosed)
        }
    }
}
