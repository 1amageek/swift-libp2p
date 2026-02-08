/// AutoNATv2Error - Error types for AutoNAT v2 protocol.

import Foundation
import P2PCore

/// Errors that can occur during AutoNAT v2 operations.
public enum AutoNATv2Error: Error, Sendable, Equatable {
    /// Protocol violation (unexpected message format or sequence).
    case protocolViolation(String)

    /// The request was rate limited (cooldown period not elapsed).
    case rateLimited(peer: PeerID)

    /// Nonce verification failed (received nonce does not match expected).
    case nonceVerificationFailed

    /// Nonce has expired and was cleaned up.
    case nonceExpired

    /// The dial-back connection failed.
    case dialBackFailed(String)

    /// Request timeout.
    case timeout

    /// Service has been shut down.
    case serviceShutdown

    /// No address provided for the check.
    case noAddress
}
