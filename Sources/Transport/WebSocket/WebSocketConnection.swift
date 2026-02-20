/// WebSocketConnection - NIO Channel wrapper for RawConnection over WebSocket
import P2PCore
import P2PTransport
import NIOCore
import NIOWebSocket
import Synchronization
import os

/// Debug logger for WebSocket connection
private let wsConnectionLogger = Logger(subsystem: "swift-libp2p", category: "WebSocketConnection")

/// Maximum buffer size (1MB) for DoS protection.
private let wsMaxReadBufferSize = 1024 * 1024

/// Internal state for WebSocketConnection.
private struct WebSocketConnectionState: Sendable {
    var readBuffer: ByteBuffer = ByteBuffer()
    /// Queue of waiters for concurrent read support.
    var readWaiters: [CheckedContinuation<ByteBuffer, Error>] = []
    var isClosed = false
}

/// A WebSocket connection wrapping a NIO Channel.
public final class WebSocketConnection: RawConnection, Sendable {

    private let channel: Channel
    private let isClient: Bool
    private let _localAddress: Multiaddr?
    private let _remoteAddress: Multiaddr

    private let state = Mutex(WebSocketConnectionState())

    public var localAddress: Multiaddr? { _localAddress }
    public var remoteAddress: Multiaddr { _remoteAddress }

    init(channel: Channel, isClient: Bool, localAddress: Multiaddr?, remoteAddress: Multiaddr) {
        self.channel = channel
        self.isClient = isClient
        self._localAddress = localAddress
        self._remoteAddress = remoteAddress
    }

    public func read() async throws -> ByteBuffer {
        let remoteAddr = self._remoteAddress
        wsConnectionLogger.debug("read(): Starting read on \(remoteAddr)")
        let result = try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                // Check buffer first (avoid data loss on close)
                if s.readBuffer.readableBytes > 0 {
                    let buffer = s.readBuffer
                    let count = buffer.readableBytes
                    s.readBuffer = ByteBuffer()
                    wsConnectionLogger.debug("read(): Returning buffered data (\(count) bytes)")
                    continuation.resume(returning: buffer)
                    return
                }

                if s.isClosed {
                    wsConnectionLogger.debug("read(): Connection already closed, throwing error")
                    continuation.resume(throwing: TransportError.connectionClosed)
                    return
                }

                // Queue the waiter for FIFO delivery
                let waiterCount = s.readWaiters.count + 1
                wsConnectionLogger.debug("read(): No data, adding waiter (total waiters: \(waiterCount))")
                s.readWaiters.append(continuation)
            }
        }
        wsConnectionLogger.debug("read(): Completed with \(result.readableBytes) bytes")
        return result
    }

    public func write(_ data: ByteBuffer) async throws {
        // Early check for closed state
        let closed = state.withLock { $0.isClosed }
        if closed {
            wsConnectionLogger.debug("write(): Connection already closed, throwing error")
            throw TransportError.connectionClosed
        }

        wsConnectionLogger.debug("write(): Writing \(data.readableBytes) bytes to \(self._remoteAddress)")
        let maskKey: WebSocketMaskingKey? = isClient ? .random() : nil
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: maskKey, data: data)
        try await channel.writeAndFlush(frame)
        wsConnectionLogger.debug("write(): Write completed")
    }

    public func close() async throws {
        wsConnectionLogger.debug("close(): Closing connection to \(self._remoteAddress)")
        let (alreadyClosed, waiters) = state.withLock { state -> (Bool, [CheckedContinuation<ByteBuffer, Error>]) in
            let wasClosed = state.isClosed
            state.isClosed = true
            let w = state.readWaiters
            state.readWaiters.removeAll()
            return (wasClosed, w)
        }

        // Resume all waiters outside of lock to avoid deadlock
        if !waiters.isEmpty {
            wsConnectionLogger.debug("close(): Resuming \(waiters.count) waiters with error")
            for waiter in waiters {
                waiter.resume(throwing: TransportError.connectionClosed)
            }
        }

        // If already closed (e.g., by channelInactive), skip channel.close()
        guard !alreadyClosed else {
            wsConnectionLogger.debug("close(): Already closed, skipping channel close")
            return
        }

        // Send WebSocket close frame and close channel
        if channel.isActive {
            wsConnectionLogger.debug("close(): Sending close frame and closing channel...")
            do {
                var closeData = channel.allocator.buffer(capacity: 2)
                closeData.write(webSocketErrorCode: .normalClosure)
                let maskKey: WebSocketMaskingKey? = isClient ? .random() : nil
                let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: maskKey, data: closeData)
                try await channel.writeAndFlush(closeFrame)
            } catch {
                wsConnectionLogger.debug("close(): Close frame send failed (may already be closed): \(error)")
            }
            do {
                try await channel.close()
                wsConnectionLogger.debug("close(): Channel closed")
            } catch {
                // Channel might have closed between isActive check and close()
                wsConnectionLogger.debug("close(): Channel close threw (may already be closed): \(error)")
            }
        } else {
            wsConnectionLogger.debug("close(): Channel already inactive")
        }
    }

    // Called by WebSocketFrameHandler when data is received
    fileprivate func dataReceived(_ data: ByteBuffer) {
        wsConnectionLogger.debug("dataReceived(): Received \(data.readableBytes) bytes")
        let (waiter, bufferSize) = state.withLock { s -> (CheckedContinuation<ByteBuffer, Error>?, Int) in
            // FIFO: dequeue the first waiter if any
            if !s.readWaiters.isEmpty {
                return (s.readWaiters.removeFirst(), 0)
            } else {
                // Buffer size limit for DoS protection
                if s.readBuffer.readableBytes + data.readableBytes > wsMaxReadBufferSize {
                    return (nil, -1)  // -1 indicates buffer full
                }
                var incoming = data
                s.readBuffer.writeBuffer(&incoming)
                return (nil, s.readBuffer.readableBytes)
            }
        }
        // Log and resume waiter outside of lock to avoid deadlock
        if let waiter = waiter {
            wsConnectionLogger.debug("dataReceived(): Delivering to waiting reader")
            waiter.resume(returning: data)
        } else if bufferSize == -1 {
            wsConnectionLogger.warning("dataReceived(): Buffer full, dropping data")
        } else {
            wsConnectionLogger.debug("dataReceived(): Buffering data (buffer size: \(bufferSize))")
        }
    }

    // Called by WebSocketFrameHandler when channel becomes inactive
    fileprivate func channelInactive() {
        wsConnectionLogger.debug("channelInactive(): Channel became inactive")
        let waiters = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
            state.isClosed = true
            let w = state.readWaiters
            state.readWaiters.removeAll()
            return w
        }
        wsConnectionLogger.debug("channelInactive(): Resuming \(waiters.count) waiters with error")
        for waiter in waiters {
            waiter.resume(throwing: TransportError.connectionClosed)
        }
    }
}

