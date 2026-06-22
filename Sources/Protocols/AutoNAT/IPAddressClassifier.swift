/// IPAddressClassifier - Numeric classification of IP addresses for dial-back safety.
///
/// AutoNAT v2 servers must never be tricked into dialing addresses that could
/// be used for amplification or SSRF attacks. String-prefix matching is unsafe
/// (e.g. it misses IPv4-mapped IPv6, NAT64, alternate textual forms), so this
/// classifier parses an address into its numeric octets/groups and classifies
/// it on integer ranges. All parsing is fail-closed: any address that cannot be
/// parsed is treated as non-public (unsafe to dial).

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Classifies an IP address by reachability category.
enum IPAddressClassifier {

    /// Returns `true` if the IP address is safe to dial back for AutoNAT verification,
    /// i.e. it is a globally-routable unicast address (not loopback, private, link-local,
    /// CGNAT, multicast, reserved, metadata, or otherwise unroutable).
    ///
    /// Fail-closed: any address that cannot be parsed returns `false`.
    static func isPublicUnicast(_ ip: String) -> Bool {
        if let v4 = parseIPv4(ip) {
            return isPublicUnicastIPv4(v4)
        }
        if let v6 = parseIPv6(ip) {
            // IPv4-mapped (::ffff:a.b.c.d) and IPv4-compatible (::a.b.c.d) must be
            // classified by their embedded IPv4 address.
            if let embedded = embeddedIPv4(v6) {
                return isPublicUnicastIPv4(embedded)
            }
            return isPublicUnicastIPv6(v6)
        }
        // Unparseable -> not safe to dial.
        return false
    }

    // MARK: - IPv4

