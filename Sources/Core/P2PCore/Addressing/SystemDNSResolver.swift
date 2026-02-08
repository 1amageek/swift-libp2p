/// SystemDNSResolver - DNS resolution using system resolver (getaddrinfo).
///
/// Resolves /dns4, /dns6, /dns, and /dnsaddr multiaddr components
/// into their IP-based equivalents using the operating system's DNS resolver.

import Foundation

public final class SystemDNSResolver: DNSResolver, Sendable {

    /// Maximum number of resolved addresses to return per DNS component.
    public let maxResults: Int

    public init(maxResults: Int = 10) {
        self.maxResults = maxResults
    }

    public func resolve(_ address: Multiaddr) async throws -> [Multiaddr] {
        // Non-DNS addresses pass through unchanged
        guard address.hasDNSComponent else {
            return [address]
        }

        // Find the first DNS component and resolve it
        for (index, proto) in address.protocols.enumerated() {
            switch proto {
            case .dns4(let hostname):
                let ips = try await resolveHostname(hostname, family: .ipv4)
                var resolvedAddresses: [Multiaddr] = []
                for ip in ips.prefix(maxResults) {
                    var newProtos = address.protocols
                    newProtos[index] = .ip4(ip)
                    resolvedAddresses.append(Multiaddr(uncheckedProtocols: newProtos))
                }
                return resolvedAddresses

            case .dns6(let hostname):
                let ips = try await resolveHostname(hostname, family: .ipv6)
                var resolvedAddresses: [Multiaddr] = []
                for ip in ips.prefix(maxResults) {
                    var newProtos = address.protocols
                    newProtos[index] = .ip6(ip)
                    resolvedAddresses.append(Multiaddr(uncheckedProtocols: newProtos))
                }
                return resolvedAddresses

            case .dns(let hostname):
                // Resolve both IPv4 and IPv6, collecting all results
                var allIPs: [(ip: String, isIPv6: Bool)] = []

                do {
                    let v4 = try await resolveHostname(hostname, family: .ipv4)
                    allIPs.append(contentsOf: v4.map { (ip: $0, isIPv6: false) })
                } catch {
                    // IPv4 resolution failed; continue to try IPv6
                }

                do {
                    let v6 = try await resolveHostname(hostname, family: .ipv6)
                    allIPs.append(contentsOf: v6.map { (ip: $0, isIPv6: true) })
                } catch {
                    // IPv6 resolution failed; check if we have any results
                }

                guard !allIPs.isEmpty else {
                    throw DNSResolverError.resolutionFailed(hostname: hostname)
                }

                var resolvedAddresses: [Multiaddr] = []
                for (ip, isV6) in allIPs.prefix(maxResults) {
                    var newProtos = address.protocols
                    newProtos[index] = isV6 ? .ip6(ip) : .ip4(ip)
                    resolvedAddresses.append(Multiaddr(uncheckedProtocols: newProtos))
                }
                return resolvedAddresses

            case .dnsaddr(let domain):
                // dnsaddr requires TXT record lookup for _dnsaddr.<domain>
                let resolved = try await resolveDNSAddr(domain)
                return resolved

            default:
                continue
            }
        }

        // No DNS components found (should not reach here if hasDNSComponent is correct)
        return [address]
    }

    // MARK: - Private

    private enum AddressFamily: Sendable {
        case ipv4
        case ipv6
    }

    private func resolveHostname(_ hostname: String, family: AddressFamily) async throws -> [String] {
        // Use getaddrinfo via Foundation.
        // DispatchQueue usage is acceptable here as it wraps a blocking C system call.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_family = family == .ipv4 ? AF_INET : AF_INET6
                hints.ai_socktype = SOCK_STREAM

                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(hostname, nil, &hints, &result)

                guard status == 0, let addrList = result else {
                    if let result { freeaddrinfo(result) }
                    let familyName = family == .ipv4 ? "IPv4" : "IPv6"
                    continuation.resume(throwing: DNSResolverError.noAddressesFound(
                        hostname: hostname,
                        family: familyName
                    ))
                    return
                }

                defer { freeaddrinfo(addrList) }

                var addresses: [String] = []
                var current: UnsafeMutablePointer<addrinfo>? = addrList

                while let info = current {
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))

                    if family == .ipv4, let sockaddr = info.pointee.ai_addr {
                        sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { addr in
                            var sinAddr = addr.pointee.sin_addr
                            inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
                        }
                    } else if family == .ipv6, let sockaddr = info.pointee.ai_addr {
                        sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { addr in
                            var sin6Addr = addr.pointee.sin6_addr
                            inet_ntop(AF_INET6, &sin6Addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                        }
                    }

                    let ip = String(cString: buffer)
                    if !ip.isEmpty && !addresses.contains(ip) {
                        addresses.append(ip)
                    }

                    current = info.pointee.ai_next
                }

                if addresses.isEmpty {
                    let familyName = family == .ipv4 ? "IPv4" : "IPv6"
                    continuation.resume(throwing: DNSResolverError.noAddressesFound(
                        hostname: hostname,
                        family: familyName
                    ))
                } else {
                    continuation.resume(returning: addresses)
                }
            }
        }
    }

    private func resolveDNSAddr(_ domain: String) async throws -> [Multiaddr] {
        // dnsaddr TXT record: _dnsaddr.<domain> contains dnsaddr=<multiaddr>
        // Full dnsaddr support requires DNS TXT record lookup which is not
        // available through getaddrinfo. A future implementation could use
        // dns_sd or a DNS library.
        throw DNSResolverError.dnsaddrLookupFailed(domain: domain)
    }
}
