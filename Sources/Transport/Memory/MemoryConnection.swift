/// MemoryConnection - In-memory RawConnection implementation
///
/// A connection that transfers data via an in-memory channel.

import Foundation
import Synchronization
import P2PCore
import P2PTransport

/// An in-memory connection that implements RawConnection.
///
/// Data written to one end of the connection can be read from the other end.
/// Used for testing without actual network I/O.
///
/// - Important: This connection assumes a single reader pattern. Concurrent calls
///   to `read()` from multiple tasks are not supported and may cause some tasks
///   to wait indefinitely.
public final class MemoryConnection: RawConnection, Sendable {

    /// Errors that can occur with memory connections.
    public enum ConnectionError: Error, Sendable {
        /// The connection is closed.
        case closed
        /// Multiple concurrent reads are not supported.
        case concurrentReadNotSupported
    }

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
    /// - Returns: The data read, or empty Data on EOF from remote
    /// - Throws: `ConnectionError.closed` if the local side has called close(),
    ///           `ConnectionError.concurrentReadNotSupported` if another read is already in progress
    public func read() async throws -> Data {
        let isClosed = state.withLock { $0.isClosed }
        if isClosed {
            throw ConnectionError.closed
        }

        do {
            switch side {
            case .a:
                return try await channel.receiveAtA()
            case .b:
                return try await channel.receiveAtB()
            }
        } catch is MemoryChannelError {
            throw ConnectionError.concurrentReadNotSupported
        }
    }

    /// Writes data to the connection.
    ///
    /// - Parameter data: The data to write
    /// - Throws: `ConnectionError.closed` if the connection is closed (locally or remotely)
    public func write(_ data: Data) async throws {
        let isClosed = state.withLock { $0.isClosed }
        if isClosed {
            throw ConnectionError.closed
        }

        let success: Bool
        switch side {
        case .a:
            success = channel.sendFromA(data)
        case .b:
            success = channel.sendFromB(data)
        }

        // Channel was closed by remote side
        if !success {
            throw ConnectionError.closed
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
