/// MultiaddrClassificationTests - Address classification helpers used by
/// discovery hint filtering and connection gating.

import Testing
import Foundation
@testable import P2PCore

@Suite("Multiaddr Classification")
struct MultiaddrClassificationTests {

    @Test("Loopback IPs are classified")
    func loopbackClassification() throws {
        #expect(try Multiaddr("/ip4/127.0.0.1/tcp/1").isLoopbackIP)
        #expect(try Multiaddr("/ip4/127.5.6.7/tcp/1").isLoopbackIP)
        #expect(try Multiaddr("/ip6/::1/tcp/1").isLoopbackIP)
        #expect(try !Multiaddr("/ip4/8.8.8.8/tcp/1").isLoopbackIP)
    }

    @Test("Link-local IPs are classified")
    func linkLocalClassification() throws {
        #expect(try Multiaddr("/ip4/169.254.1.1/tcp/1").isLinkLocalIP)
        #expect(try Multiaddr("/ip6/fe80::1/tcp/1").isLinkLocalIP)
        #expect(try !Multiaddr("/ip4/10.0.0.1/tcp/1").isLinkLocalIP)
    }

    @Test("Private IPs are classified")
    func privateClassification() throws {
        #expect(try Multiaddr("/ip4/10.0.0.1/tcp/1").isPrivateIP)
        #expect(try Multiaddr("/ip4/192.168.1.1/tcp/1").isPrivateIP)
        #expect(try Multiaddr("/ip4/172.16.0.1/tcp/1").isPrivateIP)
        #expect(try Multiaddr("/ip4/172.31.255.255/tcp/1").isPrivateIP)
        #expect(try !Multiaddr("/ip4/172.32.0.1/tcp/1").isPrivateIP)
        #expect(try !Multiaddr("/ip4/8.8.8.8/tcp/1").isPrivateIP)
    }

    @Test("Globally dialable hint excludes loopback / link-local / unspecified")
    func globallyDialableHint() throws {
        // Routable, non-private public address — dialable.
        #expect(try Multiaddr("/ip4/93.184.216.34/tcp/1").isGloballyDialableHint)
        // Private LAN address — still dialable on a LAN.
        #expect(try Multiaddr("/ip4/192.168.1.10/tcp/1").isGloballyDialableHint)
        // Loopback / link-local / unspecified — NOT auto-dial targets.
        #expect(try !Multiaddr("/ip4/127.0.0.1/tcp/1").isGloballyDialableHint)
        #expect(try !Multiaddr("/ip6/fe80::1/tcp/1").isGloballyDialableHint)
        #expect(try !Multiaddr("/ip4/0.0.0.0/tcp/1").isGloballyDialableHint)
    }
}