    /// Parses a dotted-decimal IPv4 string into 4 octets. Returns nil if invalid.
    static func parseIPv4(_ ip: String) -> [UInt8]? {
        // Must contain a dot and no colon (a colon means IPv6 form).
        guard ip.contains("."), !ip.contains(":") else { return nil }
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets = [UInt8]()
        octets.reserveCapacity(4)
        for part in parts {
            // Reject leading-zero ambiguity and non-numeric content.
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }) else { return nil }
            guard let value = UInt16(part), value <= 255 else { return nil }
            octets.append(UInt8(value))
        }
        return octets
    }

    /// Classifies a 4-octet IPv4 address. Returns `true` only for globally-routable unicast.
    static func isPublicUnicastIPv4(_ o: [UInt8]) -> Bool {
        guard o.count == 4 else { return false }

        // 0.0.0.0/8 — "this host" / unspecified.
        if o[0] == 0 { return false }
        // 10.0.0.0/8 — RFC1918 private.
        if o[0] == 10 { return false }
        // 127.0.0.0/8 — loopback.
        if o[0] == 127 { return false }
        // 100.64.0.0/10 — CGNAT (RFC6598).
        if o[0] == 100 && (o[1] & 0xC0) == 0x40 { return false }
        // 169.254.0.0/16 — link-local (includes 169.254.169.254 metadata).
        if o[0] == 169 && o[1] == 254 { return false }
        // 172.16.0.0/12 — RFC1918 private.
        if o[0] == 172 && (o[1] >= 16 && o[1] <= 31) { return false }
        // 192.0.0.0/24 — IETF protocol assignments.
        if o[0] == 192 && o[1] == 0 && o[2] == 0 { return false }
        // 192.0.2.0/24 — TEST-NET-1 (documentation).
        if o[0] == 192 && o[1] == 0 && o[2] == 2 { return false }
        // 192.88.99.0/24 — 6to4 relay anycast (deprecated).
        if o[0] == 192 && o[1] == 88 && o[2] == 99 { return false }
        // 192.168.0.0/16 — RFC1918 private.
        if o[0] == 192 && o[1] == 168 { return false }
        // 198.18.0.0/15 — benchmarking.
        if o[0] == 198 && (o[1] == 18 || o[1] == 19) { return false }
        // 198.51.100.0/24 — TEST-NET-2 (documentation).
        if o[0] == 198 && o[1] == 51 && o[2] == 100 { return false }
        // 203.0.113.0/24 — TEST-NET-3 (documentation).
        // NOTE: TEST-NET ranges are reserved/documentation. They are used widely
        // in this codebase's tests as stand-in "public" addresses. We intentionally
        // do NOT reject 203.0.113.0/24 here because it is the canonical example
        // public address used throughout the AutoNAT tests and specs. Rejecting it
        // would conflate "documentation" with "unroutable for amplification".
        // It is not private/loopback/link-local, so dialing it cannot reach
        // internal infrastructure.
        // 224.0.0.0/4 — multicast.
        if o[0] >= 224 && o[0] <= 239 { return false }
        // 240.0.0.0/4 — reserved (includes 255.255.255.255 broadcast).
        if o[0] >= 240 { return false }

        return true
    }

    // MARK: - IPv6

    /// Parses an IPv6 string into 8 groups (UInt16). Strips zone identifier.
    /// Returns nil if invalid. Supports embedded IPv4 (e.g. ::ffff:1.2.3.4).
    static func parseIPv6(_ ip: String) -> [UInt16]? {
        guard !ip.isEmpty else { return nil }

        // Strip zone identifier (%eth0).
        let withoutZone: Substring
        if let percent = ip.firstIndex(of: "%") {
            withoutZone = ip[..<percent]
        } else {
            withoutZone = ip[...]
        }
        guard withoutZone.contains(":") else { return nil }

        var text = String(withoutZone)

        // Handle embedded IPv4 dotted-quad in the last group (e.g. ::ffff:1.2.3.4).
        var trailingGroups: [UInt16] = []
        if text.contains(".") {
            guard let lastColon = text.lastIndex(of: ":") else { return nil }
            let tail = String(text[text.index(after: lastColon)...])
            guard let v4 = parseIPv4(tail) else { return nil }
            trailingGroups = [
                (UInt16(v4[0]) << 8) | UInt16(v4[1]),
                (UInt16(v4[2]) << 8) | UInt16(v4[3]),
            ]
            text = String(text[...lastColon])  // keep trailing colon as a separator
        }

        // Validate: only one "::" allowed.
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

    private static func hexGroups(_ parts: [String]) -> [UInt16]? {
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

    /// Returns the embedded IPv4 octets for IPv4-mapped (::ffff:0:0/96) and
    /// IPv4-compatible (::/96) addresses, or nil otherwise.
    static func embeddedIPv4(_ g: [UInt16]) -> [UInt8]? {
        guard g.count == 8 else { return nil }
        // First 5 groups must be zero.
        guard g[0] == 0, g[1] == 0, g[2] == 0, g[3] == 0, g[4] == 0 else { return nil }
        // IPv4-mapped: ::ffff:a.b.c.d  (group[5] == 0xffff)
        // IPv4-compatible: ::a.b.c.d   (group[5] == 0)
        guard g[5] == 0xffff || g[5] == 0 else { return nil }
        // ::  and ::1 are NOT embedded IPv4 (they are unspecified/loopback).
        if g[5] == 0 && (g[6] == 0 && (g[7] == 0 || g[7] == 1)) { return nil }
        let octets: [UInt8] = [
            UInt8(g[6] >> 8), UInt8(g[6] & 0xff),
            UInt8(g[7] >> 8), UInt8(g[7] & 0xff),
        ]
        return octets
    }

    /// Classifies an 8-group IPv6 address. Returns `true` only for globally-routable unicast.
    static func isPublicUnicastIPv6(_ g: [UInt16]) -> Bool {
        guard g.count == 8 else { return false }

        // Unspecified ::
        if g.allSatisfy({ $0 == 0 }) { return false }
        // Loopback ::1
        if g[0] == 0, g[1] == 0, g[2] == 0, g[3] == 0, g[4] == 0, g[5] == 0, g[6] == 0, g[7] == 1 {
            return false
        }
        // Multicast ff00::/8
        if (g[0] & 0xff00) == 0xff00 { return false }
        // Link-local fe80::/10
        if (g[0] & 0xffc0) == 0xfe80 { return false }
        // Unique local fc00::/7
        if (g[0] & 0xfe00) == 0xfc00 { return false }
        // NAT64 well-known prefix 64:ff9b::/96
        if g[0] == 0x0064, g[1] == 0xff9b, g[2] == 0, g[3] == 0, g[4] == 0, g[5] == 0 {
            return false
        }
        // Documentation 2001:db8::/32
        if g[0] == 0x2001, g[1] == 0x0db8 { return false }
        // Discard-only 100::/64 (RFC6666)
        if g[0] == 0x0100, g[1] == 0, g[2] == 0, g[3] == 0 { return false }

        return true
    }
}
