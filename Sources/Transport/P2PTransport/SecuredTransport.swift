/// SecuredTransport - Transport that provides pre-secured, pre-multiplexed connections.
///
/// Some transports like QUIC have built-in TLS 1.3 security and native stream
/// multiplexing. These transports bypass the standard libp2p upgrade pipeline
/// (Security → Muxer) and return MuxedConnection directly.

import P2PCore
import P2PMux

/// A transport that provides pre-secured, pre-multiplexed connections.
///
/// QUIC implements this protocol because it has built-in TLS 1.3 security
/// and native stream multiplexing. When a transport conforms to this protocol,
/// the Node will bypass the standard upgrade pipeline and use these methods instead.
///
/// ## Usage
///
/// ```swift
/// // In Node, check if transport is SecuredTransport
/// if let securedTransport = transport as? SecuredTransport {
///     let connection = try await securedTransport.dialSecured(
///         address,
///         localKeyPair: keyPair
///     )
///     // connection is already secured and multiplexed
/// }
/// ```
public protocol SecuredTransport: Transport {

    /// Dials a remote address and returns a secured, multiplexed connection directly.
    ///
    /// This method bypasses the standard upgrade pipeline because the transport
    /// provides built-in security and multiplexing.
    ///
    /// - Parameters:
    ///   - address: The address to dial
    ///   - localKeyPair: The local key pair for identity
    /// - Returns: A secured, multiplexed connection
    func dialSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any MuxedConnection

    /// Listens on the given address and returns a listener for secured connections.
    ///
    /// - Parameters:
    ///   - address: The address to listen on
    ///   - localKeyPair: The local key pair for identity
    /// - Returns: A listener that yields secured, multiplexed connections
    func listenSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any SecuredListener
}

/// A listener that yields pre-secured, pre-multiplexed connections.
///
/// This is used by SecuredTransport implementations like QUIC where
/// incoming connections are already secured and multiplexed.
public protocol SecuredListener: Sendable {

    /// The local address this listener is bound to.
    var localAddress: Multiaddr { get }

    /// Stream of incoming secured, multiplexed connections.
    ///
    /// Each connection yielded is already authenticated and ready for use.
    var connections: AsyncStream<any MuxedConnection> { get }

    /// Closes the listener.
    func close() async throws
}
