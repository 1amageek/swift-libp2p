/// Protocol definitions for Multiaddr.
/// https://github.com/multiformats/multiaddr/blob/master/protocols.csv

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A protocol component in a Multiaddr.
public enum MultiaddrProtocol: Sendable, Hashable {
    case ip4(String)
    case ip6zone(String)
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
    case webtransport
    case certhash(Data)
    case ble(Data)
    case wifiDirect(Data)
    case lora(Data)
    case nfc(Data)

    /// The protocol code as defined in the multiaddr spec.
    public var code: UInt64 {
        switch self {
        case .ip4: return 4
        case .ip6zone: return 42
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
        case .webtransport: return 480
        case .certhash: return 466
        case .ble: return 0x01B0        // Custom code for BLE transport
        case .wifiDirect: return 0x01B1 // Custom code for WiFi Direct transport
        case .lora: return 0x01B2       // Custom code for LoRa transport
        case .nfc: return 0x01B3        // Custom code for NFC transport
        }
    }

    /// The protocol name.
    public var name: String {
        switch self {
        case .ip4: return "ip4"
        case .ip6zone: return "ip6zone"
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
        case .webtransport: return "webtransport"
        case .certhash: return "certhash"
        case .ble: return "ble"
        case .wifiDirect: return "wifi-direct"
        case .lora: return "lora"
        case .nfc: return "nfc"
        }
    }

    /// The string representation of this protocol's value.
    public var valueString: String? {
        switch self {
        case .ip4(let addr): return addr
        case .ip6zone(let zone): return zone
        case .ip6(let addr): return addr
        case .tcp(let port): return String(port)
        case .udp(let port): return String(port)
        case .quic, .quicV1, .ws, .wss, .p2pCircuit, .webrtcDirect, .webtransport: return nil
        case .ble(let data), .wifiDirect(let data), .lora(let data), .nfc(let data):
            return data.map { String(format: "%02x", $0) }.joined()
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
        case .ip6zone(let zone):
            let bytes = Data(zone.utf8)
            return Varint.encode(UInt64(bytes.count)) + bytes
        case .ip6(let addr):
            guard let bytes = Self.encodeIPv6(addr) else {
                preconditionFailure("Invalid IPv6 address stored in MultiaddrProtocol.ip6: \(addr)")
            }
            return bytes
        case .tcp(let port), .udp(let port):
            return Self.encodePort(port)
        case .quic, .quicV1, .ws, .wss, .p2pCircuit, .webrtcDirect, .webtransport:
            return Data()
        case .ble(let data), .wifiDirect(let data), .lora(let data), .nfc(let data):
            return Varint.encode(UInt64(data.count)) + data
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
        var addr = in_addr()
        let result = address.withCString { cString in
            inet_pton(AF_INET, cString, &addr)
        }
        guard result == 1 else { return nil }

        return withUnsafeBytes(of: &addr.s_addr) { bytes in
            Data(bytes)
        }
    }

    private static func encodeIPv6(_ address: String) -> Data? {
        // 1. Strip zone ID (e.g., fe80::1%eth0 → fe80::1)
        let cleanAddress: String
        if let percentIndex = address.firstIndex(of: "%") {
            cleanAddress = String(address[..<percentIndex])
        } else {
            cleanAddress = address
        }
        guard !cleanAddress.isEmpty else { return nil }

        var addr = in6_addr()
        let result = cleanAddress.withCString { cString in
            inet_pton(AF_INET6, cString, &addr)
        }
        guard result == 1 else { return nil }

        return withUnsafeBytes(of: &addr) { bytes in
            Data(bytes)
        }
    }

    /// Normalizes an IPv6 address to RFC 5952 compressed form (e.g., "::1", "fe80::1").
    ///
    /// This function:
    /// - Expands `::` shorthand to full 8 groups
    /// - Strips zone IDs (e.g., `%eth0`)
    /// - Handles IPv4-mapped addresses (e.g., `::ffff:192.0.2.1`)
    /// - Rejects invalid addresses (multiple `::`, malformed groups)
    /// - Compresses the longest run of zero groups per RFC 5952
    ///
    /// - Parameter address: The IPv6 address string to normalize
    /// - Returns: The normalized IPv6 address in RFC 5952 compressed form, or nil if invalid or too long (>64 chars with zone)
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

        return compressIPv6(groups)
    }

    /// Compresses 8 IPv6 groups into RFC 5952 form.
    ///
    /// RFC 5952 rules:
    /// - Find the longest run of consecutive zero groups (minimum length 2)
    /// - If tied, use the first occurrence
    /// - Replace with "::"
    /// - Leading zeros in each group are suppressed
    static func compressIPv6(_ groups: [UInt16]) -> String {
        // Find the longest run of consecutive zero groups
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

        // Only compress runs of 2 or more zeros (RFC 5952 §4.2.3)
        if bestLen < 2 {
            bestStart = -1
            bestLen = 0
        }

        // Build compressed string
        var parts: [String] = []
        var i = 0
        while i < 8 {
            if i == bestStart {
                // Insert "::" marker
                if i == 0 { parts.append("") }
                parts.append("")
                i += bestLen
                if i == 8 { parts.append("") }
            } else {
                parts.append(String(groups[i], radix: 16))
                i += 1
            }
        }

        return parts.joined(separator: ":")
    }

    private static func encodePort(_ port: UInt16) -> Data {
        Data([UInt8(port >> 8), UInt8(port & 0xFF)])
    }

