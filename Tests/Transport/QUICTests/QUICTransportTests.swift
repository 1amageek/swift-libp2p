/// Tests for QUICTransport.

import Testing
import Foundation
@testable import P2PTransportQUIC
@testable import P2PCore

@Suite("QUICTransport Tests")
struct QUICTransportTests {

    // MARK: - Protocol Support Tests

    @Test("Supported protocols include QUIC over IPv4")
    func supportsIPv4QUIC() {
        let transport = QUICTransport()
        let protocols = transport.protocols

        #expect(protocols.contains(["ip4", "udp", "quic-v1"]))
    }

    @Test("Supported protocols include QUIC over IPv6")
    func supportsIPv6QUIC() {
        let transport = QUICTransport()
        let protocols = transport.protocols

        #expect(protocols.contains(["ip6", "udp", "quic-v1"]))
    }

    // MARK: - canDial Tests

    @Test("Can dial IPv4 QUIC address")
    func canDialIPv4QUIC() throws {
        let transport = QUICTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433/quic-v1")

        #expect(transport.canDial(addr))
    }

    @Test("Can dial IPv6 QUIC address")
    func canDialIPv6QUIC() throws {
        let transport = QUICTransport()
        let addr = try Multiaddr("/ip6/::1/udp/4433/quic-v1")

        #expect(transport.canDial(addr))
    }

    @Test("Cannot dial TCP address")
    func cannotDialTCP() throws {
        let transport = QUICTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4433")

        #expect(!transport.canDial(addr))
    }

    @Test("Cannot dial UDP-only address")
    func cannotDialUDPOnly() throws {
        let transport = QUICTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433")

        #expect(!transport.canDial(addr))
    }

    // MARK: - canListen Tests

    @Test("Can listen on IPv4 QUIC address")
    func canListenIPv4QUIC() throws {
        let transport = QUICTransport()
        let addr = try Multiaddr("/ip4/0.0.0.0/udp/4433/quic-v1")

        #expect(transport.canListen(addr))
    }

    @Test("Can listen on IPv6 QUIC address")
    func canListenIPv6QUIC() throws {
        let transport = QUICTransport()
        let addr = try Multiaddr("/ip6/::/udp/4433/quic-v1")

        #expect(transport.canListen(addr))
    }

    // MARK: - dial() Tests

    @Test("dial() throws unsupportedAddress for compatibility")
    func dialThrowsForCompatibility() async throws {
        let transport = QUICTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433/quic-v1")

        // Standard dial() should throw because QUIC doesn't fit RawConnection model
        await #expect(throws: (any Error).self) {
            _ = try await transport.dial(addr)
        }
    }
}
