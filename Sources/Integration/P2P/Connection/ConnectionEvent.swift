/// ConnectionEvent - Connection-related events
///
/// Events emitted by the connection pool for connection lifecycle changes.

import Foundation
import P2PCore

/// Events related to connection lifecycle.
///
/// These events are emitted by the Node to inform about connection
/// state changes, reconnection attempts, and pool management.
public enum ConnectionEvent: Sendable {
    /// A new connection was established.
    ///
    /// - Parameters:
    ///   - peer: The connected peer
    ///   - address: The peer's address
    ///   - direction: Whether we dialed (outbound) or accepted (inbound)
    case connected(peer: PeerID, address: Multiaddr, direction: ConnectionDirection)

    /// A connection was disconnected.
    ///
    /// - Parameters:
    ///   - peer: The disconnected peer
    ///   - reason: Why the connection was closed
    case disconnected(peer: PeerID, reason: DisconnectReason)

    /// Automatic reconnection is starting.
    ///
    /// - Parameters:
    ///   - peer: The peer being reconnected to
    ///   - attempt: Current retry attempt number (1-based)
    ///   - nextDelay: How long until the attempt starts
    case reconnecting(peer: PeerID, attempt: Int, nextDelay: Duration)

    /// Reconnection succeeded.
    ///
    /// - Parameters:
    ///   - peer: The reconnected peer
    ///   - attempt: Which attempt succeeded (1-based)
    case reconnected(peer: PeerID, attempt: Int)

    /// Reconnection failed after all retries.
    ///
    /// - Parameters:
    ///   - peer: The peer that couldn't be reconnected
    ///   - attempts: Total number of attempts made
    case reconnectionFailed(peer: PeerID, attempts: Int)

    /// A connection was trimmed due to resource limits.
    ///
    /// - Parameters:
    ///   - peer: The peer whose connection was trimmed
    ///   - reason: Why this connection was selected for trimming
    case trimmed(peer: PeerID, reason: String)

    /// Health check failed for a peer.
    ///
    /// This is emitted when ping failures exceed the threshold.
    ///
    /// - Parameter peer: The peer that failed health checks
    case healthCheckFailed(peer: PeerID)

    /// A connection was rejected by the gater.
    ///
    /// - Parameters:
    ///   - peer: The peer ID if known (may be nil for dial/accept stages)
    ///   - address: The address that was gated
    ///   - stage: At which stage the connection was rejected
    case gated(peer: PeerID?, address: Multiaddr, stage: GateStage)
}

// MARK: - Convenience Properties

extension ConnectionEvent {
    /// The peer associated with this event, if any.
    public var peer: PeerID? {
        switch self {
        case .connected(let peer, _, _),
             .disconnected(let peer, _),
             .reconnecting(let peer, _, _),
             .reconnected(let peer, _),
             .reconnectionFailed(let peer, _),
             .trimmed(let peer, _),
             .healthCheckFailed(let peer):
            return peer
        case .gated(let peer, _, _):
            return peer
        }
    }

    /// Whether this is a positive event (connection established/restored).
    public var isPositive: Bool {
        switch self {
        case .connected, .reconnected:
            return true
        default:
            return false
        }
    }

    /// Whether this is a negative event (connection lost/failed).
    public var isNegative: Bool {
        switch self {
        case .disconnected, .reconnectionFailed, .trimmed, .healthCheckFailed, .gated:
            return true
        default:
            return false
        }
    }
}

// MARK: - CustomStringConvertible

extension ConnectionEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connected(let peer, let address, let direction):
            return "connected(\(peer), \(address), \(direction))"
        case .disconnected(let peer, let reason):
            return "disconnected(\(peer), \(reason))"
        case .reconnecting(let peer, let attempt, let delay):
            return "reconnecting(\(peer), attempt: \(attempt), delay: \(delay))"
        case .reconnected(let peer, let attempt):
            return "reconnected(\(peer), attempt: \(attempt))"
        case .reconnectionFailed(let peer, let attempts):
            return "reconnectionFailed(\(peer), attempts: \(attempts))"
        case .trimmed(let peer, let reason):
            return "trimmed(\(peer), reason: \(reason))"
        case .healthCheckFailed(let peer):
            return "healthCheckFailed(\(peer))"
        case .gated(let peer, let address, let stage):
            return "gated(\(peer?.description ?? "unknown"), \(address), \(stage))"
        }
    }
}
