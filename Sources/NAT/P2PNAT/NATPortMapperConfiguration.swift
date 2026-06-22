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

    /// Whether to try PCP (Port Control Protocol).
    public var tryPCP: Bool

    /// NAT-PMP / PCP port (default: 5351).
    public var natpmpPort: UInt16

    /// Label for port mappings registered on the gateway.
    public var mappingDescription: String

    /// Minimum lease lifetime accepted from a gateway. A gateway can return an
    /// `assignedLifetime` of 0 (or a tiny value), which would otherwise schedule
    /// an immediate renewal and spin a hot-loop. Lifetimes are clamped up to
    /// this floor. Default is 60 seconds.
    public var minLeaseLifetime: Duration

    /// Maximum lease lifetime accepted from a gateway. Lifetimes are clamped
    /// down to this ceiling. Default is 24 hours.
    public var maxLeaseLifetime: Duration

    /// Minimum delay before a renewal attempt, regardless of the computed
    /// renewal time. Prevents a renewal hot-loop when the lease is shorter than
    /// the renewal buffer. Default is 5 seconds.
    public var minRenewalDelay: Duration

    /// Number of renewal retries (with backoff) before a mapping is declared
    /// expired. A single transient failure must not silently abandon the
    /// mapping. Default is 3.
    public var renewalMaxRetries: Int

    /// Base delay for renewal retry backoff. Default is 2 seconds.
    public var renewalRetryBackoff: Duration

    public init(
        discoveryTimeout: Duration = .seconds(5),
        defaultLeaseDuration: Duration = .seconds(3600),
        renewalBuffer: Duration = .seconds(300),
        autoRenew: Bool = true,
        tryUPnP: Bool = true,
        tryNATPMP: Bool = true,
        tryPCP: Bool = true,
        natpmpPort: UInt16 = 5351,
        mappingDescription: String = "libp2p",
        minLeaseLifetime: Duration = .seconds(60),
        maxLeaseLifetime: Duration = .seconds(86400),
        minRenewalDelay: Duration = .seconds(5),
        renewalMaxRetries: Int = 3,
        renewalRetryBackoff: Duration = .seconds(2)
    ) {
        self.discoveryTimeout = discoveryTimeout
        self.defaultLeaseDuration = defaultLeaseDuration
        self.renewalBuffer = renewalBuffer
        self.autoRenew = autoRenew
        self.tryUPnP = tryUPnP
        self.tryNATPMP = tryNATPMP
        self.tryPCP = tryPCP
        self.natpmpPort = natpmpPort
        self.mappingDescription = mappingDescription
        self.minLeaseLifetime = minLeaseLifetime
        self.maxLeaseLifetime = maxLeaseLifetime
        self.minRenewalDelay = minRenewalDelay
        self.renewalMaxRetries = renewalMaxRetries
        self.renewalRetryBackoff = renewalRetryBackoff
    }

    public static let `default` = NATPortMapperConfiguration()

    /// Clamps a gateway-assigned lifetime (in seconds) to `[minLeaseLifetime,
    /// maxLeaseLifetime]`. Used to neutralize a malicious or buggy gateway that
    /// returns a 0 (or excessive) lifetime.
    public func clampedLifetime(seconds: UInt32) -> Duration {
        let minSeconds = max(0, minLeaseLifetime.components.seconds)
        let maxSeconds = max(minSeconds, maxLeaseLifetime.components.seconds)
        let clamped = min(max(Int64(seconds), minSeconds), maxSeconds)
        return .seconds(clamped)
    }
}
