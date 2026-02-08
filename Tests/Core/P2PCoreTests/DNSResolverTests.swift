import Testing
import Foundation
@testable import P2PCore

@Suite("DNSResolver")
struct DNSResolverTests {

    @Test("non-DNS address passes through unchanged")
    func nonDNSPassthrough() async throws {
        let resolver = SystemDNSResolver()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let resolved = try await resolver.resolve(addr)
        #expect(resolved.count == 1)
        #expect(resolved[0] == addr)
    }

    @Test("hasDNSComponent returns false for IP address")
    func noDNS() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        #expect(!addr.hasDNSComponent)
    }

    @Test("hasDNSComponent returns true for dns4")
    func hasDNS4() throws {
        let addr = try Multiaddr("/dns4/localhost/tcp/4001")
        #expect(addr.hasDNSComponent)
    }

    @Test("hasDNSComponent returns true for dns6")
    func hasDNS6() throws {
        let addr = try Multiaddr("/dns6/localhost/tcp/4001")
        #expect(addr.hasDNSComponent)
    }

    @Test("hasDNSComponent returns true for dns")
    func hasDNS() throws {
        let addr = try Multiaddr("/dns/localhost/tcp/4001")
        #expect(addr.hasDNSComponent)
    }

    @Test("hasDNSComponent returns true for dnsaddr")
    func hasDNSAddr() throws {
        let addr = try Multiaddr("/dnsaddr/bootstrap.libp2p.io")
        #expect(addr.hasDNSComponent)
    }

    @Test("hasDNSComponent returns false for quic address")
    func noDNSInQuic() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/udp/4001/quic-v1")
        #expect(!addr.hasDNSComponent)
    }

    @Test("resolve dns4/localhost returns ip4 address", .timeLimit(.minutes(1)))
    func resolveDNS4Localhost() async throws {
        let resolver = SystemDNSResolver()
        let addr = try Multiaddr("/dns4/localhost/tcp/4001")
        let resolved = try await resolver.resolve(addr)
        #expect(!resolved.isEmpty)
        // All resolved addresses should have no DNS components
        for r in resolved {
            #expect(!r.hasDNSComponent)
        }
        // localhost should resolve to 127.0.0.1
        let hasLoopback = resolved.contains { $0.ipAddress == "127.0.0.1" }
        #expect(hasLoopback)
        // Port should be preserved
        for r in resolved {
            #expect(r.tcpPort == 4001)
        }
    }

    @Test("resolve dns6/localhost returns ip6 address", .timeLimit(.minutes(1)))
    func resolveDNS6Localhost() async throws {
        let resolver = SystemDNSResolver()
        let addr = try Multiaddr("/dns6/localhost/tcp/4001")
        let resolved = try await resolver.resolve(addr)
        #expect(!resolved.isEmpty)
        for r in resolved {
            #expect(!r.hasDNSComponent)
            #expect(r.tcpPort == 4001)
        }
    }

    @Test("resolve dns/localhost returns addresses", .timeLimit(.minutes(1)))
    func resolveDNSLocalhost() async throws {
        let resolver = SystemDNSResolver()
        let addr = try Multiaddr("/dns/localhost/tcp/4001")
        let resolved = try await resolver.resolve(addr)
        #expect(!resolved.isEmpty)
        for r in resolved {
            #expect(!r.hasDNSComponent)
            #expect(r.tcpPort == 4001)
        }
    }

    @Test("resolve unknown hostname throws", .timeLimit(.minutes(1)))
    func resolveUnknown() async throws {
        let resolver = SystemDNSResolver()
        let addr = try Multiaddr("/dns4/this.host.does.not.exist.invalid/tcp/4001")
        do {
            _ = try await resolver.resolve(addr)
            Issue.record("Should have thrown")
        } catch {
            #expect(error is DNSResolverError)
        }
    }

    @Test("resolve dnsaddr throws dnsaddrLookupFailed", .timeLimit(.minutes(1)))
    func resolveDNSAddrThrows() async throws {
        let resolver = SystemDNSResolver()
        let addr = try Multiaddr("/dnsaddr/bootstrap.libp2p.io")
        do {
            _ = try await resolver.resolve(addr)
            Issue.record("Should have thrown")
        } catch let error as DNSResolverError {
            if case .dnsaddrLookupFailed(let domain) = error {
                #expect(domain == "bootstrap.libp2p.io")
            } else {
                Issue.record("Expected dnsaddrLookupFailed, got \(error)")
            }
        }
    }

    @Test("maxResults limits resolved addresses", .timeLimit(.minutes(1)))
    func maxResults() async throws {
        let resolver = SystemDNSResolver(maxResults: 1)
        let addr = try Multiaddr("/dns4/localhost/tcp/4001")
        let resolved = try await resolver.resolve(addr)
        #expect(resolved.count <= 1)
    }

    @Test("resolved address preserves non-DNS protocols", .timeLimit(.minutes(1)))
    func preservesOtherProtocols() async throws {
        let resolver = SystemDNSResolver()
        let addr = try Multiaddr("/dns4/localhost/tcp/8080/ws")
        let resolved = try await resolver.resolve(addr)
        #expect(!resolved.isEmpty)
        for r in resolved {
            #expect(r.protocols.count == 3)
            #expect(r.tcpPort == 8080)
            // Verify the ws protocol is preserved
            let hasWS = r.protocols.contains { proto in
                if case .ws = proto { return true }
                return false
            }
            #expect(hasWS)
        }
    }
}
