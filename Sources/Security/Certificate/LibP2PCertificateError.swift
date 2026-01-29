/// LibP2PCertificateError - Errors for libp2p certificate operations
///
/// These errors are transport-agnostic and used by both TLS and WebRTC.

import P2PCore

/// Errors that can occur during libp2p certificate generation or validation.
public enum LibP2PCertificateError: Error, Sendable {
    /// The certificate does not contain the libp2p extension (OID 1.3.6.1.4.1.53594.1.1).
    case missingExtension

    /// The signature in the libp2p extension is invalid.
    case invalidSignature

    /// The PeerID extracted from the certificate does not match the expected PeerID.
    case peerIDMismatch(expected: PeerID, actual: PeerID)
}
