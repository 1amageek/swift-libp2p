/// TCPConnection - NIO Channel wrapper for RawConnection
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import Synchronization
import os

/// Debug logger for TCP connection
private let tcpLogger = Logger(subsystem: "swift-libp2p", category: "TCPConnection")

/// Maximum buffer size (1MB) for DoS protection.
private let tcpMaxReadBufferSize = 1024 * 1024

/// Internal state for TCPConnection.
private struct TCPConnectionState: Sendable {
    var readBuffer: ByteBuffer = ByteBuffer()
    /// Queue of waiters for concurrent read support.
    var readWaiters: [CheckedContinuation<ByteBuffer, Error>] = []
    var isClosed = false
}

/// A TCP connection wrapping a NIO Channel.
public final class TCPConnection: RawConnection, Sendable {

    private let channel: Channel
    private let _localAddress: Multiaddr?
    private let _remoteAddress: Multiaddr

    private let state = Mutex(TCPConnectionState())

    public var localAddress: Multiaddr? { _localAddress }
    public var remoteAddress: Multiaddr { _remoteAddress }

    /// Creates a TCPConnection.
    ///
    /// For accept side: use this init directly, then add handler via `syncOperations`.
    /// For dial side: use `create()` which handles async handler installation.
    init(channel: Channel, localAddress: Multiaddr?, remoteAddress: Multiaddr) {
        self.channel = channel
        self._localAddress = localAddress
        self._remoteAddress = remoteAddress
    }

    /// Creates a TCPConnection from a channel for dial side.
    ///
    /// This async factory method installs the read handler and returns the connection.
    /// For accept side, use TCPReadHandler with onAccepted callback in childChannelInitializer.
    static func create(
        channel: Channel,
        localAddress: Multiaddr?,
        remoteAddress: Multiaddr
    ) async throws -> TCPConnection {
        tcpLogger.debug("TCPConnection.create: Starting for \(remoteAddress)")
        let connection = TCPConnection(
            channel: channel,
            localAddress: localAddress,
            remoteAddress: remoteAddress
        )
        let handler = TCPReadHandler()
        try await channel.pipeline.addHandler(handler)
        handler.setConnection(connection)
        tcpLogger.debug("TCPConnection.create: Handler added successfully")
        return connection
    }

    public func read() async throws -> ByteBuffer {
        let remoteAddr = self._remoteAddress
        tcpLogger.debug("read(): Starting read on \(remoteAddr)")
        let result: ByteBuffer = try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                // Check buffer first (avoid data loss on close)
                if s.readBuffer.readableBytes > 0 {
                    let data = s.readBuffer
                    let count = data.readableBytes
                    s.readBuffer = ByteBuffer()
                    tcpLogger.debug("read(): Returning buffered data (\(count) bytes)")
                    continuation.resume(returning: data)
                    return
                }

                if s.isClosed {
                    tcpLogger.debug("read(): Connection already closed, throwing error")
                    continuation.resume(throwing: TransportError.connectionClosed)
                    return
                }

                // Queue the waiter for FIFO delivery
                let waiterCount = s.readWaiters.count + 1
                tcpLogger.debug("read(): No data, adding waiter (total waiters: \(waiterCount))")
                s.readWaiters.append(continuation)
            }
        }
        tcpLogger.debug("read(): Completed with \(result.readableBytes) bytes")
        return result
    }

    public func write(_ data: ByteBuffer) async throws {
        // Early check for closed state - provides clearer error than NIO's failure
        let closed = state.withLock { $0.isClosed }
        if closed {
            tcpLogger.debug("write(): Connection already closed, throwing error")
            throw TransportError.connectionClosed
        }

        tcpLogger.debug("write(): Writing \(data.readableBytes) bytes to \(self._remoteAddress)")
        try await channel.writeAndFlush(data)
        tcpLogger.debug("write(): Write completed")
    }

    public func close() async throws {
        tcpLogger.debug("close(): Closing connection to \(self._remoteAddress)")
        let (alreadyClosed, waiters) = state.withLock { state -> (Bool, [CheckedContinuation<ByteBuffer, Error>]) in
            let wasClosed = state.isClosed
            state.isClosed = true
            let w = state.readWaiters
            state.readWaiters.removeAll()
            return (wasClosed, w)
        }

        // Resume all waiters outside of lock to avoid deadlock
        if !waiters.isEmpty {
            tcpLogger.debug("close(): Resuming \(waiters.count) waiters with error")
            for waiter in waiters {
                waiter.resume(throwing: TransportError.connectionClosed)
            }
        }

        // If already closed (e.g., by channelInactive), skip channel.close()
        guard !alreadyClosed else {
            tcpLogger.debug("close(): Already closed, skipping channel close")
            return
        }

        // Close the channel if still active
        if channel.isActive {
            tcpLogger.debug("close(): Closing channel...")
            do {
                try await channel.close()
                tcpLogger.debug("close(): Channel closed")
            } catch {
                // Channel might have closed between isActive check and close()
                // This is a race condition that's acceptable to ignore
                tcpLogger.debug("close(): Channel close threw (may already be closed): \(error)")
            }
        } else {
            tcpLogger.debug("close(): Channel already inactive")
        }
    }

    // Called by TCPReadHandler when data is received
    fileprivate func dataReceived(_ data: ByteBuffer) {
        tcpLogger.debug("dataReceived(): Received \(data.readableBytes) bytes")
        let (waiter, bufferSize) = state.withLock { s -> (CheckedContinuation<ByteBuffer, Error>?, Int) in
            // FIFO: dequeue the first waiter if any
            if !s.readWaiters.isEmpty {
                return (s.readWaiters.removeFirst(), 0)
            } else {
                // Buffer size limit for DoS protection
                if s.readBuffer.readableBytes + data.readableBytes > tcpMaxReadBufferSize {
                    // Drop data if buffer is full (backpressure)
                    return (nil, -1)  // -1 indicates buffer full
                }
                var mutableData = data
                s.readBuffer.writeBuffer(&mutableData)
                return (nil, s.readBuffer.readableBytes)
            }
        }
        // Log and resume waiter outside of lock to avoid deadlock
        if let waiter = waiter {
            tcpLogger.debug("dataReceived(): Delivering to waiting reader")
            waiter.resume(returning: data)
        } else if bufferSize == -1 {
            tcpLogger.warning("dataReceived(): Buffer full, dropping data")
        } else {
            tcpLogger.debug("dataReceived(): Buffering data (buffer size: \(bufferSize))")
        }
    }

    // Called by TCPReadHandler when channel becomes inactive
    fileprivate func channelInactive() {
        tcpLogger.debug("channelInactive(): Channel became inactive")
        let waiters = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
            state.isClosed = true
            let w = state.readWaiters
            state.readWaiters.removeAll()
            return w
        }
        tcpLogger.debug("channelInactive(): Resuming \(waiters.count) waiters with error")
        // Resume all waiters outside of lock to avoid deadlock
        for waiter in waiters {
            waiter.resume(throwing: TransportError.connectionClosed)
        }
    }
}

