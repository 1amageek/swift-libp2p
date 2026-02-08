/// WebTransport connection abstraction.
///
/// This is a stub implementation that defines the connection interface
/// for WebTransport. The actual HTTP/3 session management will be
/// implemented when HTTP/3 support is available in swift-quic.

import Synchronization
import P2PCore

/// A WebTransport connection over HTTP/3.
///
/// WebTransport connections are established over QUIC with HTTP/3,
/// providing both bidirectional streams and datagrams. Like QUIC,
/// WebTransport provides built-in security (TLS 1.3) and multiplexing.
///
/// ## Connection Lifecycle
///
/// ```
/// connecting -> connected -> closing -> closed
///                  |                      ^
///                  +--- (error) ----------+
/// ```
///
/// ## Current Status
///
/// This is a stub implementation. Actual connection management requires
/// HTTP/3 support in the underlying QUIC library. All attempts to use
/// the connection will result in `WebTransportError.http3NotAvailable`.
public final class WebTransportConnection: Sendable {

    /// The state of a WebTransport connection.
    public enum State: Sendable, Equatable {
        /// The connection is being established (QUIC + HTTP/3 + WebTransport handshake).
        case connecting

        /// The connection is established and ready for use.
        case connected

        /// The connection is gracefully shutting down.
        case closing

        /// The connection is closed.
        case closed
    }

    /// Internal mutable state protected by Mutex.
    private struct ConnectionState: Sendable {
        var state: State
        var localAddress: Multiaddr?
        var remoteAddress: Multiaddr?
        var remotePeerID: PeerID?
    }

    private let connectionState: Mutex<ConnectionState>

    /// The current connection state.
    public var currentState: State {
        connectionState.withLock { $0.state }
    }

    /// The local address of this connection, if known.
    public var localAddress: Multiaddr? {
        connectionState.withLock { $0.localAddress }
    }

    /// The remote address of this connection.
    public var remoteAddress: Multiaddr? {
        connectionState.withLock { $0.remoteAddress }
    }

    /// The remote peer's identity.
    public var remotePeerID: PeerID? {
        connectionState.withLock { $0.remotePeerID }
    }

    /// Creates a new WebTransport connection.
    ///
    /// - Parameters:
    ///   - remoteAddress: The remote peer's multiaddr
    ///   - remotePeerID: The remote peer's identity (if known)
    public init(
        remoteAddress: Multiaddr? = nil,
        remotePeerID: PeerID? = nil
    ) {
        self.connectionState = Mutex(ConnectionState(
            state: .connecting,
            localAddress: nil,
            remoteAddress: remoteAddress,
            remotePeerID: remotePeerID
        ))
    }

    /// Transitions the connection to the connected state.
    ///
    /// Only transitions if the connection is currently in the `.connecting` state.
    /// Calling this method in any other state is a no-op and returns `false`.
    ///
    /// - Parameters:
    ///   - localAddress: The local address once bound
    ///   - remoteAddress: The remote address (may be updated from initial value)
    ///   - remotePeerID: The authenticated remote peer ID
    /// - Returns: `true` if the state was successfully transitioned to `.connected`
    @discardableResult
    internal func markConnected(
        localAddress: Multiaddr?,
        remoteAddress: Multiaddr?,
        remotePeerID: PeerID?
    ) -> Bool {
        connectionState.withLock { state -> Bool in
            guard case .connecting = state.state else { return false }
            state.state = .connected
            state.localAddress = localAddress
            if let remoteAddress {
                state.remoteAddress = remoteAddress
            }
            if let remotePeerID {
                state.remotePeerID = remotePeerID
            }
            return true
        }
    }

    /// Closes the WebTransport connection.
    ///
    /// This performs a graceful shutdown of the WebTransport session,
    /// closing all streams and the underlying HTTP/3 connection.
    ///
    /// - Throws: `WebTransportError` if the close operation fails
    public func close() async throws {
        let alreadyClosed = connectionState.withLock { state -> Bool in
            switch state.state {
            case .closing, .closed:
                return true
            case .connecting, .connected:
                state.state = .closing
                return false
            }
        }

        guard !alreadyClosed else { return }

        // In a full implementation, this would:
        // 1. Send a CLOSE_WEBTRANSPORT_SESSION capsule
        // 2. Close all open streams
        // 3. Close the HTTP/3 session
        // 4. Close the QUIC connection

        connectionState.withLock { state in
            state.state = .closed
        }
    }
}
