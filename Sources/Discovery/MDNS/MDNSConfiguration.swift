/// P2PDiscoveryMDNS - mDNS-based peer discovery configuration
import Foundation

/// Configuration for mDNS-based peer discovery.
public struct MDNSConfiguration: Sendable {

    /// The service type to use for discovery.
    /// Default: "_p2p._udp"
    public var serviceType: String

    /// The domain to use for discovery.
    /// Default: "local"
    public var domain: String

    /// How often to refresh queries.
    public var queryInterval: Duration

    /// Whether to use IPv4.
    public var useIPv4: Bool

    /// Whether to use IPv6.
    public var useIPv6: Bool

    /// Network interface to bind to (nil for all interfaces).
    public var networkInterface: String?

    /// TTL for advertised records.
    public var ttl: UInt32

    /// Agent version string to advertise.
    public var agentVersion: String

    public init(
        serviceType: String = "_p2p._udp",
        domain: String = "local",
        queryInterval: Duration = .seconds(120),
        useIPv4: Bool = true,
        useIPv6: Bool = true,
        networkInterface: String? = nil,
        ttl: UInt32 = 120,
        agentVersion: String = "swift-libp2p/1.0"
    ) {
        self.serviceType = serviceType
        self.domain = domain
        self.queryInterval = queryInterval
        self.useIPv4 = useIPv4
        self.useIPv6 = useIPv6
        self.networkInterface = networkInterface
        self.ttl = ttl
        self.agentVersion = agentVersion
    }

    /// Default configuration.
    public static let `default` = MDNSConfiguration()

    /// Full service type string including domain.
    public var fullServiceType: String {
        "\(serviceType).\(domain)."
    }
}
