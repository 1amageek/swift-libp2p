/// Configuration for WebTransport connections.
///
/// WebTransport uses HTTP/3 over QUIC with short-lived self-signed certificates.
/// This configuration controls certificate rotation, stream limits, and timeouts.

/// Configuration for WebTransport transport.
public struct WebTransportConfiguration: Sendable {

    /// The interval between certificate rotations.
    ///
    /// Browsers require certificates to be valid for at most 14 days.
    /// The default of 12 days provides a 2-day buffer for clock skew.
    public var certRotationInterval: Duration

    /// The maximum number of concurrent streams per connection.
    ///
    /// This limits the number of simultaneously open bidirectional streams
    /// on a single WebTransport session.
    public var maxConcurrentStreams: Int

    /// The interval between keep-alive pings.
    ///
    /// Keep-alive pings prevent the connection from being closed by
    /// intermediate NATs or firewalls due to inactivity.
    public var keepAliveInterval: Duration

    /// The timeout for establishing a connection.
    ///
    /// This covers the entire connection setup including QUIC handshake,
    /// HTTP/3 session establishment, and WebTransport session negotiation.
    public var connectionTimeout: Duration

    /// Creates a new WebTransport configuration.
    ///
    /// - Parameters:
    ///   - certRotationInterval: Certificate rotation interval. Default: 12 days.
    ///   - maxConcurrentStreams: Maximum concurrent streams. Default: 100.
    ///   - keepAliveInterval: Keep-alive ping interval. Default: 30 seconds.
    ///   - connectionTimeout: Connection establishment timeout. Default: 30 seconds.
    public init(
        certRotationInterval: Duration = .seconds(12 * 24 * 60 * 60),
        maxConcurrentStreams: Int = 100,
        keepAliveInterval: Duration = .seconds(30),
        connectionTimeout: Duration = .seconds(30)
    ) {
        self.certRotationInterval = certRotationInterval
        self.maxConcurrentStreams = maxConcurrentStreams
        self.keepAliveInterval = keepAliveInterval
        self.connectionTimeout = connectionTimeout
    }
}
