/// AutoNATError - Error types for AutoNAT protocol.

import Foundation
import P2PCore

/// Errors that can occur during AutoNAT operations.
public enum AutoNATError: Error, Sendable, Equatable {
    /// Protocol violation (unexpected message format or sequence).
    case protocolViolation(String)

    /// Dial-back failed.
    case dialFailed(String)

    /// Dial was refused by the server.
    case dialRefused

    /// Bad request from client.
    case badRequest(String)

    /// Internal server error.
    case internalError(String)

    /// Request timeout.
    case timeout

    /// No servers available for probing.
    case noServersAvailable

    /// Not enough probes to determine status.
    case insufficientProbes

    /// Request was rate limited.
    case rateLimited(RateLimitReason)

    /// Peer ID in dial request does not match the remote peer.
    case peerIDMismatch

    /// Port not allowed for dial-back.
    case portNotAllowed(UInt16)
}

/// Reasons for rate limiting a request.
public enum RateLimitReason: Sendable, Equatable, CustomStringConvertible {
    /// Global rate limit exceeded.
    case globalRateLimit

    /// Global concurrent dial limit exceeded.
    case globalConcurrencyLimit

    /// Per-peer rate limit exceeded.
    case peerRateLimit

    /// Per-peer concurrent dial limit exceeded.
    case peerConcurrencyLimit

    /// Peer is in backoff period after previous rejection.
    case backoff

    public var description: String {
        switch self {
        case .globalRateLimit:
            return "Global rate limit exceeded"
        case .globalConcurrencyLimit:
            return "Global concurrency limit exceeded"
        case .peerRateLimit:
            return "Per-peer rate limit exceeded"
        case .peerConcurrencyLimit:
            return "Per-peer concurrency limit exceeded"
        case .backoff:
            return "Peer is in backoff period"
        }
    }
}

/// Response status codes for AutoNAT dial response.
public enum AutoNATResponseStatus: UInt32, Sendable, Hashable {
    /// Dial succeeded.
    case ok = 0

    /// Dial failed (could not connect).
    case dialError = 100

    /// Dial was refused (policy).
    case dialRefused = 101

    /// Bad request (malformed message).
    case badRequest = 200

    /// Internal server error.
    case internalError = 300

    /// Unknown status.
    case unknown = 999

    /// Creates a status from a raw value.
    public init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .ok
        case 100: self = .dialError
        case 101: self = .dialRefused
        case 200: self = .badRequest
        case 300: self = .internalError
        default: self = .unknown
        }
    }

    /// Converts to an error (if not OK).
    public var asError: AutoNATError? {
        switch self {
        case .ok: return nil
        case .dialError: return .dialFailed("Dial error")
        case .dialRefused: return .dialRefused
        case .badRequest: return .badRequest("Bad request")
        case .internalError: return .internalError("Internal error")
        case .unknown: return .internalError("Unknown status")
        }
    }
}