// MARK: - TCPReadHandler

/// Channel handler for reading data from TCP connections.
///
/// This unified handler supports both accept and dial scenarios:
/// - **Accept side**: Initialize with `acceptMode: true`; connection is created on `channelActive`
///   and delivered via `setListener()` callback (supports late binding)
/// - **Dial side**: Initialize without callback; call `setConnection()` after adding to pipeline
///
/// The handler queues connections created before the listener is set, ensuring no connections
/// are dropped during listener initialization.
///
/// All mutable state is protected by `Mutex<HandlerState>` for thread safety.
/// NIO handler methods and external methods (`setListener`, `setConnection`) may run
/// on different threads, so full synchronization is required.
final class TCPReadHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    /// Whether this handler is in accept mode (creates connection on channelActive)
    let acceptMode: Bool

    private let state: Mutex<HandlerState>

    private struct HandlerState: Sendable {
        var connection: TCPConnection?
        var bufferedData: [ByteBuffer] = []
        var isInactive = false
        /// Callback for accept side: set via setListener(), may be set after channelActive
        var onAccepted: (@Sendable (TCPConnection) -> Void)?
        /// Connection created before listener was set (queued for delivery)
        var pendingConnection: TCPConnection?
    }

    /// Dial side initializer: no callback, connection set via setConnection()
    init() {
        self.acceptMode = false
        self.state = Mutex(HandlerState())
        tcpLogger.debug("TCPReadHandler: Initialized (dial mode)")
    }

    /// Accept side initializer: connection created on channelActive
    /// Callback can be provided now or later via setListener()
    init(onAccepted: (@Sendable (TCPConnection) -> Void)? = nil) {
        self.acceptMode = true
        self.state = Mutex(HandlerState(onAccepted: onAccepted))
        tcpLogger.debug("TCPReadHandler: Initialized (accept mode, callback: \(onAccepted != nil))")
    }

    /// Sets the listener callback for accept mode.
    /// If a connection was already created (pending), it is delivered immediately.
    /// This enables late binding of the listener after bootstrap completes.
    func setListener(_ callback: @escaping @Sendable (TCPConnection) -> Void) {
        let pending: TCPConnection? = state.withLock { s in
            s.onAccepted = callback
            let p = s.pendingConnection
            s.pendingConnection = nil
            return p
        }

        // Deliver pending connection outside of lock
        if let conn = pending {
            tcpLogger.debug("TCPReadHandler.setListener: Delivering pending connection")
            callback(conn)
        }
    }

    /// Called when channel becomes active.
    /// For accept side: creates connection and delivers via callback or queues for later.
    func channelActive(context: ChannelHandlerContext) {
        if acceptMode {
            let channel = context.channel
            let remoteAddr = channel.remoteAddress?.toMultiaddr()
                ?? Multiaddr(uncheckedProtocols: [.ip4("0.0.0.0"), .tcp(0)])
            let localAddr = channel.localAddress?.toMultiaddr()

            tcpLogger.debug("TCPReadHandler.channelActive: Creating connection to \(remoteAddr)")

            let newConnection = TCPConnection(
                channel: channel,
                localAddress: localAddr,
                remoteAddress: remoteAddr
            )

            enum ActiveAction {
                case deliver(@Sendable (TCPConnection) -> Void, [ByteBuffer])
                case queue([ByteBuffer])
                case skip
            }

            let action: ActiveAction = state.withLock { s in
                guard s.connection == nil else { return .skip }
                s.connection = newConnection
                let buffered = s.bufferedData
                s.bufferedData.removeAll()

                if let callback = s.onAccepted {
                    return .deliver(callback, buffered)
                } else {
                    s.pendingConnection = newConnection
                    return .queue(buffered)
                }
            }

            // Flush buffered data and act outside lock
            switch action {
            case .deliver(let callback, let buffered):
                for data in buffered {
                    tcpLogger.debug("TCPReadHandler: Flushing \(data.readableBytes) buffered bytes")
                    newConnection.dataReceived(data)
                }
                tcpLogger.debug("TCPReadHandler.channelActive: Delivering connection immediately")
                callback(newConnection)
            case .queue(let buffered):
                for data in buffered {
                    tcpLogger.debug("TCPReadHandler: Flushing \(data.readableBytes) buffered bytes")
                    newConnection.dataReceived(data)
                }
                tcpLogger.debug("TCPReadHandler.channelActive: Queuing connection (listener not ready)")
            case .skip:
                break
            }
        }
        context.fireChannelActive()
    }

    /// Dial side: manually set connection after handler is added to pipeline.
    func setConnection(_ connection: TCPConnection) {
        tcpLogger.debug("TCPReadHandler.setConnection: Setting connection")
        let (buffered, inactive) = state.withLock { s -> ([ByteBuffer], Bool) in
            s.connection = connection
            let b = s.bufferedData
            s.bufferedData.removeAll()
            let i = s.isInactive
            return (b, i)
        }
        for data in buffered {
            tcpLogger.debug("TCPReadHandler: Flushing \(data.readableBytes) buffered bytes")
            connection.dataReceived(data)
        }
        if inactive {
            connection.channelInactive()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let readable = buffer.readableBytes
        guard readable > 0, let slice = buffer.readSlice(length: readable) else { return }
        let conn: TCPConnection? = state.withLock { s in
            if let connection = s.connection {
                return connection
            } else {
                s.bufferedData.append(slice)
                return nil
            }
        }
        if let conn {
            tcpLogger.debug("TCPReadHandler.channelRead: Forwarding \(readable) bytes")
            conn.dataReceived(slice)
        } else {
            tcpLogger.debug("TCPReadHandler.channelRead: Buffering \(readable) bytes")
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        tcpLogger.debug("TCPReadHandler.channelInactive: Channel inactive")
        let conn: TCPConnection? = state.withLock { s in
            if let connection = s.connection {
                return connection
            } else {
                s.isInactive = true
                return nil
            }
        }
        conn?.channelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        tcpLogger.error("TCPReadHandler.errorCaught: \(error)")
        let conn: TCPConnection? = state.withLock { s in
            if let connection = s.connection {
                return connection
            } else {
                s.isInactive = true
                return nil
            }
        }
        conn?.channelInactive()
        context.close(promise: nil)
    }
}

// MARK: - Multiaddr conversion helpers

extension SocketAddress {
    /// Converts a SocketAddress to a Multiaddr.
    func toMultiaddr() -> Multiaddr? {
        switch self {
        case .v4(let addr):
            let ip = addr.host
            let port = UInt16(self.port ?? 0)
            // Safe: exactly 2 components
            return Multiaddr(uncheckedProtocols: [.ip4(ip), .tcp(port)])
        case .v6(let addr):
            let ip = addr.host
            let port = UInt16(self.port ?? 0)
            // Safe: exactly 2 components
            return Multiaddr(uncheckedProtocols: [.ip6(ip), .tcp(port)])
        case .unixDomainSocket:
            return nil
        }
    }
}
