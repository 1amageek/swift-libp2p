/// ResourceManager - System-wide resource accounting protocol
///
/// Provides reserve/release API for connections, streams, and memory
/// with hierarchical scopes (System -> Peer).

import P2PCore

/// System-wide resource manager for accounting connections, streams, and memory.
///
/// ## Usage
///
/// Resource managers enforce limits at two levels:
/// - **System scope**: Global limits across all peers
/// - **Peer scope**: Per-peer limits
///
/// Reservations are atomic: both system and peer limits are checked
/// before any counters are incremented. If either check fails, no
/// mutation occurs.
///
/// ## Reserve/Release Pattern
///
/// Every `reserve*` call must be paired with a corresponding `release*` call
/// when the resource is no longer in use. Failure to release leads to
/// accounting leaks.
public protocol ResourceManager: Sendable {

    /// The system-wide resource scope.
    var systemScope: ResourceScope { get }

    /// Returns the resource scope for a specific peer.
    ///
    /// - Parameter peer: The peer ID
    /// - Returns: The peer's resource scope
    func peerScope(for peer: PeerID) -> ResourceScope

    /// Reserves an inbound connection from a peer.
    ///
    /// Checks both system and peer limits atomically.
    ///
    /// - Parameter peer: The remote peer
    /// - Throws: `ResourceError.limitExceeded` if limits would be exceeded
    func reserveInboundConnection(from peer: PeerID) throws

    /// Reserves an outbound connection to a peer.
    ///
    /// Checks both system and peer limits atomically.
    ///
    /// - Parameter peer: The remote peer
    /// - Throws: `ResourceError.limitExceeded` if limits would be exceeded
    func reserveOutboundConnection(to peer: PeerID) throws

    /// Releases a connection for a peer.
    ///
    /// - Parameters:
    ///   - peer: The remote peer
    ///   - direction: The connection direction
    func releaseConnection(peer: PeerID, direction: ConnectionDirection)

    /// Reserves an inbound stream from a peer.
    ///
    /// Checks both system and peer limits atomically.
    ///
    /// - Parameter peer: The remote peer
    /// - Throws: `ResourceError.limitExceeded` if limits would be exceeded
    func reserveInboundStream(from peer: PeerID) throws

    /// Reserves an outbound stream to a peer.
    ///
    /// Checks both system and peer limits atomically.
    ///
    /// - Parameter peer: The remote peer
    /// - Throws: `ResourceError.limitExceeded` if limits would be exceeded
    func reserveOutboundStream(to peer: PeerID) throws

    /// Releases a stream for a peer.
    ///
    /// - Parameters:
    ///   - peer: The remote peer
    ///   - direction: The stream direction
    func releaseStream(peer: PeerID, direction: ConnectionDirection)

    /// Reserves memory for a peer.
    ///
    /// Checks both system and peer limits atomically.
    ///
    /// - Parameters:
    ///   - bytes: Number of bytes to reserve
    ///   - peer: The remote peer
    /// - Throws: `ResourceError.limitExceeded` if limits would be exceeded
    func reserveMemory(_ bytes: Int, for peer: PeerID) throws

    /// Releases memory for a peer.
    ///
    /// - Parameters:
    ///   - bytes: Number of bytes to release
    ///   - peer: The remote peer
    func releaseMemory(_ bytes: Int, for peer: PeerID)

    /// Returns a point-in-time snapshot of all resource usage.
    func snapshot() -> ResourceSnapshot
}
