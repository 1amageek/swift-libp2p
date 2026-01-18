/// P2PTransport - Transport protocol definitions
///
/// This module defines transport abstractions only.
/// Implementations are in separate modules (P2PTransportTCP, P2PTransportQUIC, etc.)

import P2PCore

/// A transport that can establish connections.
public protocol Transport: Sendable {
    /// The protocols this transport supports (e.g., ["tcp", "ip4"], ["tcp", "ip6"]).
    var protocols: [[String]] { get }

    /// Dials a remote address.
    ///
    /// - Parameter address: The address to dial
    /// - Returns: A raw connection
    func dial(_ address: Multiaddr) async throws -> any RawConnection

    /// Listens on the given address.
    ///
    /// - Parameter address: The address to listen on
    /// - Returns: A listener for incoming connections
    func listen(_ address: Multiaddr) async throws -> any Listener

    /// Checks if this transport can dial the given address.
    func canDial(_ address: Multiaddr) -> Bool

    /// Checks if this transport can listen on the given address.
    func canListen(_ address: Multiaddr) -> Bool
}

/// A listener for incoming connections.
public protocol Listener: Sendable {
    /// The local address this listener is bound to.
    var localAddress: Multiaddr { get }

    /// Accepts the next incoming connection.
    func accept() async throws -> any RawConnection

    /// Closes the listener.
    func close() async throws
}

/// Errors that can occur during transport operations.
public enum TransportError: Error, Sendable {
    case unsupportedAddress(Multiaddr)
    case connectionFailed(underlying: Error)
    case listenerClosed
    case timeout
}
