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
}
