/// SecuredTransport - bridge for transports that are already secured and multiplexed.
///
/// QUIC, WebRTC, and WebTransport bring their own security and stream
/// multiplexing. They bypass the raw Transport -> Security -> Muxer pipeline
/// and return MuxedConnection directly.

import P2PCore
import P2PTransport
import P2PMux

/// A transport that provides pre-secured, pre-multiplexed connections.
///
/// This protocol intentionally lives outside `P2PTransport`: raw transport
/// definitions must not depend on the mux layer, while this bridge is exactly
/// the place where transport selection meets stream-session semantics.
public protocol SecuredTransport: Transport {

    /// Dials a remote address and returns a secured, multiplexed connection directly.
    ///
    /// This method bypasses the standard upgrade pipeline because the transport
    /// provides built-in security and multiplexing.
    ///
    /// - Parameters:
    ///   - address: The address to dial.
    ///   - localKeyPair: The local key pair for identity.
    /// - Returns: A secured, multiplexed connection.
    func dialSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any MuxedConnection

    /// Listens on the given address and returns a listener for secured connections.
    ///
    /// - Parameters:
    ///   - address: The address to listen on.
    ///   - localKeyPair: The local key pair for identity.
    /// - Returns: A listener that yields secured, multiplexed connections.
    func listenSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any SecuredListener
}

/// A listener that yields pre-secured, pre-multiplexed connections.
///
/// This is used by SecuredTransport implementations where incoming
/// connections are already authenticated and ready for stream use.
public protocol SecuredListener: Sendable {

    /// The local address this listener is bound to.
    var localAddress: Multiaddr { get }

    /// Stream of incoming secured, multiplexed connections.
    var connections: AsyncStream<any MuxedConnection> { get }

    /// Closes the listener.
    func close() async throws
}
