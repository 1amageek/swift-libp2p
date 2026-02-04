/// Protocol definitions for Multiaddr.
/// https://github.com/multiformats/multiaddr/blob/master/protocols.csv

import Foundation

/// A protocol component in a Multiaddr.
public enum MultiaddrProtocol: Sendable, Hashable {
    case ip4(String)
    case ip6(String)
    case tcp(UInt16)
    case udp(UInt16)
    case quic
    case quicV1
    case ws
    case wss
    case p2p(PeerID)
    case dns(String)
    case dns4(String)
    case dns6(String)
    case dnsaddr(String)
    case unix(String)
    case memory(String)
    case p2pCircuit
    case webrtcDirect
    case certhash(Data)

    /// The protocol code as defined in the multiaddr spec.
    public var code: UInt64 {
        switch self {
        case .ip4: return 4
        case .ip6: return 41
        case .tcp: return 6
        case .udp: return 273
        case .quic: return 460
        case .quicV1: return 461
        case .ws: return 477
        case .wss: return 478
        case .p2p: return 421
        case .dns: return 53
        case .dns4: return 54
        case .dns6: return 55
        case .dnsaddr: return 56
        case .unix: return 400
        case .memory: return 777  // Custom code for in-memory transport
        case .p2pCircuit: return 290
        case .webrtcDirect: return 276
        case .certhash: return 466
        }
    }

    /// The protocol name.
    public var name: String {
        switch self {
        case .ip4: return "ip4"
        case .ip6: return "ip6"
        case .tcp: return "tcp"
        case .udp: return "udp"
        case .quic: return "quic"
        case .quicV1: return "quic-v1"
        case .ws: return "ws"
        case .wss: return "wss"
        case .p2p: return "p2p"
        case .dns: return "dns"
        case .dns4: return "dns4"
        case .dns6: return "dns6"
        case .dnsaddr: return "dnsaddr"
        case .unix: return "unix"
        case .memory: return "memory"
        case .p2pCircuit: return "p2p-circuit"
        case .webrtcDirect: return "webrtc-direct"
        case .certhash: return "certhash"
        }
    }

    /// The string representation of this protocol's value.
    public var valueString: String? {
        switch self {
        case .ip4(let addr): return addr
        case .ip6(let addr): return addr
        case .tcp(let port): return String(port)
        case .udp(let port): return String(port)
        case .quic, .quicV1, .ws, .wss, .p2pCircuit, .webrtcDirect: return nil
        case .certhash(let hash):
            // Encode as multibase base64url (prefix 'u')
            let base64url = hash.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "u" + base64url
        case .p2p(let peerID): return peerID.description
        case .dns(let name): return name
        case .dns4(let name): return name
        case .dns6(let name): return name
        case .dnsaddr(let name): return name
        case .unix(let path): return path
        case .memory(let id): return id
        }
    }

    /// The binary representation of this protocol's value.
    public var valueBytes: Data {
        switch self {
        case .ip4(let addr):
            guard let bytes = Self.encodeIPv4(addr) else {
                preconditionFailure("Invalid IPv4 address stored in MultiaddrProtocol.ip4: \(addr)")
            }
            return bytes
        case .ip6(let addr):
            guard let bytes = Self.encodeIPv6(addr) else {
                preconditionFailure("Invalid IPv6 address stored in MultiaddrProtocol.ip6: \(addr)")
            }
            return bytes
        case .tcp(let port), .udp(let port):
            return Self.encodePort(port)
        case .quic, .quicV1, .ws, .wss, .p2pCircuit, .webrtcDirect:
            return Data()
        case .certhash(let hash):
            return Varint.encode(UInt64(hash.count)) + hash
        case .p2p(let peerID):
            let bytes = peerID.bytes
            return Varint.encode(UInt64(bytes.count)) + bytes
        case .dns(let name), .dns4(let name), .dns6(let name), .dnsaddr(let name):
            let bytes = Data(name.utf8)
            return Varint.encode(UInt64(bytes.count)) + bytes
        case .unix(let path):
            let bytes = Data(path.utf8)
            return Varint.encode(UInt64(bytes.count)) + bytes
        case .memory(let id):
            let bytes = Data(id.utf8)
            return Varint.encode(UInt64(bytes.count)) + bytes
        }
    }

    /// The full binary representation including code and value.
    public var bytes: Data {
        Varint.encode(code) + valueBytes
    }

    // MARK: - Encoding Helpers

