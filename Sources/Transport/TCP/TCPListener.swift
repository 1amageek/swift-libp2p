/// TCPListener - NIO ServerChannel wrapper for Listener
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import NIOPosix
import Synchronization
import os

/// Debug logger for TCP listener
private let tcpListenerLogger = Logger(subsystem: "swift-libp2p", category: "TCPListener")

/// A TCP listener wrapping a NIO ServerChannel.
public final class TCPListener: Listener, Sendable {

    private let serverChannel: Channel
    private let _localAddress: Multiaddr

    private let state: Mutex<ListenerState>

    private struct ListenerState: Sendable {
        var pendingConnections: [TCPConnection] = []
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

    /// Binds a new TCP listener.
    ///
    /// This method uses a late-binding pattern to avoid race conditions:
    /// 1. Create handlers without listener callback
    /// 2. Start the server (may accept connections immediately)
    /// 3. Create the listener
    /// 4. Set the listener callback on all handlers (delivers any queued connections)
    static func bind(
        host: String,
        port: UInt16,
        group: EventLoopGroup
    ) async throws -> TCPListener {
        tcpListenerLogger.debug("bind(): Binding to \(host):\(port)")

        // Collect handlers for late binding
        let handlerCollector = HandlerCollector()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [handlerCollector] channel in
                // Create handler without callback - will be set after listener is ready
                let handler = TCPReadHandler(onAccepted: nil)
                handlerCollector.add(handler)
                return channel.pipeline.addHandler(handler)
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(.socketOption(.so_keepalive), value: 1)
            .childChannelOption(.autoRead, value: true)

        let serverChannel = try await bootstrap.bind(host: host, port: Int(port)).get()

        guard let socketAddress = serverChannel.localAddress,
              let localAddr = socketAddress.toMultiaddr() else {
            throw TransportError.unsupportedAddress(Multiaddr.tcp(host: host, port: port))
        }

        tcpListenerLogger.debug("bind(): Bound successfully to \(localAddr)")

        let listener = TCPListener(serverChannel: serverChannel, localAddress: localAddr)

        // Late binding: set the listener callback on all handlers
        // Any connections that arrived before this point are queued and will be delivered now
        handlerCollector.setListener { connection in
            listener.connectionAccepted(connection)
        }

        tcpListenerLogger.debug("bind(): Listener ready (handlers bound)")

        return listener
    }

    public func accept() async throws -> any RawConnection {
        let localAddr = self._localAddress
        tcpListenerLogger.debug("accept(): Waiting for connection on \(localAddr)")
        let conn = try await withCheckedThrowingContinuation { continuation in
            // Extract result within lock, resume outside to avoid deadlock
            enum AcceptResult {
                case closed
                case connection(TCPConnection)
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
                    // Queue the waiter for FIFO delivery
                    let waiterCount = s.acceptWaiters.count + 1
                    s.acceptWaiters.append(continuation)
                    return .waiting(waiterCount)
                }
            }

            // Resume continuation outside of lock to avoid deadlock
            switch result {
            case .closed:
                tcpListenerLogger.debug("accept(): Listener is closed")
                continuation.resume(throwing: TransportError.listenerClosed)
            case .connection(let conn):
                tcpListenerLogger.debug("accept(): Returning pending connection")
                continuation.resume(returning: conn)
            case .waiting(let count):
                tcpListenerLogger.debug("accept(): No pending connections, adding waiter (total: \(count))")
            }
        }
        tcpListenerLogger.debug("accept(): Connection accepted from \(conn.remoteAddress)")
        return conn
    }

    public func close() async throws {
        // Extract waiters and pending connections within lock
        let (waiters, pending) = state.withLock { s -> ([CheckedContinuation<any RawConnection, Error>], [TCPConnection]) in
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
            try? await conn.close()
        }

        try await serverChannel.close()
    }

    // Called by TCPAcceptHandler when a new connection is accepted
    fileprivate func connectionAccepted(_ connection: TCPConnection) {
        let remoteAddr = connection.remoteAddress
        tcpListenerLogger.debug("connectionAccepted(): New connection from \(remoteAddr)")

        enum AcceptAction {
            case deliverToWaiter(CheckedContinuation<any RawConnection, Error>)
            case queued(Int)
            case rejected
        }

        // Extract action within lock, execute outside to avoid deadlock
        let action: AcceptAction = state.withLock { s in
            // Reject connections after close to prevent resource leaks
            guard !s.isClosed else {
                return .rejected
            }

            // FIFO: dequeue the first waiter if any
            if !s.acceptWaiters.isEmpty {
                return .deliverToWaiter(s.acceptWaiters.removeFirst())
            } else {
                s.pendingConnections.append(connection)
                return .queued(s.pendingConnections.count)
            }
        }

        switch action {
        case .deliverToWaiter(let waiter):
            tcpListenerLogger.debug("connectionAccepted(): Delivering to waiting accept()")
            waiter.resume(returning: connection)
        case .queued(let count):
            tcpListenerLogger.debug("connectionAccepted(): Queuing connection (pending: \(count))")
        case .rejected:
            tcpListenerLogger.debug("connectionAccepted(): Rejected (listener closed)")
            Task { try? await connection.close() }
        }
    }
}

// MARK: - HandlerCollector

/// Collects TCPReadHandlers during bootstrap for late listener binding.
///
/// This class enables the late-binding pattern that prevents connection drops:
/// 1. Handlers are created and added to the collector during childChannelInitializer
/// 2. After the listener is created, setListener() is called to store the callback
/// 3. New handlers added after setListener() automatically receive the callback
/// 4. Any connections that arrived before binding are delivered from the handler's queue
private final class HandlerCollector: Sendable {
    private let state: Mutex<CollectorState>

    private struct CollectorState: Sendable {
        var handlers: [TCPReadHandler] = []
        var listenerCallback: (@Sendable (TCPConnection) -> Void)?
    }

    init() {
        self.state = Mutex(CollectorState())
    }

    /// Adds a handler to the collection.
    /// If the listener callback is already set, applies it immediately
    /// without storing the handler (avoiding memory leak).
    func add(_ handler: TCPReadHandler) {
        let callback: (@Sendable (TCPConnection) -> Void)? = state.withLock { s in
            if let cb = s.listenerCallback {
                return cb
            } else {
                // Only store if listener isn't set yet (needed for setListener batch apply)
                s.handlers.append(handler)
                return nil
            }
        }

        // If listener is already set, apply callback immediately (outside lock)
        if let callback {
            handler.setListener(callback)
        }
    }

    /// Sets the listener callback on all collected handlers and future handlers.
    /// This delivers any queued connections and enables future deliveries.
    /// Clears the stored handlers afterward since they are no longer needed.
    func setListener(_ callback: @escaping @Sendable (TCPConnection) -> Void) {
        let currentHandlers: [TCPReadHandler] = state.withLock { s in
            s.listenerCallback = callback
            let h = s.handlers
            s.handlers.removeAll()
            return h
        }

        for handler in currentHandlers {
            handler.setListener(callback)
        }
    }
}

