/// Error types for DCUtR operations.

import Foundation
import P2PCore

/// Errors for DCUtR operations.
public enum DCUtRError: Error, Sendable {
    /// Protocol message was malformed or unexpected.
    case protocolViolation(String)

    /// Hole punch attempt failed.
    case holePunchFailed(String)

    /// All dial attempts failed.
    case allDialsFailed

    /// No addresses available to dial.
    case noAddresses

    /// Operation timed out.
    case timeout

    /// Not connected via relay (required for DCUtR).
    case notRelayedConnection

    /// Encoding/decoding error.
    case encodingError(String)

    /// Maximum retry attempts exceeded.
    case maxAttemptsExceeded(Error)

    /// The message carried an unknown/unsupported HolePunch type value.
    case unknownMessageType(UInt64)

    /// A multiaddr in the message could not be parsed.
    case invalidAddress(String)

    /// The maximum number of concurrent hole-punch upgrades was reached.
    case concurrencyLimitReached
}
