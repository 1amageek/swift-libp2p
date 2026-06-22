/// RFC 5952 IPv6 compression and normalization.
///
/// Embedded-clean: no Foundation, no `any`. Compresses 8 IPv6 16-bit groups
/// into the canonical "::"-shortened textual form, and normalizes an arbitrary
/// IPv6 string to that form. Lives in the core so the Multiaddr binary codec
/// and factory helpers can canonicalize addresses without Foundation.

extension IPAddress {

    /// Compresses 8 IPv6 groups into RFC 5952 textual form.
    ///
    /// RFC 5952 rules:
    /// - Replace the longest run of consecutive zero groups (min length 2) with
    ///   "::"; on ties use the first occurrence.
    /// - Suppress leading zeros in each group; lowercase hex.
    ///
    /// - Parameter groups: Exactly 8 16-bit groups (behavior is undefined for
    ///   other counts; callers always pass 8).
    /// - Returns: The compressed textual form (e.g. "::1", "fe80::1").
    public static func compressIPv6(_ groups: [UInt16]) -> String {
        // Find the longest run of consecutive zero groups.
        var bestStart = -1
        var bestLen = 0
        var curStart = -1
        var curLen = 0

        for i in 0..<8 {
            if groups[i] == 0 {
                if curStart == -1 { curStart = i }
                curLen += 1
                if curLen > bestLen {
                    bestStart = curStart
                    bestLen = curLen
                }
            } else {
                curStart = -1
                curLen = 0
            }
        }

        // Only compress runs of 2 or more zeros (RFC 5952 §4.2.3).
        if bestLen < 2 {
            bestStart = -1
            bestLen = 0
        }

        var parts: [String] = []
        var i = 0
        while i < 8 {
            if i == bestStart {
                if i == 0 { parts.append("") }
                parts.append("")
                i += bestLen
                if i == 8 { parts.append("") }
            } else {
                parts.append(hexString(groups[i]))
                i += 1
            }
        }

        return joined(parts, separator: ":")
    }

    /// Normalizes an IPv6 address string to RFC 5952 compressed form.
    ///
    /// Strips a trailing `%zone` suffix, parses (expanding `::` and handling
    /// IPv4-mapped tails), and re-emits in compressed form. Rejects strings
    /// longer than 64 characters (with zone) or that fail to parse.
    ///
    /// - Parameter address: The IPv6 address string (zone suffix allowed).
    /// - Returns: The normalized address, or `nil` if invalid or too long.
    public static func normalizeIPv6(_ address: String) -> String? {
        guard address.count <= 64 else { return nil }

        // Strip zone ID (e.g. "fe80::1%eth0" -> "fe80::1").
        let clean: String
        if let percentIndex = address.firstIndex(of: "%") {
            clean = String(address[..<percentIndex])
        } else {
            clean = address
        }
        guard !clean.isEmpty else { return nil }

        guard let bytes = encodeIPv6(clean) else { return nil }

        var groups = [UInt16](repeating: 0, count: 8)
        for i in 0..<8 {
            groups[i] = UInt16(bytes[i * 2]) << 8 | UInt16(bytes[i * 2 + 1])
        }
        return compressIPv6(groups)
    }

    // MARK: - Foundation-free text helpers

    /// Lowercase hex string of a 16-bit group with leading zeros suppressed.
    @inline(__always)
    static func hexString(_ value: UInt16) -> String {
        if value == 0 { return "0" }
        let digits: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                   "8", "9", "a", "b", "c", "d", "e", "f"]
        var chars: [Character] = []
        var v = value
        while v > 0 {
            chars.append(digits[Int(v & 0xF)])
            v >>= 4
        }
        return String(chars.reversed())
    }

    /// Joins string parts with a separator (Foundation-free).
    @inline(__always)
    static func joined(_ parts: [String], separator: String) -> String {
        var result = ""
        for (index, part) in parts.enumerated() {
            if index > 0 { result.append(separator) }
            result.append(part)
        }
        return result
    }
}
