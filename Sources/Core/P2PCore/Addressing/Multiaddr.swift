/// Multiaddr - Self-describing network addresses.
/// https://github.com/multiformats/multiaddr

import Foundation

/// Maximum size for Multiaddr input (bytes or string length).
/// This prevents memory exhaustion from maliciously large inputs.
public let multiaddrMaxInputSize = 1024

/// Maximum number of protocol components in a Multiaddr.
/// Typical addresses have 2-5 components (e.g., /ip4/.../tcp/.../p2p/...).
public let multiaddrMaxComponents = 20

/// A self-describing network address.
///
/// Multiaddrs are composable addresses that describe a network path.
/// For example: `/ip4/192.168.1.1/tcp/4001/p2p/QmPeerID`
public struct Multiaddr: Sendable, Hashable, CustomStringConvertible {

    /// The protocol components of this address.
    public let protocols: [MultiaddrProtocol]

    /// Creates a Multiaddr from protocol components.
    ///
    /// - Parameter protocols: The protocol components
    /// - Throws: `MultiaddrError.tooManyComponents` if components exceed limit
    /// - Throws: `MultiaddrError.invalidAddress` when IP protocol values are invalid
    public init(protocols: [MultiaddrProtocol]) throws {
        guard protocols.count <= multiaddrMaxComponents else {
            throw MultiaddrError.tooManyComponents(count: protocols.count, max: multiaddrMaxComponents)
        }

        for proto in protocols {
            switch proto {
            case .ip4(let address):
                guard MultiaddrProtocol.isValidIPv4(address) else {
                    throw MultiaddrError.invalidAddress
                }
            case .ip6zone(let zone):
                guard MultiaddrProtocol.isValidZoneID(zone) else {
                    throw MultiaddrError.invalidAddress
                }
            case .ip6(let address):
                guard MultiaddrProtocol.isValidIPv6(address) else {
                    throw MultiaddrError.invalidAddress
                }
            default:
                continue
            }
        }

        self.protocols = protocols
    }

    /// Creates a Multiaddr from protocol components without validation.
    ///
    /// Use this initializer only when you are certain the protocols array
    /// has fewer than `multiaddrMaxComponents` elements. This is intended for:
    /// - Factory methods that create known-small addresses
    /// - Internal composition methods
    ///
    /// - Parameter uncheckedProtocols: Protocol components (must be <= 20)
    /// - Warning: No validation is performed. Use `init(protocols:)` for untrusted input.
    public init(uncheckedProtocols: [MultiaddrProtocol]) {
        self.protocols = uncheckedProtocols
    }

    /// Creates a Multiaddr from its string representation.
    ///
    /// - Parameter string: The string representation (e.g., "/ip4/127.0.0.1/tcp/4001")
    /// - Throws: `MultiaddrError` if the string is invalid
    public init(_ string: String) throws {
        // Check input size to prevent DoS
        guard string.utf8.count <= multiaddrMaxInputSize else {
            throw MultiaddrError.inputTooLarge(size: string.utf8.count, max: multiaddrMaxInputSize)
        }

        guard string.hasPrefix("/") else {
            throw MultiaddrError.invalidFormat
        }

        var protocols: [MultiaddrProtocol] = []
        let parts = string.dropFirst().split(separator: "/", omittingEmptySubsequences: false)

        var index = 0
        while index < parts.count {
            // Check component count to prevent DoS
            guard protocols.count < multiaddrMaxComponents else {
                throw MultiaddrError.tooManyComponents(count: protocols.count + 1, max: multiaddrMaxComponents)
            }

            let name = String(parts[index])
            guard let requiresValue = MultiaddrProtocol.requiresValue(name: name) else {
                throw MultiaddrError.unknownProtocolName(name)
            }

            let value: String?
            if requiresValue {
                guard index + 1 < parts.count else {
                    throw MultiaddrError.missingValue
                }
                value = String(parts[index + 1])
                index += 1
            } else {
                value = nil
            }

            let proto = try MultiaddrProtocol.parse(name: name, value: value)
            protocols.append(proto)
            index += 1
        }

        self.protocols = protocols
    }

