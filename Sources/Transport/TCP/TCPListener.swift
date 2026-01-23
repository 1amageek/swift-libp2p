/// TCPListener - NIO ServerChannel wrapper for Listener
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import NIOPosix
import os

/// Debug logger for TCP listener
private let tcpListenerLogger = Logger(subsystem: "swift-libp2p", category: "TCPListener")

/// A TCP listener wrapping a NIO ServerChannel.
public final class TCPListener: Listener, @unchecked Sendable {

    private let serverChannel: Channel
    private let _localAddress: Multiaddr

    private let lock = OSAllocatedUnfairLock()
    private var pendingConnections: [TCPConnection] = []
    /// Queue of waiters for concurrent accept support.
    private var acceptWaiters: [CheckedContinuation<any RawConnection, Error>] = []
    private var isClosed = false

    public var localAddress: Multiaddr { _localAddress }

    private init(serverChannel: Channel, localAddress: Multiaddr) {
        self.serverChannel = serverChannel
        self._localAddress = localAddress
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

            let result: AcceptResult = lock.withLock {
                if isClosed {
                    return .closed
                }

                if !pendingConnections.isEmpty {
                    let connection = pendingConnections.removeFirst()
                    return .connection(connection)
                } else {
                    // Queue the waiter for FIFO delivery
                    let waiterCount = acceptWaiters.count + 1
                    acceptWaiters.append(continuation)
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
        let (waiters, pending) = lock.withLock { () -> ([CheckedContinuation<any RawConnection, Error>], [TCPConnection]) in
            isClosed = true
            let w = acceptWaiters
            let p = pendingConnections
            acceptWaiters.removeAll()
            pendingConnections.removeAll()
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
        // Extract waiter within lock, resume outside to avoid deadlock
        let (waiter, pendingCount) = lock.withLock { () -> (CheckedContinuation<any RawConnection, Error>?, Int) in
            // FIFO: dequeue the first waiter if any
            if !acceptWaiters.isEmpty {
                return (acceptWaiters.removeFirst(), 0)
            } else {
                pendingConnections.append(connection)
                return (nil, pendingConnections.count)
            }
        }
        if let waiter = waiter {
            tcpListenerLogger.debug("connectionAccepted(): Delivering to waiting accept()")
            waiter.resume(returning: connection)
        } else {
            tcpListenerLogger.debug("connectionAccepted(): Queuing connection (pending: \(pendingCount))")
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
private final class HandlerCollector: @unchecked Sendable {
    private var handlers: [TCPReadHandler] = []
    private var listenerCallback: (@Sendable (TCPConnection) -> Void)?
    private let lock = NSLock()

    /// Adds a handler to the collection.
    /// If the listener callback is already set, applies it immediately.
    func add(_ handler: TCPReadHandler) {
        lock.lock()
        handlers.append(handler)
        let callback = listenerCallback
        lock.unlock()

        // If listener is already set, apply callback immediately
        if let callback = callback {
            handler.setListener(callback)
        }
    }

    /// Sets the listener callback on all collected handlers and future handlers.
    /// This delivers any queued connections and enables future deliveries.
    func setListener(_ callback: @escaping @Sendable (TCPConnection) -> Void) {
        lock.lock()
        listenerCallback = callback
        let currentHandlers = handlers
        lock.unlock()

        for handler in currentHandlers {
            handler.setListener(callback)
        }
    }
}

