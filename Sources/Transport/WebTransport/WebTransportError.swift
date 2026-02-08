/// Errors specific to WebTransport operations.
public enum WebTransportError: Error, Sendable {

    /// HTTP/3 support is not yet available in the underlying QUIC implementation.
    ///
    /// WebTransport requires HTTP/3, which depends on the HTTP layer
    /// being implemented on top of QUIC. This error is returned when
    /// attempting to dial or listen before HTTP/3 support is available.
    case http3NotAvailable

    /// The certificate hash in the multiaddr is invalid or malformed.
    case invalidCertificateHash

    /// The connection to the remote peer failed.
    ///
    /// - Parameter message: A description of what went wrong.
    case connectionFailed(String)

    /// Failed to create a new stream on the connection.
    case streamCreationFailed

    /// The operation requires an active connection, but none exists.
    case notConnected

    /// The operation timed out before completing.
    case timeout

    /// Certificate verification failed during the handshake.
    ///
    /// WebTransport uses certificate hashes for verification instead of
    /// the standard CA-based PKI. This error indicates the remote peer's
    /// certificate hash does not match the expected hash from the multiaddr.
    case certificateVerificationFailed
}