    /// Creates a Multiaddr from its binary representation.
    ///
    /// - Parameter bytes: The binary representation
    /// - Throws: `MultiaddrError` if the bytes are invalid
    public init(bytes: Data) throws {
        // Check input size to prevent DoS
        guard bytes.count <= multiaddrMaxInputSize else {
            throw MultiaddrError.inputTooLarge(size: bytes.count, max: multiaddrMaxInputSize)
        }

        var protocols: [MultiaddrProtocol] = []
        var remaining = bytes

        while !remaining.isEmpty {
            // Check component count to prevent DoS
            guard protocols.count < multiaddrMaxComponents else {
                throw MultiaddrError.tooManyComponents(count: protocols.count + 1, max: multiaddrMaxComponents)
            }

            let (code, codeBytes) = try Varint.decode(remaining)
            remaining = remaining.dropFirst(codeBytes)

            let (proto, valueBytes) = try MultiaddrProtocol.decode(code: code, from: Data(remaining))
            protocols.append(proto)
            remaining = remaining.dropFirst(valueBytes)
        }

        self.protocols = protocols
    }

    /// The binary representation of this address.
    public var bytes: Data {
        // Pre-allocate capacity: each protocol typically uses 3-20 bytes
        var result = Data(capacity: protocols.count * 12)
        for proto in protocols {
            result.append(contentsOf: proto.bytes)
        }
        return result
    }

    /// The string representation of this address.
    public var description: String {
        "/" + protocols.map { proto in
            if let value = proto.valueString {
                return "\(proto.name)/\(value)"
            } else {
                return proto.name
            }
        }.joined(separator: "/")
    }

    // MARK: - Protocol Access

    /// Returns the first protocol matching the given code.
    public func first(code: UInt64) -> MultiaddrProtocol? {
        protocols.first { $0.code == code }
    }

    /// Returns all protocols matching the given code.
    public func filter(code: UInt64) -> [MultiaddrProtocol] {
        protocols.filter { $0.code == code }
    }

    /// Whether this multiaddr contains a p2p (PeerID) component.
    public var hasPeerID: Bool {
        peerID != nil
    }

    /// The PeerID component, if present.
    public var peerID: PeerID? {
        for proto in protocols {
            if case .p2p(let peerID) = proto {
                return peerID
            }
        }
        return nil
    }

    /// The TCP port, if present.
    public var tcpPort: UInt16? {
        for proto in protocols {
            if case .tcp(let port) = proto {
                return port
            }
        }
        return nil
    }

    /// The UDP port, if present.
    public var udpPort: UInt16? {
        for proto in protocols {
            if case .udp(let port) = proto {
                return port
            }
        }
        return nil
    }

    /// The IP address (v4 or v6), if present.
    public var ipAddress: String? {
        for proto in protocols {
            switch proto {
            case .ip4(let addr), .ip6(let addr):
                return addr
            default:
                continue
            }
        }
        return nil
    }

