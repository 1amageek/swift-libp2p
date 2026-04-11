/// DisconnectReason - Reasons for connection disconnection
///
/// Provides detailed information about why a connection was closed.

/// Error codes for disconnect reasons.
///
/// Used for stable equality comparison of error-based disconnects.
public enum DisconnectErrorCode: Sendable, Equatable {
    /// Error in transport layer.
    case transportError
    /// Error in security handshake.
    case securityError
    /// Error in muxer.
    case muxerError
    /// Error in protocol negotiation.
    case protocolError
    /// Internal error.
    case internalError
    /// Unknown error.
    case unknown
}

/// The stage at which a connection was gated (rejected).
public enum GateStage: Sendable, Equatable {
    /// Gated before dialing.
    case dial
    /// Gated when accepting inbound connection.
    case accept
    /// Gated after security handshake.
    case secured
}

/// The reason a connection was disconnected.
///
/// ## Equality
/// For `.error` cases, equality is based on the error code, not the message.
/// This allows stable comparison without relying on error message strings.
public enum DisconnectReason: Sendable, Equatable {
    /// Connection was closed locally.
    case localClose

    /// Connection was closed by the remote peer.
    case remoteClose

    /// Connection timed out.
    case timeout

    /// Connection was closed due to idle timeout.
    case idleTimeout

    /// Health check failed (ping failures exceeded threshold).
    case healthCheckFailed

    /// Connection was closed due to connection limit exceeded.
    case connectionLimitExceeded

    /// Connection was rejected by gater.
    case gated(stage: GateStage)

    /// Connection failed with an error.
    ///
    /// - Parameters:
    ///   - code: The error code for stable comparison
    ///   - message: Human-readable error description
    case error(code: DisconnectErrorCode, message: String)

    // MARK: - Equatable

    public static func == (lhs: DisconnectReason, rhs: DisconnectReason) -> Bool {
        switch (lhs, rhs) {
        case (.localClose, .localClose),
             (.remoteClose, .remoteClose),
             (.timeout, .timeout),
             (.idleTimeout, .idleTimeout),
             (.healthCheckFailed, .healthCheckFailed),
             (.connectionLimitExceeded, .connectionLimitExceeded):
            return true
        case (.gated(let lStage), .gated(let rStage)):
            return lStage == rStage
        case (.error(let lCode, _), .error(let rCode, _)):
            // Compare by code only, not message
            return lCode == rCode
        default:
            return false
        }
    }
}

// MARK: - CustomStringConvertible

extension DisconnectReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .localClose:
            return "local close"
        case .remoteClose:
            return "remote close"
        case .timeout:
            return "timeout"
        case .idleTimeout:
            return "idle timeout"
        case .healthCheckFailed:
            return "health check failed"
        case .connectionLimitExceeded:
            return "connection limit exceeded"
        case .gated(let stage):
            return "gated at \(stage)"
        case .error(let code, let message):
            return "error(\(code)): \(message)"
        }
    }
}
