/// TLSError - TLS security errors
import Foundation

/// Errors that can occur during TLS operations.
public enum TLSError: Error, Sendable {
    /// TLS handshake failed.
    case handshakeFailed(reason: String)

    /// Invalid certificate signature.
    case invalidCertificateSignature

    /// Missing libp2p extension in certificate.
    case missingLibP2PExtension

    /// Peer ID mismatch.
    case peerIDMismatch(expected: String, actual: String)

    /// Connection was closed.
    case connectionClosed

    /// Decryption failed.
    case decryptionFailed

    /// Encryption failed.
    case encryptionFailed

    /// TLS handshake timeout.
    case timeout

    /// Invalid TLS message format.
    case invalidMessage

    /// Certificate generation failed.
    case certificateGenerationFailed(reason: String)

    /// Key generation failed.
    case keyGenerationFailed

    /// Unsupported TLS version.
    case unsupportedVersion
}
