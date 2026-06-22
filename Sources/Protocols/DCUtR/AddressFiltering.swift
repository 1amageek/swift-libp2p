/// AddressFiltering - Shared address filtering utilities for DCUtR module.
///
/// Provides private/unroutable address detection used by both DCUtRService
/// and HolePunchService.
///
/// Hole punching dials peer-supplied addresses. A naive string-prefix filter is
/// trivially bypassable (IPv4-mapped IPv6, NAT64, alternate textual forms) and
/// can be turned into an SSRF primitive against internal infrastructure. This
/// classifier parses addresses to numeric form and classifies on integer ranges.
/// It is fail-closed: any address that cannot be parsed is treated as private
/// (i.e. not dialable).

import Foundation

/// Checks if an IP address string is private/unroutable (and thus unsafe to dial
/// for hole punching).
///
/// Returns `true` for loopback, unspecified, RFC1918 private, CGNAT, link-local,
/// ULA, multicast, reserved, NAT64, IPv4-mapped/compatible-to-private, and any
/// address that cannot be parsed (fail-closed).
///
/// - Parameter ip: The IP address string to check.
/// - Returns: `true` if the address is private/unroutable or unparseable.
func isPrivateAddress(_ ip: String) -> Bool {
    if let v4 = parseIPv4(ip) {
        return isPrivateIPv4(v4)
    }
    if let v6 = parseIPv6(ip) {
        // IPv4-mapped (::ffff:a.b.c.d) / IPv4-compatible (::a.b.c.d) classify by
        // their embedded IPv4 address.
        if let embedded = embeddedIPv4(v6) {
            return isPrivateIPv4(embedded)
        }
        return isPrivateIPv6(v6)
    }
    // Unparseable -> fail closed (treat as private / not dialable).
    return true
}

// MARK: - IPv4

func parseIPv4(_ ip: String) -> [UInt8]? {
    guard ip.contains("."), !ip.contains(":") else { return nil }
    let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    var octets = [UInt8]()
    octets.reserveCapacity(4)
    for part in parts {
        guard !part.isEmpty, part.allSatisfy({ $0.isNumber }) else { return nil }
        guard let value = UInt16(part), value <= 255 else { return nil }
        octets.append(UInt8(value))
    }
    return octets
}

func isPrivateIPv4(_ o: [UInt8]) -> Bool {
    guard o.count == 4 else { return true }

    // 0.0.0.0/8 — unspecified / "this host".
    if o[0] == 0 { return true }
    // 10.0.0.0/8 — RFC1918.
    if o[0] == 10 { return true }
    // 127.0.0.0/8 — loopback.
    if o[0] == 127 { return true }
    // 100.64.0.0/10 — CGNAT (RFC6598).
    if o[0] == 100 && (o[1] & 0xC0) == 0x40 { return true }
    // 169.254.0.0/16 — link-local (incl. 169.254.169.254 metadata).
    if o[0] == 169 && o[1] == 254 { return true }
    // 172.16.0.0/12 — RFC1918.
    if o[0] == 172 && (o[1] >= 16 && o[1] <= 31) { return true }
    // 192.0.0.0/24 — IETF protocol assignments.
    if o[0] == 192 && o[1] == 0 && o[2] == 0 { return true }
    // 192.0.2.0/24 — TEST-NET-1.
    if o[0] == 192 && o[1] == 0 && o[2] == 2 { return true }
    // 192.88.99.0/24 — 6to4 relay anycast.
    if o[0] == 192 && o[1] == 88 && o[2] == 99 { return true }
    // 192.168.0.0/16 — RFC1918.
    if o[0] == 192 && o[1] == 168 { return true }
    // 198.18.0.0/15 — benchmarking.
    if o[0] == 198 && (o[1] == 18 || o[1] == 19) { return true }
    // 224.0.0.0/4 — multicast.
    if o[0] >= 224 && o[0] <= 239 { return true }
    // 240.0.0.0/4 — reserved (incl. 255.255.255.255 broadcast).
    if o[0] >= 240 { return true }

    return false
}

// MARK: - IPv6

