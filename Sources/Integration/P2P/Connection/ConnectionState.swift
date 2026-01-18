/// ConnectionState - Connection state machine
///
/// Represents the current state of a connection in its lifecycle.

import Foundation

/// The state of a connection.
///
/// ## State Machine
/// ```
/// Idle → Connecting → Connected → Disconnected → Reconnecting → ...
///                                      ↓
///                                   Failed
/// ```
///
/// - `connecting`: Connection attempt in progress
/// - `connected`: Connection established and active
/// - `disconnected`: Connection closed but may reconnect
/// - `reconnecting`: Automatic reconnection in progress
/// - `failed`: Connection permanently failed (no more retries)
public enum ConnectionState: Sendable {
    /// Connection attempt is in progress.
    case connecting

    /// Connection is established and active.
    case connected

    /// Connection was disconnected.
    ///
    /// May transition to `reconnecting` if auto-reconnect is enabled.
    case disconnected(reason: DisconnectReason)

    /// Automatic reconnection is in progress.
    ///
    /// - Parameters:
    ///   - attempt: Current retry attempt number (1-based)
    ///   - nextAttempt: When the next attempt will be made
    case reconnecting(attempt: Int, nextAttempt: ContinuousClock.Instant)

    /// Connection has permanently failed.
    ///
    /// This occurs when max retry attempts are exceeded or
    /// reconnection is disabled.
    case failed(reason: DisconnectReason)
}

// MARK: - Convenience Properties

extension ConnectionState {
    /// Whether this connection is currently active.
    public var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    /// Whether this connection is attempting to connect or reconnect.
    public var isConnecting: Bool {
        switch self {
        case .connecting, .reconnecting:
            return true
        default:
            return false
        }
    }

    /// Whether this connection has failed permanently.
    public var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    /// Whether this connection is disconnected (not failed).
    public var isDisconnected: Bool {
        if case .disconnected = self {
            return true
        }
        return false
    }

    /// The disconnect reason, if applicable.
    public var disconnectReason: DisconnectReason? {
        switch self {
        case .disconnected(let reason), .failed(let reason):
            return reason
        default:
            return nil
        }
    }

    /// The current reconnection attempt number, if reconnecting.
    public var reconnectAttempt: Int? {
        if case .reconnecting(let attempt, _) = self {
            return attempt
        }
        return nil
    }
}

// MARK: - CustomStringConvertible

extension ConnectionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected(let reason):
            return "disconnected(\(reason))"
        case .reconnecting(let attempt, _):
            return "reconnecting(attempt: \(attempt))"
        case .failed(let reason):
            return "failed(\(reason))"
        }
    }
}