    /// Whether this address contains any DNS components that need resolution.
    public var hasDNSComponent: Bool {
        protocols.contains { proto in
            switch proto {
            case .dns4, .dns6, .dns, .dnsaddr:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Composition

    /// Creates a new Multiaddr by appending the given protocol.
    ///
    /// - Throws: `MultiaddrError.tooManyComponents` if the result exceeds the component limit
    public func appending(_ proto: MultiaddrProtocol) throws -> Multiaddr {
        let newProtocols = protocols + [proto]
        return try Multiaddr(protocols: newProtocols)
    }

    /// Creates a new Multiaddr by appending the given Multiaddr.
    ///
    /// - Throws: `MultiaddrError.tooManyComponents` if the result exceeds the component limit
    public func appending(_ other: Multiaddr) throws -> Multiaddr {
        let newProtocols = protocols + other.protocols
        return try Multiaddr(protocols: newProtocols)
    }

    /// Creates a new Multiaddr by encapsulating with the given protocol.
    ///
    /// - Throws: `MultiaddrError.tooManyComponents` if the result exceeds the component limit
    public func encapsulate(_ proto: MultiaddrProtocol) throws -> Multiaddr {
        try appending(proto)
    }

    /// Creates a new Multiaddr by removing protocols after and including the given code.
    public func decapsulate(code: UInt64) -> Multiaddr {
        if let index = protocols.lastIndex(where: { $0.code == code }) {
            return Multiaddr(uncheckedProtocols: Array(protocols.prefix(upTo: index)))
        }
        return self
    }

}

public enum MultiaddrError: Error, Equatable {
    case invalidFormat
    case invalidAddress
    case unknownProtocol(UInt64)
    case unknownProtocolName(String)
    case missingValue
    case fieldTooLarge
    case inputTooLarge(size: Int, max: Int)
    case tooManyComponents(count: Int, max: Int)
}

// MARK: - Codable

extension Multiaddr: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        try self.init(string)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Common Addresses

extension Multiaddr {

    /// Creates a TCP address.
    ///
    /// - Note: Factory methods don't validate size since they create known-small addresses.
    /// - Note: IPv6 addresses are normalized to expanded form.
    public static func tcp(host: String, port: UInt16) -> Multiaddr {
        if host.contains(":") {
            let normalized = MultiaddrProtocol.normalizeIPv6(host) ?? host
            return Multiaddr(uncheckedProtocols: [.ip6(normalized), .tcp(port)])
        } else {
            return Multiaddr(uncheckedProtocols: [.ip4(host), .tcp(port)])
        }
    }

    /// Creates a QUIC address.
    ///
    /// - Note: Factory methods don't validate size since they create known-small addresses.
    /// - Note: IPv6 addresses are normalized to expanded form.
    public static func quic(host: String, port: UInt16) -> Multiaddr {
        if host.contains(":") {
            let normalized = MultiaddrProtocol.normalizeIPv6(host) ?? host
            return Multiaddr(uncheckedProtocols: [.ip6(normalized), .udp(port), .quicV1])
        } else {
            return Multiaddr(uncheckedProtocols: [.ip4(host), .udp(port), .quicV1])
        }
    }

    /// Creates a memory transport address.
    ///
    /// - Parameter id: The identifier for the memory endpoint
    /// - Returns: A Multiaddr of the form `/memory/<id>`
    /// - Note: Factory methods don't validate size since they create known-small addresses.
    public static func memory(id: String) -> Multiaddr {
        Multiaddr(uncheckedProtocols: [.memory(id)])
    }

    /// Creates a WebSocket address.
    ///
    /// - Note: Factory methods don't validate size since they create known-small addresses.
    /// - Note: IPv6 addresses are normalized to expanded form.
    public static func ws(host: String, port: UInt16) -> Multiaddr {
        if host.contains(":") {
            let normalized = MultiaddrProtocol.normalizeIPv6(host) ?? host
            return Multiaddr(uncheckedProtocols: [.ip6(normalized), .tcp(port), .ws])
        } else {
            return Multiaddr(uncheckedProtocols: [.ip4(host), .tcp(port), .ws])
        }
    }

    /// Creates a WebSocket Secure address.
    ///
    /// - Note: Factory methods don't validate size since they create known-small addresses.
    /// - Note: IPv6 addresses are normalized to expanded form.
    public static func wss(host: String, port: UInt16) -> Multiaddr {
        if host.contains(":") {
            let normalized = MultiaddrProtocol.normalizeIPv6(host) ?? host
            return Multiaddr(uncheckedProtocols: [.ip6(normalized), .tcp(port), .wss])
        } else {
            return Multiaddr(uncheckedProtocols: [.ip4(host), .tcp(port), .wss])
        }
    }

    /// Creates a WebTransport address.
    ///
    /// - Parameters:
    ///   - host: The IP address
    ///   - port: The UDP port
    ///   - certhashes: Optional certificate hashes (multihash-encoded)
    /// - Returns: A Multiaddr of the form `/ip4/<host>/udp/<port>/quic-v1/webtransport[/certhash/<hash>...]`
    /// - Note: Factory methods don't validate size since they create known-small addresses.
    /// - Note: IPv6 addresses are normalized to expanded form.
    public static func webtransport(host: String, port: UInt16, certhashes: [Data] = []) -> Multiaddr {
        var protos: [MultiaddrProtocol]
        if host.contains(":") {
            let normalized = MultiaddrProtocol.normalizeIPv6(host) ?? host
            protos = [.ip6(normalized), .udp(port), .quicV1, .webtransport]
        } else {
            protos = [.ip4(host), .udp(port), .quicV1, .webtransport]
        }
        for hash in certhashes {
            protos.append(.certhash(hash))
        }
        return Multiaddr(uncheckedProtocols: protos)
    }

    /// Creates a WebRTC Direct address.
    ///
    /// - Parameters:
    ///   - host: The IP address
    ///   - port: The UDP port
    ///   - certhash: The certificate hash (multihash-encoded)
    /// - Returns: A Multiaddr of the form `/ip4/<host>/udp/<port>/webrtc-direct/certhash/<hash>`
    public static func webrtcDirect(host: String, port: UInt16, certhash: Data) -> Multiaddr {
        if host.contains(":") {
            let normalized = MultiaddrProtocol.normalizeIPv6(host) ?? host
            return Multiaddr(uncheckedProtocols: [.ip6(normalized), .udp(port), .webrtcDirect, .certhash(certhash)])
        } else {
            return Multiaddr(uncheckedProtocols: [.ip4(host), .udp(port), .webrtcDirect, .certhash(certhash)])
        }
    }

    /// The memory identifier, if present.
    public var memoryID: String? {
        for proto in protocols {
            if case .memory(let id) = proto {
                return id
            }
        }
        return nil
    }

    // MARK: - Socket Address Conversion

    /// The socket address string representation (e.g., "192.168.1.1:4001").
    ///
    /// Returns the IP address and port as a standard socket address string.
    /// IPv6 addresses are wrapped in brackets per RFC 2732.
    ///
    /// - Returns: Socket address string, or `nil` if no IP/port combination exists
    ///
    /// ## Examples
    /// ```swift
    /// let addr: Multiaddr = "/ip4/192.168.1.1/tcp/4001"
    /// addr.socketAddressString  // "192.168.1.1:4001"
    ///
    /// let addr6: Multiaddr = "/ip6/::1/udp/5353"
    /// addr6.socketAddressString  // "[::1]:5353"
    /// ```
    public var socketAddressString: String? {
        guard let host = ipAddress else { return nil }
        guard let port = tcpPort ?? udpPort else { return nil }

        if host.contains(":") {
            return "[\(host)]:\(port)"
        } else {
            return "\(host):\(port)"
        }
    }
}

// MARK: - Failable Initializers

extension Multiaddr {

    /// Creates a Multiaddr from a socket address string.
    ///
    /// - Parameters:
    ///   - socketAddress: Address in "host:port" format (e.g., "192.168.1.1:4001" or "[::1]:4001")
    ///   - transport: Transport protocol, defaults to `.tcp`
    ///
    /// ## Examples
    /// ```swift
    /// let addr = Multiaddr(socketAddress: "192.168.1.1:4001")
    /// // → /ip4/192.168.1.1/tcp/4001
    ///
    /// let addr6 = Multiaddr(socketAddress: "[::1]:5353", transport: .udp)
    /// // → /ip6/0:0:0:0:0:0:0:1/udp/5353 (IPv6 is normalized)
    /// ```
    public init?(socketAddress: String, transport: Transport = .tcp) {
        // Size limit check for DoS protection
        guard socketAddress.utf8.count <= multiaddrMaxInputSize else {
            return nil
        }

        guard let (host, port, isIPv6) = Self.parseSocketAddress(socketAddress) else {
            return nil
        }

        let ipProtocol: MultiaddrProtocol
        if isIPv6 {
            // Apply IPv6 normalization (includes length validation)
            guard let normalized = MultiaddrProtocol.normalizeIPv6(host) else {
                return nil
            }
            ipProtocol = .ip6(normalized)
        } else {
            ipProtocol = .ip4(host)
        }

        let transportProtocol: MultiaddrProtocol = transport == .tcp ? .tcp(port) : .udp(port)
        // Use unchecked since socket addresses are always small (2 components)
        self.init(uncheckedProtocols: [ipProtocol, transportProtocol])
    }

    /// Transport layer protocol.
    public enum Transport {
        case tcp
        case udp
    }

    private static func parseSocketAddress(_ address: String) -> (host: String, port: UInt16, isIPv6: Bool)? {
        // IPv6 with brackets: [::1]:4001
        if address.hasPrefix("[") {
            guard let closeBracket = address.firstIndex(of: "]") else {
                return nil
            }
            let host = String(address[address.index(after: address.startIndex)..<closeBracket])
            let remaining = address[address.index(after: closeBracket)...]
            guard remaining.hasPrefix(":"),
                  let port = UInt16(remaining.dropFirst()) else {
                return nil
            }
            return (host, port, true)
        }

        // IPv4 or IPv6 without brackets
        guard let lastColon = address.lastIndex(of: ":") else {
            return nil
        }

        let host = String(address[..<lastColon])
        guard let port = UInt16(address[address.index(after: lastColon)...]) else {
            return nil
        }

        let isIPv6 = host.contains(":")
        return (host, port, isIPv6)
    }
}