    static func isValidIPv4(_ address: String) -> Bool {
        encodeIPv4(address) != nil
    }

    static func isValidIPv6(_ address: String) -> Bool {
        encodeIPv6(address) != nil
    }

    // MARK: - Decoding

    /// Creates a protocol from its code and value bytes.
    public static func decode(code: UInt64, from data: Data) throws -> (MultiaddrProtocol, Int) {
        switch code {
        case 4: // ip4
            guard data.count >= 4 else { throw MultiaddrError.invalidAddress }
            let addr = data.prefix(4).map { String($0) }.joined(separator: ".")
            return (.ip4(addr), 4)

        case 42: // ip6zone
            let (length, lengthBytes) = try Varint.decode(data)
            guard length <= 1024 else { throw MultiaddrError.fieldTooLarge }
            let len = Int(length)
            let start = data.dropFirst(lengthBytes)
            guard start.count >= len else { throw MultiaddrError.invalidAddress }
            let zone = String(decoding: start.prefix(len), as: UTF8.self)
            guard isValidZoneID(zone) else { throw MultiaddrError.invalidAddress }
            return (.ip6zone(zone), lengthBytes + len)

        case 41: // ip6
            guard data.count >= 16 else { throw MultiaddrError.invalidAddress }
            var groups: [UInt16] = []
            for i in 0..<8 {
                let value = UInt16(data[i * 2]) << 8 | UInt16(data[i * 2 + 1])
                groups.append(value)
            }
            return (.ip6(compressIPv6(groups)), 16)

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

        case 480: // webtransport
            return (.webtransport, 0)

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

        case 0x01B0, 0x01B1, 0x01B2, 0x01B3: // ble, wifi-direct, lora, nfc
            let (length, lengthBytes) = try Varint.decode(data)
            guard length <= 256 else { throw MultiaddrError.fieldTooLarge }
            let len = Int(length)
            let start = data.dropFirst(lengthBytes)
            guard start.count >= len else { throw MultiaddrError.invalidAddress }
            let addrData = Data(start.prefix(len))
            let proto: MultiaddrProtocol
            switch code {
            case 0x01B0: proto = .ble(addrData)
            case 0x01B1: proto = .wifiDirect(addrData)
            case 0x01B2: proto = .lora(addrData)
            case 0x01B3: proto = .nfc(addrData)
            default: throw MultiaddrError.unknownProtocol(code)
            }
            return (proto, lengthBytes + len)

        default:
            throw MultiaddrError.unknownProtocol(code)
        }
    }

    /// Creates a protocol from its name and value string.
    static func requiresValue(name: String) -> Bool? {
        switch name {
        case "ip4", "ip6zone", "ip6", "tcp", "udp", "p2p", "ipfs",
             "dns", "dns4", "dns6", "dnsaddr", "unix", "memory",
             "certhash", "ble", "wifi-direct", "lora", "nfc":
            return true
        case "quic", "quic-v1", "ws", "wss", "p2p-circuit", "webrtc-direct", "webtransport":
            return false
        default:
            return nil
        }
    }

    /// Creates a protocol from its name and value string.
    public static func parse(name: String, value: String?) throws -> MultiaddrProtocol {
        switch name {
        case "ip4":
            guard let v = value else { throw MultiaddrError.missingValue }
            guard encodeIPv4(v) != nil else { throw MultiaddrError.invalidAddress }
            return .ip4(v)
        case "ip6zone":
            guard let v = value else { throw MultiaddrError.missingValue }
            guard isValidZoneID(v) else { throw MultiaddrError.invalidAddress }
            return .ip6zone(v)
        case "ip6":
            guard let v = value else { throw MultiaddrError.missingValue }
            if let percent = v.firstIndex(of: "%") {
                let base = String(v[..<percent])
                let zoneStart = v.index(after: percent)
                let zone = String(v[zoneStart...])
                guard !zone.isEmpty else { throw MultiaddrError.invalidAddress }
                guard zone.utf8.count <= 32 else { throw MultiaddrError.invalidAddress }
                guard let normalized = normalizeIPv6(base) else { throw MultiaddrError.invalidAddress }
                return .ip6("\(normalized)%\(zone)")
            }
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
        case "webtransport":
            return .webtransport
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
        case "ble", "wifi-direct", "lora", "nfc":
            guard let v = value else { throw MultiaddrError.missingValue }
            // Decode hex string to bytes
            var bytes = Data()
            var hex = v[...]
            while hex.count >= 2 {
                let byteStr = String(hex.prefix(2))
                hex = hex.dropFirst(2)
                guard let byte = UInt8(byteStr, radix: 16) else {
                    throw MultiaddrError.invalidAddress
                }
                bytes.append(byte)
            }
            guard hex.isEmpty else { throw MultiaddrError.invalidAddress }
            switch name {
            case "ble": return .ble(bytes)
            case "wifi-direct": return .wifiDirect(bytes)
            case "lora": return .lora(bytes)
            case "nfc": return .nfc(bytes)
            default: throw MultiaddrError.unknownProtocolName(name)
            }
        default:
            throw MultiaddrError.unknownProtocolName(name)
        }
    }

    public static func isValidZoneID(_ zone: String) -> Bool {
        guard !zone.isEmpty, zone.utf8.count <= 32 else { return false }
        return !zone.contains("/")
    }
}
