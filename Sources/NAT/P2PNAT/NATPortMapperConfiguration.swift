/// NATPortMapperConfiguration - Configuration for NATPortMapper
import Foundation

/// Configuration for NATPortMapper.
public struct NATPortMapperConfiguration: Sendable {
    /// Timeout for gateway discovery.
    public var discoveryTimeout: Duration

    /// Default mapping duration.
    public var defaultLeaseDuration: Duration

    /// Buffer before expiration to renew.
    public var renewalBuffer: Duration

    /// Whether to automatically renew mappings.
    public var autoRenew: Bool

    /// Whether to try UPnP.
    public var tryUPnP: Bool

    /// Whether to try NAT-PMP.
    public var tryNATPMP: Bool

    /// NAT-PMP port (default: 5351).
    public var natpmpPort: UInt16

    /// Label for port mappings registered on the gateway.
    public var mappingDescription: String

    public init(
        discoveryTimeout: Duration = .seconds(5),
        defaultLeaseDuration: Duration = .seconds(3600),
        renewalBuffer: Duration = .seconds(300),
        autoRenew: Bool = true,
        tryUPnP: Bool = true,
        tryNATPMP: Bool = true,
        natpmpPort: UInt16 = 5351,
        mappingDescription: String = "libp2p"
    ) {
        self.discoveryTimeout = discoveryTimeout
        self.defaultLeaseDuration = defaultLeaseDuration
        self.renewalBuffer = renewalBuffer
        self.autoRenew = autoRenew
        self.tryUPnP = tryUPnP
        self.tryNATPMP = tryNATPMP
        self.natpmpPort = natpmpPort
        self.mappingDescription = mappingDescription
    }

    public static let `default` = NATPortMapperConfiguration()
}
