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
        self.state = Mutex(ConnectionState())
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

    /// Returns an async stream of incoming streams.
    ///
    /// This stream yields MuxedStreams as they are opened by the remote peer.
    /// The stream completes when the connection is closed.
    public var inboundStreams: AsyncStream<MuxedStream> {
        AsyncStream { continuation in
            state.withLock { $0.inboundContinuation = continuation }

            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                for await quicStream in self.quicConnection.incomingStreams {
                    let muxedStream = QUICMuxedStream(stream: quicStream)
                    continuation.yield(muxedStream)
                }

                continuation.finish()
                self.state.withLock { $0.inboundContinuation = nil }
            }
        }
    }

    /// Closes all streams and the connection.
    public func close() async throws {
        let alreadyClosed = state.withLock { s in
            let was = s.isClosed
            s.isClosed = true
            s.inboundContinuation?.finish()
            s.inboundContinuation = nil
            return was
        }

        guard !alreadyClosed else { return }

        await quicConnection.close(error: nil)
    }
}

// MARK: - CustomStringConvertible

extension QUICMuxedConnection: CustomStringConvertible {
    public var description: String {
        "QUICMuxedConnection(local: \(localPeer), remote: \(remotePeer), address: \(remoteAddress))"
    }
}
