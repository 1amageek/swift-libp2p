/// HTTPProtocol - Protocol constants and defaults for HTTP over libp2p.

/// Constants and defaults for the HTTP protocol over libp2p streams.
public enum HTTPProtocol {
    /// Protocol ID for HTTP/1.1 over libp2p.
    public static let protocolID = "/http/1.1"

    /// Maximum header size in bytes (8KB).
    public static let maxHeaderSize = 8192

    /// Maximum body size in bytes (10MB).
    public static let maxBodySize = 10 * 1024 * 1024
}
