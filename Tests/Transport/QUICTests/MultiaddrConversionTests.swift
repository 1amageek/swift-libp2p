/// Tests for Multiaddr ↔ SocketAddress conversion.

import Testing
import Foundation
@testable import P2PTransportQUIC
@testable import P2PCore
import QUIC

@Suite("MultiaddrConversion Tests")
struct MultiaddrConversionTests {

    // MARK: - hasQUICProtocol Tests

    @Test("IPv4 QUIC address has QUIC protocol")
    func ipv4QUICAddress() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433/quic-v1")
        #expect(addr.hasQUICProtocol)
    }

    @Test("IPv6 QUIC address has QUIC protocol")
    func ipv6QUICAddress() throws {
        let addr = try Multiaddr("/ip6/::1/udp/4433/quic-v1")
        #expect(addr.hasQUICProtocol)
    }

    @Test("TCP address does not have QUIC protocol")
    func tcpAddress() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4433")
        #expect(!addr.hasQUICProtocol)
    }

    @Test("UDP-only address does not have QUIC protocol")
    func udpOnlyAddress() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433")
        #expect(!addr.hasQUICProtocol)
    }

    // MARK: - toQUICSocketAddress Tests

    @Test("Convert IPv4 QUIC multiaddr to SocketAddress")
    func convertIPv4ToSocketAddress() throws {
        let addr = try Multiaddr("/ip4/192.168.1.100/udp/4433/quic-v1")
        let socketAddr = addr.toQUICSocketAddress()

        #expect(socketAddr != nil)
        #expect(socketAddr?.ipAddress == "192.168.1.100")
        #expect(socketAddr?.port == 4433)
    }

    @Test("Convert IPv6 QUIC multiaddr to SocketAddress")
    func convertIPv6ToSocketAddress() throws {
        let addr = try Multiaddr("/ip6/::1/udp/5555/quic-v1")
        let socketAddr = addr.toQUICSocketAddress()

        #expect(socketAddr != nil)
        // IPv6 may be normalized to expanded form
        #expect(socketAddr?.ipAddress == "::1" || socketAddr?.ipAddress == "0:0:0:0:0:0:0:1")
        #expect(socketAddr?.port == 5555)
    }

    @Test("Non-QUIC address returns nil SocketAddress")
    func nonQUICAddressReturnsNil() throws {
        let tcpAddr = try Multiaddr("/ip4/127.0.0.1/tcp/4433")
        #expect(tcpAddr.toQUICSocketAddress() == nil)

        let udpAddr = try Multiaddr("/ip4/127.0.0.1/udp/4433")
        #expect(udpAddr.toQUICSocketAddress() == nil)
    }

    // MARK: - toQUICMultiaddr Tests

    @Test("Convert IPv4 SocketAddress to QUIC multiaddr")
    func convertIPv4SocketToMultiaddr() throws {
        let socketAddr = SocketAddress(ipAddress: "10.0.0.1", port: 9000)
        let multiaddr = socketAddr.toQUICMultiaddr()

        #expect(multiaddr.hasQUICProtocol)
        #expect(multiaddr.ipAddress == "10.0.0.1")
        #expect(multiaddr.udpPort == 9000)

        let components = multiaddr.protocols
        #expect(components.count >= 3)
        #expect(components[0].name == "ip4")
        #expect(components[1].name == "udp")
        #expect(components[2].name == "quic-v1")
    }

    @Test("Convert IPv6 SocketAddress to QUIC multiaddr")
    func convertIPv6SocketToMultiaddr() throws {
        let socketAddr = SocketAddress(ipAddress: "fe80::1", port: 8080)
        let multiaddr = socketAddr.toQUICMultiaddr()

        #expect(multiaddr.hasQUICProtocol)
        #expect(multiaddr.ipAddress == "fe80::1")
        #expect(multiaddr.udpPort == 8080)

        let components = multiaddr.protocols
        #expect(components.count >= 3)
        #expect(components[0].name == "ip6")
        #expect(components[1].name == "udp")
        #expect(components[2].name == "quic-v1")
    }

    // MARK: - Round-trip Tests

    @Test("IPv4 round-trip conversion preserves address")
    func ipv4RoundTrip() throws {
        let original = try Multiaddr("/ip4/172.16.0.1/udp/12345/quic-v1")
        let socketAddr = original.toQUICSocketAddress()
        #expect(socketAddr != nil)

        let converted = socketAddr!.toQUICMultiaddr()
        #expect(converted.hasQUICProtocol)

        // Verify the converted address matches original
        let reconverted = converted.toQUICSocketAddress()
        #expect(reconverted?.ipAddress == "172.16.0.1")
        #expect(reconverted?.port == 12345)
    }
}
