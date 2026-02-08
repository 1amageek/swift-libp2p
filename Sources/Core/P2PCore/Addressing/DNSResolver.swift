/// DNSResolver - Resolves DNS components in multiaddrs.
///
/// Converts addresses like /dns4/example.com/tcp/4001
/// to /ip4/93.184.216.34/tcp/4001.

import Foundation

/// Protocol for DNS resolution of multiaddrs.
public protocol DNSResolver: Sendable {
    /// Resolves any DNS components in the given multiaddr.
    /// Returns one or more resolved addresses.
    /// Non-DNS addresses are returned as-is.
    func resolve(_ address: Multiaddr) async throws -> [Multiaddr]
}

/// Errors from DNS resolution.
public enum DNSResolverError: Error, Sendable {
    /// The hostname could not be resolved.
    case resolutionFailed(hostname: String)
    /// No addresses of the requested family were found.
    case noAddressesFound(hostname: String, family: String)
    /// The dnsaddr TXT record lookup failed.
    case dnsaddrLookupFailed(domain: String)
}