    private static func encodeIPv4(_ address: String) -> Data? {
        // Single-pass parsing without string allocation
        var bytes = Data(capacity: 4)
        var current: UInt16 = 0
        var digitCount = 0
        var byteCount = 0

        for char in address.utf8 {
            if char == UInt8(ascii: ".") {
                guard digitCount > 0, digitCount <= 3, current <= 255 else { return nil }
                bytes.append(UInt8(current))
                byteCount += 1
                current = 0
                digitCount = 0
            } else if char >= UInt8(ascii: "0") && char <= UInt8(ascii: "9") {
                digitCount += 1
                guard digitCount <= 3 else { return nil }
                current = current * 10 + UInt16(char - UInt8(ascii: "0"))
                guard current <= 255 else { return nil }
            } else {
                return nil  // Invalid character
            }
        }

        // Last byte
        guard digitCount > 0, digitCount <= 3, current <= 255, byteCount == 3 else { return nil }
        bytes.append(UInt8(current))

        return bytes
    }

    /// Parses colon-separated hex groups from an IPv6 address substring.
    ///
    /// - Parameter substring: A substring containing hex groups separated by colons
    /// - Returns: Array of UInt16 values, or empty array on parse error
    private static func parseIPv6Groups(_ substring: Substring) -> [UInt16] {
        var groups: [UInt16] = []
        var current: UInt16 = 0
        var digitCount = 0

        for char in substring.utf8 {
            if char == UInt8(ascii: ":") {
                guard digitCount > 0, digitCount <= 4 else { return [] }
                groups.append(current)
                current = 0
                digitCount = 0
            } else {
                // Parse hex digit
                let value: UInt16
                if char >= UInt8(ascii: "0") && char <= UInt8(ascii: "9") {
                    value = UInt16(char - UInt8(ascii: "0"))
                } else if char >= UInt8(ascii: "a") && char <= UInt8(ascii: "f") {
                    value = UInt16(char - UInt8(ascii: "a") + 10)
                } else if char >= UInt8(ascii: "A") && char <= UInt8(ascii: "F") {
                    value = UInt16(char - UInt8(ascii: "A") + 10)
                } else {
                    return []  // Invalid character
                }

                digitCount += 1
                guard digitCount <= 4 else { return [] }
                current = (current << 4) | value
            }
        }

        // Last group
        guard digitCount > 0, digitCount <= 4 else { return [] }
        groups.append(current)

        return groups
    }

    private static func encodeIPv6(_ address: String) -> Data? {
        // 1. Strip zone ID (e.g., fe80::1%eth0 → fe80::1)
        let cleanAddress: String
        if let percentIndex = address.firstIndex(of: "%") {
            cleanAddress = String(address[..<percentIndex])
        } else {
            cleanAddress = address
        }

        // 2. Validate: only one :: allowed (optimized single-pass check)
        var doubleColonCount = 0
        var i = cleanAddress.startIndex
        while i < cleanAddress.endIndex {
            if cleanAddress[i] == ":" {
                let next = cleanAddress.index(after: i)
                if next < cleanAddress.endIndex && cleanAddress[next] == ":" {
                    doubleColonCount += 1
                    guard doubleColonCount <= 1 else { return nil }
                    i = cleanAddress.index(after: next)
                    continue
                }
            }
            i = cleanAddress.index(after: i)
        }

        // 3. Handle IPv4-mapped IPv6 (::ffff:192.0.2.1 or ::ffff:c0a8:101)
        if cleanAddress.lowercased().hasPrefix("::ffff:") {
            let suffix = String(cleanAddress.dropFirst(7))
            // Check if it's IPv4 dotted notation
            if suffix.contains(".") {
                if let ipv4Bytes = encodeIPv4(suffix) {
                    var bytes = Data(repeating: 0, count: 16)
                    bytes[10] = 0xff
                    bytes[11] = 0xff
                    bytes[12] = ipv4Bytes[0]
                    bytes[13] = ipv4Bytes[1]
                    bytes[14] = ipv4Bytes[2]
                    bytes[15] = ipv4Bytes[3]
                    return bytes
                }
                return nil
            }
            // Fall through to normal hex parsing for ::ffff:c0a8:101 format
        }

        // 4. Handle :: expansion - optimized parsing
        var bytes = Data(count: 16)

        if let doubleColonRange = cleanAddress.range(of: "::") {
            // Split by :: without string allocation
            let beforeDouble = cleanAddress[..<doubleColonRange.lowerBound]
            let afterDouble = cleanAddress[doubleColonRange.upperBound...]

            // Parse left groups
            var leftGroups: [UInt16] = []
            if !beforeDouble.isEmpty {
                leftGroups = parseIPv6Groups(beforeDouble)
                guard !leftGroups.isEmpty || beforeDouble == "" else { return nil }
            }

            // Parse right groups
            var rightGroups: [UInt16] = []
            if !afterDouble.isEmpty {
                rightGroups = parseIPv6Groups(afterDouble)
                guard !rightGroups.isEmpty || afterDouble == "" else { return nil }
            }

            let missing = 8 - leftGroups.count - rightGroups.count
            guard missing >= 0 else { return nil }

            // Write groups to bytes
            for (idx, group) in leftGroups.enumerated() {
                bytes[idx * 2] = UInt8(group >> 8)
                bytes[idx * 2 + 1] = UInt8(group & 0xFF)
            }
            for (idx, group) in rightGroups.enumerated() {
                let offset = (leftGroups.count + missing + idx) * 2
                bytes[offset] = UInt8(group >> 8)
                bytes[offset + 1] = UInt8(group & 0xFF)
            }
        } else {
            // No :: - parse all 8 groups
            let groups = parseIPv6Groups(cleanAddress[...])
            guard groups.count == 8 else { return nil }

            for (idx, group) in groups.enumerated() {
                bytes[idx * 2] = UInt8(group >> 8)
                bytes[idx * 2 + 1] = UInt8(group & 0xFF)
            }
        }

        return bytes
    }