func parseIPv6(_ ip: String) -> [UInt16]? {
    guard !ip.isEmpty else { return nil }

    let withoutZone: Substring
    if let percent = ip.firstIndex(of: "%") {
        withoutZone = ip[..<percent]
    } else {
        withoutZone = ip[...]
    }
    guard withoutZone.contains(":") else { return nil }

    var text = String(withoutZone)

    // Embedded IPv4 dotted-quad in the last group (e.g. ::ffff:1.2.3.4).
    var trailingGroups: [UInt16] = []
    if text.contains(".") {
        guard let lastColon = text.lastIndex(of: ":") else { return nil }
        let tail = String(text[text.index(after: lastColon)...])
        guard let v4 = parseIPv4(tail) else { return nil }
        trailingGroups = [
            (UInt16(v4[0]) << 8) | UInt16(v4[1]),
            (UInt16(v4[2]) << 8) | UInt16(v4[3]),
        ]
        text = String(text[...lastColon])
    }

    let doubleColonCount = text.components(separatedBy: "::").count - 1
    guard doubleColonCount <= 1 else { return nil }

    let groups: [UInt16]
    if text.contains("::") {
        let halves = text.components(separatedBy: "::")
        guard halves.count == 2 else { return nil }
        let left = halves[0].split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let right = halves[1].split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard let leftGroups = hexGroups(left), let rightGroups = hexGroups(right) else { return nil }
        let known = leftGroups.count + rightGroups.count + trailingGroups.count
        guard known <= 8 else { return nil }
        let zeros = Array(repeating: UInt16(0), count: 8 - known)
        groups = leftGroups + zeros + rightGroups + trailingGroups
    } else {
        let parts = text.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        guard let parsed = hexGroups(parts) else { return nil }
        groups = parsed + trailingGroups
    }

    guard groups.count == 8 else { return nil }
    return groups
}

private func hexGroups(_ parts: [String]) -> [UInt16]? {
    var result = [UInt16]()
    result.reserveCapacity(parts.count)
    for part in parts {
        guard !part.isEmpty, part.count <= 4,
              part.allSatisfy({ $0.isHexDigit }),
              let value = UInt16(part, radix: 16) else { return nil }
        result.append(value)
    }
    return result
}

func embeddedIPv4(_ g: [UInt16]) -> [UInt8]? {
    guard g.count == 8 else { return nil }
    guard g[0] == 0, g[1] == 0, g[2] == 0, g[3] == 0, g[4] == 0 else { return nil }
    guard g[5] == 0xffff || g[5] == 0 else { return nil }
    // :: and ::1 are not embedded IPv4.
    if g[5] == 0 && (g[6] == 0 && (g[7] == 0 || g[7] == 1)) { return nil }
    return [
        UInt8(g[6] >> 8), UInt8(g[6] & 0xff),
        UInt8(g[7] >> 8), UInt8(g[7] & 0xff),
    ]
}

func isPrivateIPv6(_ g: [UInt16]) -> Bool {
    guard g.count == 8 else { return true }

    // Unspecified ::
    if g.allSatisfy({ $0 == 0 }) { return true }
    // Loopback ::1
    if g[0] == 0, g[1] == 0, g[2] == 0, g[3] == 0, g[4] == 0, g[5] == 0, g[6] == 0, g[7] == 1 {
        return true
    }
    // Multicast ff00::/8
    if (g[0] & 0xff00) == 0xff00 { return true }
    // Link-local fe80::/10
    if (g[0] & 0xffc0) == 0xfe80 { return true }
    // Unique local fc00::/7
    if (g[0] & 0xfe00) == 0xfc00 { return true }
    // NAT64 well-known prefix 64:ff9b::/96
    if g[0] == 0x0064, g[1] == 0xff9b, g[2] == 0, g[3] == 0, g[4] == 0, g[5] == 0 {
        return true
    }
    // Documentation 2001:db8::/32
    if g[0] == 0x2001, g[1] == 0x0db8 { return true }
    // Discard-only 100::/64 (RFC6666)
    if g[0] == 0x0100, g[1] == 0, g[2] == 0, g[3] == 0 { return true }

    return false
}
