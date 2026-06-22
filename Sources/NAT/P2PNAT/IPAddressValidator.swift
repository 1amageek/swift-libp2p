/// IPAddressValidator - Parses and validates IP addresses for NAT operations.
///
/// Gateways and peers are untrusted: SSDP is unauthenticated UDP multicast,
/// and NAT-PMP/PCP responses can be spoofed. This validator parses network
/// input to numeric form and rejects bogon / unroutable ranges so that
/// gateway-supplied addresses are never blindly trusted (SSRF / spoofing).
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Classification of a parsed IP address.
enum IPAddressClass: Sendable, Equatable {
    /// RFC1918 private IPv4 (10/8, 172.16/12, 192.168/16) or IPv6 ULA (fc00::/7).
    case privateRange
    /// Link-local (169.254/16, fe80::/10).
    case linkLocal
    /// Loopback (127/8, ::1).
    case loopback
    /// Unspecified (0.0.0.0, ::).
    case unspecified
    /// Multicast (224/4, ff00::/8).
    case multicast
    /// Carrier-grade NAT shared address space (100.64/10).
    case cgnat
    /// Globally routable / public address.
    case global
}

/// Validates IP addresses parsed from untrusted network input.
enum IPAddressValidator {

    /// Parses an IPv4 or IPv6 string into 4-byte / 16-byte numeric form.
    ///
    /// - Returns: The parsed bytes (4 for IPv4, 16 for IPv6), or `nil` if the
    ///   string is not a valid numeric IP. Hostnames are rejected (we never
    ///   resolve attacker-supplied DNS names for control traffic).
    static func parse(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4.s_addr) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }

    /// Classifies a numeric IP address (4 or 16 bytes).
    static func classify(_ bytes: [UInt8]) -> IPAddressClass? {
        switch bytes.count {
        case 4:
            return classifyIPv4(bytes)
        case 16:
            return classifyIPv6(bytes)
        default:
            return nil
        }
    }

    /// Classifies an IP address string.
    static func classify(_ address: String) -> IPAddressClass? {
        guard let bytes = parse(address) else { return nil }
        return classify(bytes)
    }

    /// Whether the address is a private / link-local address that is acceptable
    /// as a NAT gateway or local client on the LAN.
    ///
    /// Accepts RFC1918 private and link-local ranges. Rejects loopback,
    /// unspecified, multicast, CGNAT and global addresses for control endpoints.
    static func isLANAddress(_ address: String) -> Bool {
        switch classify(address) {
        case .privateRange, .linkLocal:
            return true
        default:
            return false
        }
    }

    /// Whether the address is a valid, routable external (public) IP that a
    /// gateway may legitimately report as our external address.
    ///
    /// Rejects unspecified (0.0.0.0), loopback, private, link-local, multicast,
    /// and CGNAT bogon ranges.
    static func isRoutableExternalAddress(_ address: String) -> Bool {
        classify(address) == .global
    }

    // MARK: - IPv4

    private static func classifyIPv4(_ b: [UInt8]) -> IPAddressClass {
        // 0.0.0.0/8 — unspecified / "this network"
        if b[0] == 0 {
            return .unspecified
        }
        // 127.0.0.0/8 — loopback
        if b[0] == 127 {
            return .loopback
        }
        // 10.0.0.0/8
        if b[0] == 10 {
            return .privateRange
        }
        // 172.16.0.0/12
        if b[0] == 172, (16...31).contains(b[1]) {
            return .privateRange
        }
        // 192.168.0.0/16
        if b[0] == 192, b[1] == 168 {
            return .privateRange
        }
        // 169.254.0.0/16 — link-local (includes 169.254.169.254 metadata endpoint)
        if b[0] == 169, b[1] == 254 {
            return .linkLocal
        }
        // 100.64.0.0/10 — carrier-grade NAT
        if b[0] == 100, (64...127).contains(b[1]) {
            return .cgnat
        }
        // 224.0.0.0/4 — multicast
        if (224...239).contains(b[0]) {
            return .multicast
        }
        // 240.0.0.0/4 — reserved (treat as non-routable / unspecified)
        if b[0] >= 240 {
            return .unspecified
        }
        return .global
    }

    // MARK: - IPv6

    private static func classifyIPv6(_ b: [UInt8]) -> IPAddressClass {
        // :: — unspecified
        if b.allSatisfy({ $0 == 0 }) {
            return .unspecified
        }
        // ::1 — loopback
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 {
            return .loopback
        }
        // ::ffff:0:0/96 — IPv4-mapped; classify the embedded IPv4
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
            return classifyIPv4(Array(b[12..<16]))
        }
        // ff00::/8 — multicast
        if b[0] == 0xFF {
            return .multicast
        }
        // fe80::/10 — link-local
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 {
            return .linkLocal
        }
        // fc00::/7 — unique local address (private)
        if (b[0] & 0xFE) == 0xFC {
            return .privateRange
        }
        return .global
    }
}
