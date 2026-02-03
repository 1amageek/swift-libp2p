/// Multiaddr <-> SocketAddress conversion for QUIC transport.

import Foundation
import P2PCore
import QUIC

// MARK: - Multiaddr Extensions for QUIC

extension Multiaddr {

    /// Whether this address contains a QUIC protocol.
    public var hasQUICProtocol: Bool {
        protocols.contains { proto in
            switch proto {
            case .quic, .quicV1:
                return true
            default:
                return false
            }
        }
    }

    /// Converts this Multiaddr to a QUIC SocketAddress.
    ///
    /// The address must contain:
    /// - An IP protocol (ip4 or ip6)
    /// - A UDP port
    /// - A QUIC protocol (quic or quic-v1)
    ///
    /// - Returns: The SocketAddress, or nil if conversion is not possible.
    public func toQUICSocketAddress() -> QUIC.SocketAddress? {
        guard let ip = ipAddress,
              let port = udpPort,
              hasQUICProtocol else {
            return nil
        }
        return QUIC.SocketAddress(ipAddress: ip, port: port)
    }
}

// MARK: - SocketAddress Extensions

extension QUIC.SocketAddress {

    /// Converts this SocketAddress to a QUIC Multiaddr.
    ///
    /// The resulting address will be in the format:
    /// `/ip4/<ip>/udp/<port>/quic-v1` or `/ip6/<ip>/udp/<port>/quic-v1`
    ///
    /// - Returns: The Multiaddr representation.
    public func toQUICMultiaddr() -> Multiaddr {
        let ipProtocol: MultiaddrProtocol = ipAddress.contains(":")
            ? .ip6(ipAddress)
            : .ip4(ipAddress)
        return Multiaddr(uncheckedProtocols: [ipProtocol, .udp(port), .quicV1])
    }
}
