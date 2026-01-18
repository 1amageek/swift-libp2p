import Foundation

/// A secured connection after security handshake.
///
/// This protocol represents a connection that has been upgraded
/// with encryption and mutual authentication.
public protocol SecuredConnection: Sendable {
    /// The local peer ID.
    var localPeer: PeerID { get }

    /// The remote peer ID.
    var remotePeer: PeerID { get }

    /// The local address (may be nil for some transports).
    var localAddress: Multiaddr? { get }

    /// The remote address.
    var remoteAddress: Multiaddr { get }

    /// Reads decrypted data from the connection.
    func read() async throws -> Data

    /// Writes data to the connection (will be encrypted).
    func write(_ data: Data) async throws

    /// Closes the connection.
    func close() async throws
}

/// The role in a security handshake.
public enum SecurityRole: Sendable {
    case initiator
    case responder
}
