/// MemoryConnection - In-memory RawConnection implementation
///
/// A connection that transfers data via an in-memory channel.

import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PTransport

/// Internal error detail for memory connection failures.
internal enum MemoryConnectionDetailError: Error, CustomStringConvertible, Sendable {
    /// The peer's receive buffer is full (backpressure; the peer is not reading).
    case receiveBufferFull
    var description: String {
        switch self {
        case .receiveBufferFull: return "Peer receive buffer is full (backpressure)"
        }
    }
}

/// An in-memory connection that implements RawConnection.
///
/// Data written to one end of the connection can be read from the other end.
/// Used for testing without actual network I/O.
///
/// - Important: This connection assumes a single reader pattern. Concurrent calls
///   to `read()` from multiple tasks are not supported and will throw
///   `TransportError.unsupportedOperation`.
public final class MemoryConnection: RawConnection, Sendable {

    /// Which side of the channel this connection represents.
    internal enum Side: Sendable {
        case a
        case b
    }

    /// The local address of this connection.
    public let localAddress: Multiaddr?

    /// The remote address of this connection.
    public let remoteAddress: Multiaddr

    /// The underlying channel.
    private let channel: MemoryChannel

    /// Which side of the channel this is.
    private let side: Side

    /// Connection state.
    private let state: Mutex<ConnectionState>

    private struct ConnectionState: Sendable {
        var isClosed = false
    }

    /// Creates a new memory connection.
    ///
    /// - Parameters:
    ///   - localAddress: The local address
    ///   - remoteAddress: The remote address
    ///   - channel: The underlying memory channel
    ///   - side: Which side of the channel this connection is on
    internal init(
        localAddress: Multiaddr?,
        remoteAddress: Multiaddr,
        channel: MemoryChannel,
        side: Side
    ) {
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.channel = channel
        self.side = side
        self.state = Mutex(ConnectionState())
    }

    /// Reads data from the connection.
    ///
    /// - Returns: The data read, or empty ByteBuffer on EOF from remote
    /// - Throws: `TransportError.connectionClosed` if the local side has called close(),
    ///           `TransportError.unsupportedOperation` if another read is already in progress
    public func read() async throws -> ByteBuffer {
        let isClosed = state.withLock { $0.isClosed }
        if isClosed {
            throw TransportError.connectionClosed
        }

        do {
            switch side {
            case .a:
                return try await channel.receiveAtA()
            case .b:
                return try await channel.receiveAtB()
            }
        } catch is MemoryChannelError {
            throw TransportError.unsupportedOperation("concurrent read not supported")
        }
    }

    /// Writes data to the connection.
    ///
    /// - Parameter data: The data to write
    /// - Throws: `TransportError.connectionClosed` if the connection is closed
    ///   (locally or remotely); `TransportError.connectionFailed` wrapping
    ///   `MemoryConnectionDetailError.receiveBufferFull` if the peer's receive
    ///   buffer is full (backpressure — the peer is not reading).
    public func write(_ data: ByteBuffer) async throws {
        let isClosed = state.withLock { $0.isClosed }
        if isClosed {
            throw TransportError.connectionClosed
        }

        let result: MemorySendResult
        switch side {
        case .a:
            result = channel.sendFromA(data)
        case .b:
            result = channel.sendFromB(data)
        }

        switch result {
        case .accepted:
            return
        case .closed:
            // Channel was closed by remote side
            throw TransportError.connectionClosed
        case .bufferFull:
            // Peer is not draining; surface backpressure explicitly rather than
            // buffering unboundedly (memory-exhaustion DoS) or dropping silently.
            throw TransportError.connectionFailed(
                underlying: MemoryConnectionDetailError.receiveBufferFull
            )
        }
    }

    /// Closes the connection (full close - both directions).
    ///
    /// After close, both read() and write() will fail.
    /// The remote side will receive EOF on their next read().
    public func close() async throws {
        let wasClosed = state.withLock { state -> Bool in
            let was = state.isClosed
            state.isClosed = true
            return was
        }

        if wasClosed { return }

        // Full close - close both directions so remote gets EOF
        // and cannot send more data
        channel.close()
    }

    // MARK: - Factory

    /// Creates a pair of connected memory connections.
    ///
    /// Data written to one connection can be read from the other.
    ///
    /// - Parameters:
    ///   - localAddress: The address for the local (A) side
    ///   - remoteAddress: The address for the remote (B) side
    /// - Returns: A tuple of (local, remote) connections
    public static func makePair(
        localAddress: Multiaddr,
        remoteAddress: Multiaddr
    ) -> (local: MemoryConnection, remote: MemoryConnection) {
        let channel = MemoryChannel()

        let local = MemoryConnection(
            localAddress: localAddress,
            remoteAddress: remoteAddress,
            channel: channel,
            side: .a
        )

        let remote = MemoryConnection(
            localAddress: remoteAddress,
            remoteAddress: localAddress,
            channel: channel,
            side: .b
        )

        return (local, remote)
    }
}
