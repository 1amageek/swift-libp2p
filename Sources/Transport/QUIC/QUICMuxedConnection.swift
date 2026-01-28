/// QUIC Connection wrapper implementing MuxedConnection protocol.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import QUIC

/// Async channel for buffering and distributing streams.
///
/// This class provides a simple producer-consumer pattern for streams.
/// The producer calls `send()` to add streams, consumers call `receive()`
/// to get them. Multiple consumers are supported and will receive streams
/// in FIFO order.
///
/// This is essentially a simplified AsyncChannel implementation using
/// `Mutex` for thread-safe access and `CheckedContinuation` for async waiting.
private final class StreamChannel: Sendable {
    private struct State: Sendable {
        var buffer: [MuxedStream] = []
        var waiters: [CheckedContinuation<MuxedStream?, Never>] = []
        var isFinished = false
    }

    private let state = Mutex(State())

    /// Sends a stream to the channel.
    /// If there are waiting receivers, the first one gets the stream.
    /// Otherwise, the stream is buffered.
    func send(_ stream: MuxedStream) {
        let waiterToResume: CheckedContinuation<MuxedStream?, Never>? = state.withLock { s in
            guard !s.isFinished else { return nil }
            if !s.waiters.isEmpty {
                return s.waiters.removeFirst()
            } else {
                s.buffer.append(stream)
                return nil
            }
        }
        waiterToResume?.resume(returning: stream)
    }

    /// Finishes the channel, resuming all waiters with nil.
    func finish() {
        let waitersToResume: [CheckedContinuation<MuxedStream?, Never>] = state.withLock { s in
            guard !s.isFinished else { return [] }
            s.isFinished = true
            let waiters = s.waiters
            s.waiters.removeAll()
            return waiters
        }
        for waiter in waitersToResume {
            waiter.resume(returning: nil)
        }
    }

    /// Receives the next stream from the channel.
    /// Waits if no streams are available.
    /// Returns nil if the channel is finished.
    func receive() async -> MuxedStream? {
        // Use an enum to track what action to take after the lock
        enum Action {
            case returnStream(MuxedStream)
            case returnNil
            case wait
        }

        return await withCheckedContinuation { continuation in
            let action: Action = state.withLock { s in
                // If there's a buffered stream, return it immediately
                if !s.buffer.isEmpty {
                    return .returnStream(s.buffer.removeFirst())
                }
                // If finished and no buffered streams, return nil
                if s.isFinished {
                    return .returnNil
                }
                // Otherwise, register as waiter
                s.waiters.append(continuation)
                return .wait
            }

            switch action {
            case .returnStream(let stream):
                continuation.resume(returning: stream)
            case .returnNil:
                continuation.resume(returning: nil)
            case .wait:
                // Continuation is stored in waiters, will be resumed by send() or finish()
                break
            }
        }
    }
}

/// A QUIC connection wrapped as a MuxedConnection.
///
/// This class wraps a `QUICConnectionProtocol` to conform to the libp2p
/// `MuxedConnection` protocol. Unlike TCP connections, QUIC connections
/// are already secured and multiplexed, so this wrapper directly exposes
/// the underlying QUIC streams as MuxedStreams.
///
/// ## Design Notes
///
/// QUIC provides native stream multiplexing and TLS 1.3 security, so:
/// - No SecurityUpgrader is needed (TLS is built into QUIC)
/// - No Muxer is needed (streams are native to QUIC)
/// - PeerID is extracted from the TLS certificate
///
/// ## Stream Consumption
///
/// Both `inboundStreams` and `acceptStream()` consume from the same internal
/// channel. Use ONE of the following patterns, not both:
///
/// - Use `for await stream in connection.inboundStreams { ... }` to iterate
/// - Use `let stream = try await connection.acceptStream()` repeatedly
///
/// Mixing these patterns will cause streams to be split between consumers.
public final class QUICMuxedConnection: MuxedConnection, Sendable {

    private let quicConnection: any QUICConnectionProtocol
    private let _localPeer: PeerID
    private let _remotePeer: PeerID
    private let _localAddress: Multiaddr?
    private let _remoteAddress: Multiaddr

    private let state: Mutex<ConnectionState>
    private let streamChannel: StreamChannel

