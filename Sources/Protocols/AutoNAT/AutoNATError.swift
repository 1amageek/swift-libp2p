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
