/// AddressFiltering - Shared address filtering utilities for DCUtR module.
///
/// Provides private/unroutable address detection used by both DCUtRService
/// and HolePunchService.

/// Checks if an IP address string is private/unroutable.
///
/// Returns `true` for loopback, unspecified, private, and link-local addresses
/// in both IPv4 and IPv6.
///
/// - Parameter ip: The IP address string to check.
/// - Returns: `true` if the address is private/unroutable.
func isPrivateAddress(_ ip: String) -> Bool {
    // IPv4
    if ip.contains(".") {
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return true }

        // Loopback: 127.0.0.0/8
        if octets[0] == 127 { return true }
        // Unspecified: 0.0.0.0
        if octets.allSatisfy({ $0 == 0 }) { return true }
        // Private: 10.0.0.0/8
        if octets[0] == 10 { return true }
        // Private: 172.16.0.0/12
        if octets[0] == 172 && (octets[1] >= 16 && octets[1] <= 31) { return true }
        // Private: 192.168.0.0/16
        if octets[0] == 192 && octets[1] == 168 { return true }
        // Link-local: 169.254.0.0/16
        if octets[0] == 169 && octets[1] == 254 { return true }

        return false
    }

    // IPv6
    let normalized = ip.lowercased()
    // Loopback: ::1
    if normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" { return true }
    // Unspecified: ::
    if normalized == "::" || normalized == "0:0:0:0:0:0:0:0" { return true }
    // Link-local: fe80::/10
    if normalized.hasPrefix("fe8") || normalized.hasPrefix("fe9") ||
       normalized.hasPrefix("fea") || normalized.hasPrefix("feb") { return true }
    // Unique local: fc00::/7
    if normalized.hasPrefix("fc") || normalized.hasPrefix("fd") { return true }

    return false
}