// MARK: - WebSocketFrameHandler

/// Channel handler for reading WebSocket frames and delivering data to connections.
///
/// Handles binary/text frames as data, auto-responds to pings with pongs,
/// and responds to close frames per RFC 6455 (send close response, then close channel).
final class WebSocketFrameHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    let isClient: Bool

    private let state: Mutex<HandlerState>

    private struct HandlerState: Sendable {
        var connection: WebSocketConnection?
        var bufferedData: [ByteBuffer] = []
        var fragmentedMessage: ByteBuffer?
        var isInactive = false
    }

    init(isClient: Bool) {
        self.isClient = isClient
        self.state = Mutex(HandlerState())
        wsConnectionLogger.debug("WebSocketFrameHandler: Initialized (isClient: \(isClient))")
    }

    /// Sets the connection for this handler.
    /// Flushes any buffered data and propagates inactive state.
    func setConnection(_ connection: WebSocketConnection) {
        wsConnectionLogger.debug("WebSocketFrameHandler.setConnection: Setting connection")
        let (buffered, inactive) = state.withLock { s -> ([ByteBuffer], Bool) in
            s.connection = connection
            let b = s.bufferedData
            s.bufferedData.removeAll()
            let i = s.isInactive
            return (b, i)
        }
        for data in buffered {
            wsConnectionLogger.debug("WebSocketFrameHandler: Flushing \(data.readableBytes) buffered bytes")
            connection.dataReceived(data)
        }
        if inactive {
            connection.channelInactive()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .binary, .text:
            // Extract and unmask frame data
            if let maskKey = frame.maskKey {
                frame.data.webSocketUnmask(maskKey)
            }
            if let slice = frame.data.readSlice(length: frame.data.readableBytes) {
                let completedMessage: ByteBuffer? = state.withLock { s -> ByteBuffer? in
                    if frame.fin {
                        if var fragmented = s.fragmentedMessage {
                            var tail = slice
                            fragmented.writeBuffer(&tail)
                            s.fragmentedMessage = nil
                            return fragmented
                        } else {
                            return slice
                        }
                    } else {
                        if var fragmented = s.fragmentedMessage {
                            var chunk = slice
                            fragmented.writeBuffer(&chunk)
                            s.fragmentedMessage = fragmented
                        } else {
                            s.fragmentedMessage = slice
                        }
                        return nil
                    }
                }
                if let message = completedMessage {
                    deliverOrBuffer(message)
                }
            }

        case .continuation:
            if let maskKey = frame.maskKey {
                frame.data.webSocketUnmask(maskKey)
            }
            if let slice = frame.data.readSlice(length: frame.data.readableBytes) {
                let completedMessage: ByteBuffer? = state.withLock { s -> ByteBuffer? in
                    guard var fragmented = s.fragmentedMessage else {
                        return nil
                    }

                    var chunk = slice
                    fragmented.writeBuffer(&chunk)
                    if frame.fin {
                        s.fragmentedMessage = nil
                        return fragmented
                    } else {
                        s.fragmentedMessage = fragmented
                        return nil
                    }
                }
                if let message = completedMessage {
                    deliverOrBuffer(message)
                }
            }

        case .ping:
            // Auto-respond with pong
            var responseData = frame.data
            if let inboundMaskKey = frame.maskKey {
                responseData.webSocketUnmask(inboundMaskKey)
            }
            let pongMaskKey: WebSocketMaskingKey? = isClient ? .random() : nil
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: pongMaskKey, data: responseData)
            context.writeAndFlush(self.wrapOutboundOut(pong), promise: nil)

        case .connectionClose:
            // RFC 6455: send close response frame, then close the channel.
            // channelInactive(context:) will fire naturally after channel.close()
            // and call conn.channelInactive() to clean up waiters.
            wsConnectionLogger.debug("WebSocketFrameHandler.channelRead: Received close frame, sending response")
            var closeData = frame.data
            if let inboundMaskKey = frame.maskKey {
                closeData.webSocketUnmask(inboundMaskKey)
            }
            let closeCode = closeData.readSlice(length: 2) ?? context.channel.allocator.buffer(capacity: 0)
            let responseMaskKey: WebSocketMaskingKey? = isClient ? .random() : nil
            let responseFrame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: responseMaskKey, data: closeCode)
            let loopBoundContext = context.loopBound
            context.writeAndFlush(self.wrapOutboundOut(responseFrame)).whenComplete { _ in
                loopBoundContext.value.close(promise: nil)
            }

        case .pong:
            break // Ignore

        default:
            break // Unknown frames
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        wsConnectionLogger.debug("WebSocketFrameHandler.channelInactive: Channel inactive")
        let conn: WebSocketConnection? = state.withLock { s in
            s.fragmentedMessage = nil
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
        wsConnectionLogger.error("WebSocketFrameHandler.errorCaught: \(error)")
        let conn: WebSocketConnection? = state.withLock { s in
            s.fragmentedMessage = nil
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

    private func deliverOrBuffer(_ message: ByteBuffer) {
        let conn: WebSocketConnection? = state.withLock { s in
            if let connection = s.connection {
                return connection
            } else {
                s.bufferedData.append(message)
                return nil
            }
        }
        if let conn {
            wsConnectionLogger.debug("WebSocketFrameHandler.channelRead: Forwarding \(message.readableBytes) bytes")
            conn.dataReceived(message)
        } else {
            wsConnectionLogger.debug("WebSocketFrameHandler.channelRead: Buffering \(message.readableBytes) bytes")
        }
    }
}

// MARK: - Multiaddr conversion helpers

extension SocketAddress {
    /// Converts a SocketAddress to a WebSocket Multiaddr.
    ///
    /// - Parameter secure: `true` for `/wss`, `false` for `/ws`
    func toWebSocketMultiaddr(secure: Bool = false) -> Multiaddr? {
        switch self {
        case .v4(let addr):
            let ip = addr.host
            let port = UInt16(self.port ?? 0)
            return Multiaddr(uncheckedProtocols: [.ip4(ip), .tcp(port), secure ? .wss : .ws])
        case .v6(let addr):
            let ip = addr.host
            let port = UInt16(self.port ?? 0)
            return Multiaddr(uncheckedProtocols: [.ip6(ip), .tcp(port), secure ? .wss : .ws])
        case .unixDomainSocket:
            return nil
        }
    }
}