    /// Normalizes an IPv6 address to expanded form (e.g., "::1" → "0:0:0:0:0:0:0:1").
    ///
    /// This function:
    /// - Expands `::` shorthand to full 8 groups
    /// - Strips zone IDs (e.g., `%eth0`)
    /// - Handles IPv4-mapped addresses (e.g., `::ffff:192.0.2.1`)
    /// - Rejects invalid addresses (multiple `::`, malformed groups)
    ///
    /// - Parameter address: The IPv6 address string to normalize
    /// - Returns: The normalized IPv6 address in expanded form, or nil if invalid or too long (>64 chars with zone)
    static func normalizeIPv6(_ address: String) -> String? {
        // Max IPv6 address length with zone ID is ~64 chars
        guard address.count <= 64 else { return nil }
        guard let bytes = encodeIPv6(address) else { return nil }

        // Parse into 16-bit groups
        var groups: [UInt16] = []
        for i in 0..<8 {
            let value = UInt16(bytes[i * 2]) << 8 | UInt16(bytes[i * 2 + 1])
            groups.append(value)
        }

        // Build expanded string (always 8 groups separated by colons)
        return groups.map { String($0, radix: 16) }.joined(separator: ":")
    }

    private static func encodePort(_ port: UInt16) -> Data {
        Data([UInt8(port >> 8), UInt8(port & 0xFF)])
    }

    // MARK: - Decoding

    /// Creates a protocol from its code and value bytes.
    public static func decode(code: UInt64, from data: Data) throws -> (MultiaddrProtocol, Int) {
        switch code {
        case 4: // ip4
            guard data.count >= 4 else { throw MultiaddrError.invalidAddress }
            let addr = data.prefix(4).map { String($0) }.joined(separator: ".")
            return (.ip4(addr), 4)

        case 41: // ip6
            guard data.count >= 16 else { throw MultiaddrError.invalidAddress }
            var parts: [String] = []
            for i in 0..<8 {
                let value = UInt16(data[i * 2]) << 8 | UInt16(data[i * 2 + 1])
                parts.append(String(value, radix: 16))
            }
            return (.ip6(parts.joined(separator: ":")), 16)

        case 6: // tcp
            guard data.count >= 2 else { throw MultiaddrError.invalidAddress }
            let port = UInt16(data[0]) << 8 | UInt16(data[1])
            return (.tcp(port), 2)

        case 273: // udp
            guard data.count >= 2 else { throw MultiaddrError.invalidAddress }
            let port = UInt16(data[0]) << 8 | UInt16(data[1])
            return (.udp(port), 2)

        case 460: // quic
            return (.quic, 0)

        case 461: // quic-v1
            return (.quicV1, 0)

        case 477: // ws
            return (.ws, 0)

        case 478: // wss
            return (.wss, 0)

        case 290: // p2p-circuit
            return (.p2pCircuit, 0)

        case 276: // webrtc-direct
            return (.webrtcDirect, 0)

        case 466: // certhash
            let (length, lengthBytes) = try Varint.decode(data)
            guard length <= 1024 else { throw MultiaddrError.fieldTooLarge }
            let len = Int(length)
            let start = data.dropFirst(lengthBytes)
            guard start.count >= len else { throw MultiaddrError.invalidAddress }
            let hash = Data(start.prefix(len))
            return (.certhash(hash), lengthBytes + len)

        case 421: // p2p
            let (length, lengthBytes) = try Varint.decode(data)
            // PeerIDs are typically < 100 bytes, 4KB is more than enough
            guard length <= 4096 else { throw MultiaddrError.fieldTooLarge }
            let len = Int(length)
            let start = data.dropFirst(lengthBytes)
            guard start.count >= len else { throw MultiaddrError.invalidAddress }
            let peerIDBytes = Data(start.prefix(len))
            let peerID = try PeerID(bytes: peerIDBytes)
            return (.p2p(peerID), lengthBytes + len)

        case 53, 54, 55, 56: // dns, dns4, dns6, dnsaddr
            let (length, lengthBytes) = try Varint.decode(data)
            // DNS names should be < 256 bytes according to spec
            guard length <= 4096 else { throw MultiaddrError.fieldTooLarge }
            let len = Int(length)
            let start = data.dropFirst(lengthBytes)
            guard start.count >= len else { throw MultiaddrError.invalidAddress }
            let name = String(decoding: start.prefix(len), as: UTF8.self)
            let proto: MultiaddrProtocol
            switch code {
            case 53: proto = .dns(name)
            case 54: proto = .dns4(name)
            case 55: proto = .dns6(name)
            case 56: proto = .dnsaddr(name)
            default: throw MultiaddrError.unknownProtocol(code)
            }
            return (proto, lengthBytes + len)

        case 400: // unix
            let (length, lengthBytes) = try Varint.decode(data)
            // Unix paths should be < 4KB
            guard length <= 4096 else { throw MultiaddrError.fieldTooLarge }
            let len = Int(length)
            let start = data.dropFirst(lengthBytes)
            guard start.count >= len else { throw MultiaddrError.invalidAddress }
            let path = String(decoding: start.prefix(len), as: UTF8.self)
            return (.unix(path), lengthBytes + len)

        case 777: // memory
            let (length, lengthBytes) = try Varint.decode(data)
            // Memory IDs should be short
            guard length <= 1024 else { throw MultiaddrError.fieldTooLarge }
            let len = Int(length)
            let start = data.dropFirst(lengthBytes)
            guard start.count >= len else { throw MultiaddrError.invalidAddress }
            let id = String(decoding: start.prefix(len), as: UTF8.self)
            return (.memory(id), lengthBytes + len)

        default:
            throw MultiaddrError.unknownProtocol(code)
        }
    }

