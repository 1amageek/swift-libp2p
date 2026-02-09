import Foundation

/// Configuration for the WiFi beacon transport adapter.
public struct WiFiBeaconConfiguration: Sendable {
    /// IPv4 multicast group address (RFC 2365 Organization-Local Scope).
    public var multicastGroup: String

    /// UDP port for beacon traffic.
    public var port: Int

    /// Network interface to bind (nil = all interfaces).
    public var networkInterface: String?

    /// Interval between beacon transmissions.
    public var transmitInterval: Duration

    /// Whether to receive own beacons via multicast loopback.
    /// Useful for testing; should be false in production.
    public var loopback: Bool

    public init(
        multicastGroup: String = "239.2.0.1",
        port: Int = 9876,
        networkInterface: String? = nil,
        transmitInterval: Duration = .seconds(5),
        loopback: Bool = false
    ) {
        self.multicastGroup = multicastGroup
        self.port = port
        self.networkInterface = networkInterface
        self.transmitInterval = transmitInterval
        self.loopback = loopback
    }
}
