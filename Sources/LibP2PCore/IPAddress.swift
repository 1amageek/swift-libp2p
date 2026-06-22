/// Foundation-free IPv4 / IPv6 textual <-> binary codecs.
///
/// Embedded-clean: no Foundation, no `inet_pton`/`inet_ntop`, no `any`.
/// These parse/format IP address strings to/from their wire bytes over
/// `[UInt8]`. They replace the historical `inet_pton`-based path so the
/// Multiaddr binary codec can live in the Embedded-clean core. The `Data`
/// surface lives in the `P2PCore` adapter.

public enum IPAddress {

    // MARK: - IPv4

    /// Encodes a dotted-decimal IPv4 address (e.g. "192.168.1.1") to its 4
    /// network-order bytes.
    ///
    /// - Parameter address: The dotted-decimal address string.
    /// - Returns: The 4 address bytes, or `nil` if the string is not a valid
    ///   IPv4 address. Accepts exactly 4 decimal octets in `0...255` with no
    ///   leading-zero ambiguity beyond a single "0", matching `inet_pton`'s
    ///   strict form.
    public static func encodeIPv4(_ address: String) -> [UInt8]? {
        let utf8 = Array(address.utf8)
        guard !utf8.isEmpty else { return nil }

        var octets: [UInt8] = []
        octets.reserveCapacity(4)

        var i = 0
        let count = utf8.count
        while true {
            // Parse one octet: 1-3 decimal digits.
            var digits = 0
            var value = 0
            while i < count, let d = decimalValue(utf8[i]) {
                // Reject leading zeros (e.g. "01") to match inet_pton strictness.
                if digits == 1 && value == 0 {
                    return nil
                }
                value = value * 10 + Int(d)
                digits += 1
                i += 1
                if digits > 3 { return nil }
            }
            guard digits > 0, value <= 255 else { return nil }
            octets.append(UInt8(value))

            if octets.count == 4 {
                // Must be at end of string.
                return i == count ? octets : nil
            }

            // Expect a separator dot.
            guard i < count, utf8[i] == UInt8(ascii: ".") else { return nil }
            i += 1
        }
    }

    /// Formats 4 network-order IPv4 bytes as a dotted-decimal string.
    ///
    /// - Parameter bytes: Exactly 4 address bytes.
    /// - Returns: The dotted-decimal string, or `nil` if `bytes.count != 4`.
    public static func formatIPv4(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 4 else { return nil }
        var result = ""
        for (index, byte) in bytes.enumerated() {
            if index > 0 { result.append(".") }
            result.append(String(byte))
        }
        return result
    }

    // MARK: - IPv6

    /// Encodes an IPv6 address string (e.g. "fe80::1", "::1",
    /// "::ffff:192.0.2.1") to its 16 network-order bytes.
    ///
    /// Supports `::` zero-run compression and a trailing IPv4-dotted-quad
    /// (IPv4-mapped form). Does NOT accept a zone ID — the caller strips any
    /// `%zone` suffix first.
    ///
    /// - Parameter address: The IPv6 address string (no zone suffix).
    /// - Returns: The 16 address bytes, or `nil` if the string is not a valid
    ///   IPv6 address.
    public static func encodeIPv6(_ address: String) -> [UInt8]? {
        let utf8 = Array(address.utf8)
        guard !utf8.isEmpty else { return nil }

        // Split into head (before "::") and tail (after "::") group lists.
        // A single "::" compresses one or more all-zero groups.
        var head: [UInt16] = []
        var tail: [UInt16] = []
        var sawDoubleColon = false

        var i = 0
        let count = utf8.count

        // Leading "::"
        if count >= 2 && utf8[0] == UInt8(ascii: ":") && utf8[1] == UInt8(ascii: ":") {
            sawDoubleColon = true
            i = 2
            // "::" alone is the all-zero address.
            if i == count {
                return [UInt8](repeating: 0, count: 16)
            }
        } else if utf8[0] == UInt8(ascii: ":") {
            // A single leading colon (not "::") is invalid.
            return nil
        }

        func append(_ group: UInt16) -> Bool {
            if sawDoubleColon {
                tail.append(group)
            } else {
                head.append(group)
            }
            return true
        }

        while i < count {
            // Try to parse an embedded IPv4 (only valid as the final element).
            if containsDot(utf8, from: i) {
                guard let v4 = encodeIPv4(String(decoding: utf8[i..<count], as: UTF8.self)) else {
                    return nil
                }
                let g0 = UInt16(v4[0]) << 8 | UInt16(v4[1])
                let g1 = UInt16(v4[2]) << 8 | UInt16(v4[3])
                _ = append(g0)
                _ = append(g1)
                i = count
                break
            }

            // Parse a hextet: 1-4 hex digits.
            var digits = 0
            var value: UInt32 = 0
            while i < count, let h = hexValue(utf8[i]) {
                value = value << 4 | UInt32(h)
                digits += 1
                i += 1
                if digits > 4 { return nil }
            }
            guard digits > 0 else { return nil }
            _ = append(UInt16(value))

            if i == count { break }

            // Separator handling.
            guard utf8[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            if i < count && utf8[i] == UInt8(ascii: ":") {
                // Second "::" is invalid.
                if sawDoubleColon { return nil }
                sawDoubleColon = true
                i += 1
                // Trailing "::" terminates the address.
                if i == count { break }
            } else if i == count {
                // Trailing single colon (not part of "::") is invalid.
                return nil
            }
        }

        let totalGroups = head.count + tail.count
        if sawDoubleColon {
            guard totalGroups <= 7 else { return nil }
        } else {
            guard totalGroups == 8 else { return nil }
        }

        var groups = [UInt16](repeating: 0, count: 8)
        for (index, g) in head.enumerated() {
            groups[index] = g
        }
        if sawDoubleColon {
            let tailStart = 8 - tail.count
            for (index, g) in tail.enumerated() {
                groups[tailStart + index] = g
            }
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for g in groups {
            bytes.append(UInt8(g >> 8))
            bytes.append(UInt8(g & 0xFF))
        }
        return bytes
    }

    // MARK: - Helpers

    @inline(__always)
    static func decimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        default:
            return nil
        }
    }

    @inline(__always)
    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }

    /// Whether a "." appears in `utf8[from...]` before the next ":".
    @inline(__always)
    static func containsDot(_ utf8: [UInt8], from: Int) -> Bool {
        var i = from
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: ".") { return true }
            if utf8[i] == UInt8(ascii: ":") { return false }
            i += 1
        }
        return false
    }
}
