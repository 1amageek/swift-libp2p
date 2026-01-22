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
        }
    }

    /// The string representation of this protocol's value.
    public var valueString: String? {
        switch self {
        case .ip4(let addr): return addr
        case .ip6(let addr): return addr
        case .tcp(let port): return String(port)
        case .udp(let port): return String(port)
        case .quic, .quicV1, .ws, .wss, .p2pCircuit: return nil
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
            return Self.encodeIPv4(addr) ?? Data()
        case .ip6(let addr):
            return Self.encodeIPv6(addr) ?? Data()
        case .tcp(let port), .udp(let port):
            return Self.encodePort(port)
        case .quic, .quicV1, .ws, .wss, .p2pCircuit:
            return Data()
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
        let parts = address.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes = Data()
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    private static func encodeIPv6(_ address: String) -> Data? {
        // Simplified IPv6 encoding
        var bytes = Data(count: 16)

        // Handle :: expansion
        let parts: [String]
        if address.contains("::") {
            let halves = address.split(separator: "::", omittingEmptySubsequences: false)
            let left = halves.first.map { $0.split(separator: ":").map(String.init) } ?? []
            let right = halves.count > 1 ? halves[1].split(separator: ":").map(String.init) : []
            let missing = 8 - left.count - right.count
            parts = left + Array(repeating: "0", count: missing) + right
        } else {
            parts = address.split(separator: ":").map(String.init)
        }

        guard parts.count == 8 else { return nil }

        for (index, part) in parts.enumerated() {
            guard let value = UInt16(part, radix: 16) else { return nil }
            bytes[index * 2] = UInt8(value >> 8)
            bytes[index * 2 + 1] = UInt8(value & 0xFF)
        }

        return bytes
    }

    /// Normalizes an IPv6 address to expanded form (e.g., "::1" → "0:0:0:0:0:0:0:1").
    /// - Parameter address: The IPv6 address string to normalize
    /// - Returns: The normalized IPv6 address, or nil if invalid or too long (>45 chars)
    static func normalizeIPv6(_ address: String) -> String? {
        // Max IPv6 address length is 45 chars (39 expanded + some slack for edge cases)
        guard address.count <= 45 else { return nil }
        guard let bytes = encodeIPv6(address) else { return nil }
        var parts: [String] = []
        for i in 0..<8 {
            let value = UInt16(bytes[i * 2]) << 8 | UInt16(bytes[i * 2 + 1])
            parts.append(String(value, radix: 16))
        }
        return parts.joined(separator: ":")
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
        default:
            throw MultiaddrError.unknownProtocolName(name)
        }
    }
}