    /// Creates a protocol from its name and value string.
    public static func parse(name: String, value: String?) throws -> MultiaddrProtocol {
        switch name {
        case "ip4":
            guard let v = value else { throw MultiaddrError.missingValue }
            guard encodeIPv4(v) != nil else { throw MultiaddrError.invalidAddress }
            return .ip4(v)
        case "ip6":
            guard let v = value else { throw MultiaddrError.missingValue }
            guard let normalized = normalizeIPv6(v) else { throw MultiaddrError.invalidAddress }
            return .ip6(normalized)
        case "tcp":
            guard let v = value, let port = UInt16(v) else { throw MultiaddrError.missingValue }
            return .tcp(port)
        case "udp":
            guard let v = value, let port = UInt16(v) else { throw MultiaddrError.missingValue }
            return .udp(port)
        case "quic":
            return .quic
        case "quic-v1":
            return .quicV1
        case "ws":
            return .ws
        case "wss":
            return .wss
        case "p2p-circuit":
            return .p2pCircuit
        case "p2p", "ipfs": // ipfs is legacy alias
            guard let v = value else { throw MultiaddrError.missingValue }
            let peerID = try PeerID(string: v)
            return .p2p(peerID)
        case "dns":
            guard let v = value else { throw MultiaddrError.missingValue }
            return .dns(v)
        case "dns4":
            guard let v = value else { throw MultiaddrError.missingValue }
            return .dns4(v)
        case "dns6":
            guard let v = value else { throw MultiaddrError.missingValue }
            return .dns6(v)
        case "dnsaddr":
            guard let v = value else { throw MultiaddrError.missingValue }
            return .dnsaddr(v)
        case "unix":
            guard let v = value else { throw MultiaddrError.missingValue }
            return .unix(v)
        case "memory":
            guard let v = value else { throw MultiaddrError.missingValue }
            return .memory(v)
        case "webrtc-direct":
            return .webrtcDirect
        case "certhash":
            guard let v = value else { throw MultiaddrError.missingValue }
            // Decode multibase base64url (prefix 'u')
            guard v.hasPrefix("u") else { throw MultiaddrError.invalidAddress }
            let base64url = String(v.dropFirst())
            let base64 = base64url
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            // Add padding if needed
            let paddedBase64: String
            let remainder = base64.count % 4
            if remainder > 0 {
                paddedBase64 = base64 + String(repeating: "=", count: 4 - remainder)
            } else {
                paddedBase64 = base64
            }
            guard let data = Data(base64Encoded: paddedBase64) else {
                throw MultiaddrError.invalidAddress
            }
            return .certhash(data)
        default:
            throw MultiaddrError.unknownProtocolName(name)
        }
    }
}
