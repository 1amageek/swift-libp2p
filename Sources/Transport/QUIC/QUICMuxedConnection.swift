/// QUIC Connection wrapper implementing MuxedConnection protocol.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import QUIC

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
public final class QUICMuxedConnection: MuxedConnection, Sendable {

    private let quicConnection: any QUICConnectionProtocol
    private let _localPeer: PeerID
    private let _remotePeer: PeerID
    private let _localAddress: Multiaddr?
    private let _remoteAddress: Multiaddr

    private let state: Mutex<ConnectionState>

    private struct ConnectionState: Sendable {
        var isClosed: Bool = false
        var inboundContinuation: AsyncStream<MuxedStream>.Continuation?
        var forwardingTask: Task<Void, Never>?
    }

    /// Incoming streams from the remote peer.
    /// This stream is created once and should be consumed by a single consumer.
    public let inboundStreams: AsyncStream<MuxedStream>

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

        // Create AsyncStream once in init
        let (stream, continuation) = AsyncStream<MuxedStream>.makeStream()
        self.inboundStreams = stream

        var initialState = ConnectionState()
        initialState.inboundContinuation = continuation
        self.state = Mutex(initialState)
    }

    /// Starts forwarding incoming streams from the QUIC connection.
    ///
    /// This method must be called after initialization to begin
    /// yielding streams to the `inboundStreams` AsyncStream.
    public func startForwarding() {
        let task = Task { [weak self] in
            guard let self = self else { return }

            for await quicStream in self.quicConnection.incomingStreams {
                let muxedStream = QUICMuxedStream(stream: quicStream)
                let shouldYield = self.state.withLock { s -> Bool in
                    guard !s.isClosed else { return false }
                    s.inboundContinuation?.yield(muxedStream)
                    return true
                }
                if !shouldYield { break }
            }

            self.state.withLock { s in
                s.inboundContinuation?.finish()
                s.inboundContinuation = nil
            }
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
    /// - Returns: The next incoming MuxedStream.
    /// - Throws: Error if accept fails or connection is closed.
    public func acceptStream() async throws -> MuxedStream {
        let quicStream = try await quicConnection.acceptStream()
        return QUICMuxedStream(stream: quicStream)
    }

    /// Closes all streams and the connection.
    public func close() async throws {
        let (alreadyClosed, task) = state.withLock { s -> (Bool, Task<Void, Never>?) in
            let was = s.isClosed
            s.isClosed = true
            s.inboundContinuation?.finish()
            s.inboundContinuation = nil
            let t = s.forwardingTask
            s.forwardingTask = nil
            return (was, t)
        }

        guard !alreadyClosed else { return }

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
