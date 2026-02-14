import Foundation
import Crypto
import P2PCore
import QUIC

public enum WebTransportHost: Sendable, Equatable {
    case ip4(String)
    case ip6(String)
    case dns(String)
    case dns4(String)
    case dns6(String)

    var value: String {
        switch self {
        case .ip4(let host), .ip6(let host), .dns(let host), .dns4(let host), .dns6(let host):
            return host
        }
    }

    var isIPv6: Bool {
        if case .ip6 = self {
            return true
        }
        return false
    }

    var isDNS: Bool {
        switch self {
        case .dns, .dns4, .dns6:
            return true
        default:
            return false
        }
    }

    var protocolValue: MultiaddrProtocol {
        switch self {
        case .ip4(let host):
            return .ip4(host)
        case .ip6(let host):
            return .ip6(host)
        case .dns(let host):
            return .dns(host)
        case .dns4(let host):
            return .dns4(host)
        case .dns6(let host):
            return .dns6(host)
        }
    }
}

/// Parsed WebTransport address components with strict transport-level validation.
public struct WebTransportAddressComponents: Sendable {
    public let host: WebTransportHost
    public let port: UInt16
    public let certificateHashes: [Data]
    public let peerID: PeerID?

    public var hostValue: String {
        host.value
    }

    public var isIPv6: Bool {
        host.isIPv6
    }

    public var socketAddress: QUIC.SocketAddress {
        QUIC.SocketAddress(ipAddress: hostValue, port: port)
    }

    public func toMultiaddr(certificateHashes: [Data]? = nil) -> Multiaddr {
        let hashes = certificateHashes ?? self.certificateHashes
        var protocols: [MultiaddrProtocol] = [host.protocolValue, .udp(port), .quicV1, .webtransport]
        for hash in hashes {
            protocols.append(.certhash(hash))
        }
        if let peerID {
            protocols.append(.p2p(peerID))
        }
        return Multiaddr(uncheckedProtocols: protocols)
    }
}

public enum WebTransportAddressError: Error, Sendable {
    case invalidFormat
    case invalidProtocolOrder
    case unsupportedProtocol(String)
    case duplicateCertificateHash
    case missingCertificateHash
    case invalidCertificateHash
}

/// Strict parser for WebTransport multiaddrs.
///
/// Supported shape:
/// `/ip4|ip6|dns|dns4|dns6/<host>/udp/<port>/quic-v1/webtransport[/certhash/<hash>...][/p2p/<peer>]`
public enum WebTransportAddressParser {

    public static func parse(
        _ address: Multiaddr,
        requireCertificateHash: Bool
    ) throws -> WebTransportAddressComponents {
        let protocols = address.protocols
        guard protocols.count >= 4 else {
            throw WebTransportAddressError.invalidFormat
        }

        let host: WebTransportHost
        switch protocols[0] {
        case .ip4(let ip):
            host = .ip4(ip)
        case .ip6(let ip):
            host = .ip6(ip)
        case .dns(let domain):
            host = .dns(domain)
        case .dns4(let domain):
            host = .dns4(domain)
        case .dns6(let domain):
            host = .dns6(domain)
        default:
            throw WebTransportAddressError.invalidProtocolOrder
        }

        guard case .udp(let port) = protocols[1] else {
            throw WebTransportAddressError.invalidProtocolOrder
        }

        guard case .quicV1 = protocols[2] else {
            throw WebTransportAddressError.invalidProtocolOrder
        }

        guard case .webtransport = protocols[3] else {
            throw WebTransportAddressError.invalidProtocolOrder
        }

        var certificateHashes: [Data] = []
        var peerID: PeerID?
        var seen = Set<Data>()

        var index = 4
        while index < protocols.count {
            switch protocols[index] {
            case .certhash(let rawHash):
                let normalized = try WebTransportCertificateHash.validateMultihashSHA256(rawHash)
                guard seen.insert(normalized).inserted else {
                    throw WebTransportAddressError.duplicateCertificateHash
                }
                certificateHashes.append(normalized)

            case .p2p(let id):
                guard peerID == nil else {
                    throw WebTransportAddressError.invalidFormat
                }
                guard index == protocols.count - 1 else {
                    throw WebTransportAddressError.invalidProtocolOrder
                }
                peerID = id

            default:
                throw WebTransportAddressError.invalidProtocolOrder
            }
            index += 1
        }

        if requireCertificateHash && certificateHashes.isEmpty {
            throw WebTransportAddressError.missingCertificateHash
        }

        return WebTransportAddressComponents(
            host: host,
            port: port,
            certificateHashes: certificateHashes,
            peerID: peerID
        )
    }
}

/// Utilities for WebTransport `/certhash` handling.
public enum WebTransportCertificateHash {

    /// Multihash prefix for SHA-256 digest (code 0x12, length 0x20).
    private static let sha256Prefix = Data([0x12, 0x20])

    /// Computes `/certhash` value (multihash) from certificate DER bytes.
    public static func multihashSHA256(for certificateDER: Data) -> Data {
        let digest = Data(SHA256.hash(data: certificateDER))
        return sha256Prefix + digest
    }

    /// Validates and normalizes a `/certhash` multihash value.
    ///
    /// Current implementation requires SHA-256 multihash (34 bytes).
    public static func validateMultihashSHA256(_ hash: Data) throws -> Data {
        guard hash.count == 34 else {
            throw WebTransportAddressError.invalidCertificateHash
        }
        guard hash.prefix(2) == sha256Prefix else {
            throw WebTransportAddressError.invalidCertificateHash
        }
        return hash
    }

    /// Verifies a leaf certificate DER against expected `/certhash` values.
    public static func matchesAny(
        certificateDER: Data,
        expectedHashes: [Data]
    ) -> Bool {
        let actual = multihashSHA256(for: certificateDER)
        return expectedHashes.contains(actual)
    }
}
