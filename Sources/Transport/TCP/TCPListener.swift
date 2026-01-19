/// TCPListener - NIO ServerChannel wrapper for Listener
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import NIOPosix
import os

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
    static func bind(
        host: String,
        port: UInt16,
        group: EventLoopGroup
    ) async throws -> TCPListener {

        // Create the listener first so we can reference it in the handler
        let listenerHolder = ListenerHolder()

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.autoRead, value: true)

        let serverChannel = try await bootstrap.bind(host: host, port: Int(port)).get()

        guard let socketAddress = serverChannel.localAddress,
              let localAddr = socketAddress.toMultiaddr() else {
            throw TransportError.unsupportedAddress(Multiaddr.tcp(host: host, port: port))
        }

        let listener = TCPListener(serverChannel: serverChannel, localAddress: localAddr)
        listenerHolder.listener = listener

        // Add accept handler to server channel
        try await serverChannel.pipeline.addHandler(TCPAcceptHandler(listenerHolder: listenerHolder))

        return listener
    }

    public func accept() async throws -> any RawConnection {
        try await withCheckedThrowingContinuation { continuation in
            // Extract result within lock, resume outside to avoid deadlock
            enum AcceptResult {
                case closed
                case connection(TCPConnection)
                case waiting
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
                    acceptWaiters.append(continuation)
                    return .waiting
                }
            }

            // Resume continuation outside of lock to avoid deadlock
            switch result {
            case .closed:
                continuation.resume(throwing: TransportError.listenerClosed)
            case .connection(let conn):
                continuation.resume(returning: conn)
            case .waiting:
                break  // Continuation stored, will be resumed later
            }
        }
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
        // Extract waiter within lock, resume outside to avoid deadlock
        let waiter = lock.withLock { () -> CheckedContinuation<any RawConnection, Error>? in
            // FIFO: dequeue the first waiter if any
            if !acceptWaiters.isEmpty {
                return acceptWaiters.removeFirst()
            } else {
                pendingConnections.append(connection)
                return nil
            }
        }
        waiter?.resume(returning: connection)
    }
}

// MARK: - ListenerHolder

/// Holder to break circular reference during initialization.
private final class ListenerHolder: @unchecked Sendable {
    var listener: TCPListener?
}

// MARK: - TCPAcceptHandler

private final class TCPAcceptHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Channel

    private let listenerHolder: ListenerHolder

    init(listenerHolder: ListenerHolder) {
        self.listenerHolder = listenerHolder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let childChannel = unwrapInboundIn(data)

        let remoteAddr = childChannel.remoteAddress?.toMultiaddr()
            // Safe: exactly 2 components
            ?? Multiaddr(uncheckedProtocols: [.ip4("0.0.0.0"), .tcp(0)])
        let localAddr = childChannel.localAddress?.toMultiaddr()

        let connection = TCPConnection(
            channel: childChannel,
            localAddress: localAddr,
            remoteAddress: remoteAddr
        )

        listenerHolder.listener?.connectionAccepted(connection)
    }
}