    private struct ConnectionState: Sendable {
        var isClosed: Bool = false
        var forwardingTask: Task<Void, Never>?
        var inboundStream: AsyncStream<MuxedStream>?
    }

    /// Incoming streams from the remote peer.
    ///
    /// - Note: This property and `acceptStream()` consume from the same source.
    ///   Use only one pattern per connection.
    public var inboundStreams: AsyncStream<MuxedStream> {
        state.withLock { s in
            if let existing = s.inboundStream {
                return existing
            }
            let stream = AsyncStream<MuxedStream> { continuation in
                Task { [streamChannel] in
                    while let stream = await streamChannel.receive() {
                        continuation.yield(stream)
                    }
                    continuation.finish()
                }
            }
            s.inboundStream = stream
            return stream
        }
    }

    /// The local peer ID.
    public var localPeer: PeerID { _localPeer }

    /// The remote peer ID.
    public var remotePeer: PeerID { _remotePeer }

    /// The local address (if known).
    public var localAddress: Multiaddr? { _localAddress }

    /// The remote address.
    public var remoteAddress: Multiaddr { _remoteAddress }

    /// Creates a new QUICMuxedConnection.
    ///
    /// - Parameters:
    ///   - quicConnection: The underlying QUIC connection
    ///   - localPeer: The local peer ID
    ///   - remotePeer: The remote peer ID (extracted from TLS certificate)
    ///   - localAddress: The local multiaddr (if known)
    ///   - remoteAddress: The remote multiaddr
    public init(
        quicConnection: any QUICConnectionProtocol,
        localPeer: PeerID,
        remotePeer: PeerID,
        localAddress: Multiaddr?,
        remoteAddress: Multiaddr
    ) {
        self.quicConnection = quicConnection
        self._localPeer = localPeer
        self._remotePeer = remotePeer
        self._localAddress = localAddress
        self._remoteAddress = remoteAddress
        self.streamChannel = StreamChannel()
        self.state = Mutex(ConnectionState())
    }

    /// Starts forwarding incoming streams from the QUIC connection.
    ///
    /// This method must be called after initialization to begin
    /// sending streams to the internal channel for consumption by
    /// `inboundStreams` or `acceptStream()`.
    public func startForwarding() {
        let task = Task { [weak self] in
            guard let self = self else { return }

            for await quicStream in self.quicConnection.incomingStreams {
                let isClosed = self.state.withLock { $0.isClosed }
                if isClosed { break }

                let muxedStream = QUICMuxedStream(stream: quicStream)
                self.streamChannel.send(muxedStream)
            }

            self.streamChannel.finish()
        }

        state.withLock { $0.forwardingTask = task }
    }

    // MARK: - MuxedConnection

    /// Opens a new outbound stream.
    ///
    /// - Returns: A new MuxedStream.
    /// - Throws: Error if stream creation fails.
    public func newStream() async throws -> MuxedStream {
        let quicStream = try await quicConnection.openStream()
        return QUICMuxedStream(stream: quicStream)
    }

    /// Accepts an incoming stream.
    ///
    /// This consumes from the internal channel that is populated by `startForwarding()`.
    /// Multiple calls to `acceptStream()` are safe and will return streams in FIFO order.
    ///
    /// - Note: `acceptStream()` and direct iteration of `inboundStreams` consume from
    ///   the same source. Use one pattern or the other, not both.
    ///
    /// - Returns: The next incoming MuxedStream.
    /// - Throws: Error if accept fails or connection is closed.
    public func acceptStream() async throws -> MuxedStream {
        guard let stream = await streamChannel.receive() else {
            throw QUICTransportError.connectionClosed
        }
        return stream
    }

    /// Closes all streams and the connection.
    public func close() async throws {
        let (alreadyClosed, task) = state.withLock { s -> (Bool, Task<Void, Never>?) in
            let was = s.isClosed
            s.isClosed = true
            let t = s.forwardingTask
            s.forwardingTask = nil
            return (was, t)
        }

        guard !alreadyClosed else { return }

        streamChannel.finish()
        task?.cancel()
        await quicConnection.close(error: nil)
    }
}

// MARK: - CustomStringConvertible

extension QUICMuxedConnection: CustomStringConvertible {
    public var description: String {
        "QUICMuxedConnection(local: \(localPeer), remote: \(remotePeer), address: \(remoteAddress))"
    }
}
