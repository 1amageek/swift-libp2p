/// WebTransport protocol constants.
///
/// WebTransport is a web API that uses HTTP/3 as a bidirectional transport.
/// It enables browsers to connect to libp2p nodes using QUIC streams
/// over an HTTP/3 connection.
///
/// ## Multiaddr Format
///
/// WebTransport addresses include certificate hashes for browser verification:
/// `/ip4/<ip>/udp/<port>/quic-v1/webtransport/certhash/<hash>`
///
/// ## References
///
/// - [WebTransport Specification](https://www.w3.org/TR/webtransport/)
/// - [libp2p WebTransport](https://github.com/libp2p/specs/tree/master/webtransport)

/// Protocol constants for WebTransport.
public enum WebTransportProtocol {

    /// The libp2p protocol identifier for WebTransport.
    public static let protocolID = "/webtransport"

    /// The ALPN token used during the TLS handshake.
    public static let alpn = "h3"

    /// The prefix used for certificate hash components in multiaddrs.
    public static let certHashPrefix = "/certhash/"

    /// The maximum certificate validity period for browser-compatible certificates.
    ///
    /// Browsers require self-signed certificates used with WebTransport to have
    /// a validity period of at most 14 days.
    public static let maxCertificateValidityDays = 14
}
