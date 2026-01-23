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
    var readBuffer: [UInt8] = []
    /// Queue of waiters for concurrent read support.
    var readWaiters: [CheckedContinuation<Data, Error>] = []
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

    public func read() async throws -> Data {
        let remoteAddr = self._remoteAddress
        tcpLogger.debug("read(): Starting read on \(remoteAddr)")
        let result = try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                // Check buffer first (avoid data loss on close)
                if !s.readBuffer.isEmpty {
                    let data = Data(s.readBuffer)
                    let count = data.count
                    s.readBuffer.removeAll()
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
        tcpLogger.debug("read(): Completed with \(result.count) bytes")
        return result
    }

    public func write(_ data: Data) async throws {
        // Early check for closed state - provides clearer error than NIO's failure
        let closed = state.withLock { $0.isClosed }
        if closed {
            tcpLogger.debug("write(): Connection already closed, throwing error")
            throw TransportError.connectionClosed
        }

        tcpLogger.debug("write(): Writing \(data.count) bytes to \(self._remoteAddress)")
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer)
        tcpLogger.debug("write(): Write completed")
    }

    public func close() async throws {
        tcpLogger.debug("close(): Closing connection to \(self._remoteAddress)")
        let (alreadyClosed, waiters) = state.withLock { state -> (Bool, [CheckedContinuation<Data, Error>]) in
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
    fileprivate func dataReceived(_ data: [UInt8]) {
        tcpLogger.debug("dataReceived(): Received \(data.count) bytes")
        let (waiter, bufferSize) = state.withLock { s -> (CheckedContinuation<Data, Error>?, Int) in
            // FIFO: dequeue the first waiter if any
            if !s.readWaiters.isEmpty {
                return (s.readWaiters.removeFirst(), 0)
            } else {
                // Buffer size limit for DoS protection
                if s.readBuffer.count + data.count > tcpMaxReadBufferSize {
                    // Drop data if buffer is full (backpressure)
                    return (nil, -1)  // -1 indicates buffer full
                }
                s.readBuffer.append(contentsOf: data)
                return (nil, s.readBuffer.count)
            }
        }
        // Log and resume waiter outside of lock to avoid deadlock
        if let waiter = waiter {
            tcpLogger.debug("dataReceived(): Delivering to waiting reader")
            waiter.resume(returning: Data(data))
        } else if bufferSize == -1 {
            tcpLogger.warning("dataReceived(): Buffer full, dropping data")
        } else {
            tcpLogger.debug("dataReceived(): Buffering data (buffer size: \(bufferSize))")
        }
    }

    // Called by TCPReadHandler when channel becomes inactive
    fileprivate func channelInactive() {
        tcpLogger.debug("channelInactive(): Channel became inactive")
        let waiters = state.withLock { state -> [CheckedContinuation<Data, Error>] in
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
/// NIO ChannelHandler requires @unchecked Sendable due to framework requirements.
final class TCPReadHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var connection: TCPConnection?
    private var bufferedData: [[UInt8]] = []
    private var isInactive = false

    /// Whether this handler is in accept mode (creates connection on channelActive)
    private let acceptMode: Bool

    /// Callback for accept side: set via setListener(), may be set after channelActive
    private var onAccepted: (@Sendable (TCPConnection) -> Void)?

    /// Connection created before listener was set (queued for delivery)
    private var pendingConnection: TCPConnection?

    /// Lock for thread-safe access to onAccepted and pendingConnection
    private let lock = NSLock()

    /// Dial side initializer: no callback, connection set via setConnection()
    init() {
        self.acceptMode = false
        self.onAccepted = nil
        tcpLogger.debug("TCPReadHandler: Initialized (dial mode)")
    }

    /// Accept side initializer: connection created on channelActive
    /// Callback can be provided now or later via setListener()
    init(onAccepted: (@Sendable (TCPConnection) -> Void)? = nil) {
        self.acceptMode = true
        self.onAccepted = onAccepted
        tcpLogger.debug("TCPReadHandler: Initialized (accept mode, callback: \(onAccepted != nil))")
    }

    /// Sets the listener callback for accept mode.
    /// If a connection was already created (pending), it is delivered immediately.
    /// This enables late binding of the listener after bootstrap completes.
    func setListener(_ callback: @escaping @Sendable (TCPConnection) -> Void) {
        lock.lock()
        self.onAccepted = callback
        let pending = pendingConnection
        pendingConnection = nil
        lock.unlock()

        // Deliver pending connection outside of lock
        if let conn = pending {
            tcpLogger.debug("TCPReadHandler.setListener: Delivering pending connection")
            callback(conn)
        }
    }

    /// Called when channel becomes active.
    /// For accept side: creates connection and delivers via callback or queues for later.
    func channelActive(context: ChannelHandlerContext) {
        if acceptMode && connection == nil {
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
            self.connection = newConnection
            flushBufferedData(to: newConnection)

            // Try to deliver immediately, or queue for later
            lock.lock()
            if let callback = onAccepted {
                lock.unlock()
                tcpLogger.debug("TCPReadHandler.channelActive: Delivering connection immediately")
                callback(newConnection)
            } else {
                // Listener not yet set - queue the connection
                pendingConnection = newConnection
                lock.unlock()
                tcpLogger.debug("TCPReadHandler.channelActive: Queuing connection (listener not ready)")
            }
        }
        context.fireChannelActive()
    }

    /// Dial side: manually set connection after handler is added to pipeline.
    func setConnection(_ connection: TCPConnection) {
        tcpLogger.debug("TCPReadHandler.setConnection: Setting connection")
        self.connection = connection
        flushBufferedData(to: connection)
        if isInactive {
            connection.channelInactive()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            if let connection = connection {
                tcpLogger.debug("TCPReadHandler.channelRead: Forwarding \(bytes.count) bytes")
                connection.dataReceived(bytes)
            } else {
                tcpLogger.debug("TCPReadHandler.channelRead: Buffering \(bytes.count) bytes")
                bufferedData.append(bytes)
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        tcpLogger.debug("TCPReadHandler.channelInactive: Channel inactive")
        if let connection = connection {
            connection.channelInactive()
        } else {
            isInactive = true
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        tcpLogger.error("TCPReadHandler.errorCaught: \(error)")
        if let connection = connection {
            connection.channelInactive()
        } else {
            isInactive = true
        }
        context.close(promise: nil)
    }

    private func flushBufferedData(to connection: TCPConnection) {
        for data in bufferedData {
            tcpLogger.debug("TCPReadHandler: Flushing \(data.count) buffered bytes")
            connection.dataReceived(data)
        }
        bufferedData.removeAll()
    }
}

// MARK: - TransportError extension

extension TransportError {
    static let connectionClosed = TransportError.connectionFailed(underlying: ConnectionClosedError())
}

struct ConnectionClosedError: Error, CustomStringConvertible {
    var description: String { "Connection closed" }
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
