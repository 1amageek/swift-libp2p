/// TCPConnection - NIO Channel wrapper for RawConnection
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import Synchronization

/// Internal state for TCPConnection.
private struct TCPConnectionState: Sendable {
    var readBuffer: [UInt8] = []
    var readContinuation: CheckedContinuation<Data, Error>?
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

    /// Creates a TCPConnection from a channel.
    init(channel: Channel, localAddress: Multiaddr?, remoteAddress: Multiaddr) {
        self.channel = channel
        self._localAddress = localAddress
        self._remoteAddress = remoteAddress

        // Set up the channel pipeline for reading
        _ = channel.pipeline.addHandler(TCPReadHandler(connection: self))
    }

    public func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if state.isClosed {
                    continuation.resume(throwing: TransportError.connectionClosed)
                    return
                }

                if !state.readBuffer.isEmpty {
                    let data = Data(state.readBuffer)
                    state.readBuffer.removeAll()
                    continuation.resume(returning: data)
                } else {
                    state.readContinuation = continuation
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer)
    }

    public func close() async throws {
        let continuation = state.withLock { state -> CheckedContinuation<Data, Error>? in
            state.isClosed = true
            let cont = state.readContinuation
            state.readContinuation = nil
            return cont
        }
        // Resume continuation outside of lock to avoid deadlock
        continuation?.resume(throwing: TransportError.connectionClosed)
        try await channel.close()
    }

    // Called by TCPReadHandler when data is received
    fileprivate func dataReceived(_ data: [UInt8]) {
        let continuation = state.withLock { state -> CheckedContinuation<Data, Error>? in
            if let cont = state.readContinuation {
                state.readContinuation = nil
                return cont
            } else {
                state.readBuffer.append(contentsOf: data)
                return nil
            }
        }
        // Resume continuation outside of lock to avoid deadlock
        continuation?.resume(returning: Data(data))
    }

    // Called by TCPReadHandler when channel becomes inactive
    fileprivate func channelInactive() {
        let continuation = state.withLock { state -> CheckedContinuation<Data, Error>? in
            state.isClosed = true
            let cont = state.readContinuation
            state.readContinuation = nil
            return cont
        }
        // Resume continuation outside of lock to avoid deadlock
        continuation?.resume(throwing: TransportError.connectionClosed)
    }
}

// MARK: - TCPReadHandler

// NIO ChannelHandler requires @unchecked Sendable due to framework requirements
private final class TCPReadHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private weak var connection: TCPConnection?

    init(connection: TCPConnection) {
        self.connection = connection
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            connection?.dataReceived(bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection?.channelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        connection?.channelInactive()
        context.close(promise: nil)
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
