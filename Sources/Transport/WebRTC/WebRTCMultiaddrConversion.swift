/// WebRTC Multiaddr Conversion
///
/// NIO SocketAddress <-> UDP/WebRTC Direct Multiaddr conversion.
/// Analogous to TCP's toMultiaddr() in TCPConnection.swift
/// and QUIC's MultiaddrConversion.swift.

import Foundation
import NIOCore
import P2PCore

extension SocketAddress {

    /// Converts this NIO SocketAddress to a UDP Multiaddr.
    ///
    /// - Returns: `/ip4/<host>/udp/<port>` or `/ip6/<host>/udp/<port>`, or nil for unix sockets.
    func toUDPMultiaddr() -> Multiaddr? {
        switch self {
        case .v4(let addr):
            let port = UInt16(self.port ?? 0)
            return Multiaddr(uncheckedProtocols: [.ip4(addr.host), .udp(port)])
        case .v6(let addr):
            let port = UInt16(self.port ?? 0)
            return Multiaddr(uncheckedProtocols: [.ip6(addr.host), .udp(port)])
        case .unixDomainSocket:
            return nil
        }
    }

    /// Converts this NIO SocketAddress to a WebRTC Direct Multiaddr with certhash.
    ///
    /// - Parameter certhash: The multihash-encoded certificate fingerprint.
    /// - Returns: `/ip4/<host>/udp/<port>/webrtc-direct/certhash/<hash>`, or nil for unix sockets.
    func toWebRTCDirectMultiaddr(certhash: Data) -> Multiaddr? {
        switch self {
        case .v4(let addr):
            let port = UInt16(self.port ?? 0)
            return Multiaddr(uncheckedProtocols: [
                .ip4(addr.host), .udp(port), .webrtcDirect, .certhash(certhash)
            ])
        case .v6(let addr):
            let port = UInt16(self.port ?? 0)
            return Multiaddr(uncheckedProtocols: [
                .ip6(addr.host), .udp(port), .webrtcDirect, .certhash(certhash)
            ])
        case .unixDomainSocket:
            return nil
        }
    }

    /// Stable string key for routing table lookup.
    ///
    /// Format: `"192.168.1.1:4001"` (IPv4) or `"[::1]:4001"` (IPv6).
    ///
    /// Uses `ipAddress` (derived from the sockaddr struct) rather than `host`
    /// because `SocketAddress(ipAddress:port:)` sets `host` to empty string
    /// while NIO-received addresses populate it from the kernel.
    var addressKey: String {
        let ip = self.ipAddress ?? ""
        let port = self.port ?? 0
        if ip.contains(":") {
            return "[\(ip)]:\(port)"
        }
        return "\(ip):\(port)"
    }
}
