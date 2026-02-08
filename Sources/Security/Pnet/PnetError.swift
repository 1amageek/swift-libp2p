/// PnetError - Error definitions for Private Network (pnet) protocol
import Foundation

/// Errors that can occur during pnet operations.
public enum PnetError: Error, Sendable {
    /// The PSK has an invalid length.
    case invalidKeyLength(expected: Int, got: Int)

    /// The PSK file format is invalid.
    case invalidFileFormat(String)

    /// The nonce has an invalid length.
    case invalidNonceLength(expected: Int, got: Int)

    /// The PSK fingerprints do not match (different private networks).
    case fingerprintMismatch(local: PnetFingerprint, remote: PnetFingerprint)

    /// A connection-level error occurred.
    case connectionFailed(String)

    /// Concurrent access to a non-reentrant operation was detected.
    /// Stream ciphers require strict byte ordering; concurrent reads or
    /// concurrent writes would silently corrupt data.
    case concurrentAccess(String)
}
