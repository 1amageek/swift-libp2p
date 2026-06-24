/// TLSError - TLS security errors for libp2p
import Foundation

/// Errors that can occur during libp2p TLS operations.
///
/// Crypto-level errors (encryption, decryption, framing) are handled
/// internally by swift-tls. These errors cover libp2p-specific concerns.
public enum TLSError: Error, Sendable {
    /// TLS handshake failed.
    case handshakeFailed(reason: String)

    /// Invalid certificate signature (libp2p extension verification failed).
    case invalidCertificateSignature

    /// Missing libp2p extension in certificate.
    case missingLibP2PExtension

    /// Peer ID mismatch.
    case peerIDMismatch(expected: String, actual: String)

    /// Connection was closed.
    case connectionClosed

    /// TLS handshake timeout.
    case timeout

    /// ALPN protocol mismatch (expected "libp2p").
    case alpnMismatch

    /// The verified remote PeerID could not be obtained from the completed TLS
    /// handshake. This is the fail-closed gate for the deferred swift-tls
    /// peer-identity surfacing gap: the Tier-1 `TLS` facade currently discards
    /// the `PeerIdentity` produced by the certificate validator
    /// (`peerIdentity` returns nil), so the libp2p-TLS upgrader cannot read the
    /// peer's RPK PeerID back out of the handshake. Until the facade surfaces
    /// `peerIdentity`, the upgrader rejects rather than admit an
    /// unauthenticated/unidentified peer. See CONTEXT.md "Deferred".
    case peerIdentityUnavailable

    /// An underlying `TLS` facade error occurred during the handshake or
    /// record-layer processing. `reason` carries the facade error description.
    case facade(reason: String)
}
