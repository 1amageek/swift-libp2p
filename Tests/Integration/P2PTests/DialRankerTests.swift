import Testing
import P2PCore
@testable import P2P

@Suite("DialRanker")
struct DialRankerTests {

    @Test("QUIC IPv6 comes first")
    func quicIPv6First() throws {
        let ranker = DefaultDialRanker()
        let addrs = [
            try Multiaddr("/ip4/1.2.3.4/tcp/4001"),
            try Multiaddr("/ip6/::1/udp/4001/quic-v1"),
            try Multiaddr("/ip4/1.2.3.4/udp/4001/quic-v1"),
            try Multiaddr("/ip6/::1/tcp/4001"),
        ]

        let groups = ranker.rankAddresses(addrs)
        #expect(groups.count == 4)
        // First group should be QUIC IPv6
        #expect(groups[0].delay == .zero)
    }

    @Test("empty addresses returns empty groups")
    func emptyAddresses() {
        let ranker = DefaultDialRanker()
        let groups = ranker.rankAddresses([])
        #expect(groups.isEmpty)
    }

    @Test("single address produces single group")
    func singleAddress() throws {
        let ranker = DefaultDialRanker()
        let groups = ranker.rankAddresses([try Multiaddr("/ip4/1.2.3.4/tcp/4001")])
        #expect(groups.count == 1)
        #expect(groups[0].delay == .zero)
    }

    @Test("first group has no delay")
    func firstGroupNoDelay() throws {
        let ranker = DefaultDialRanker()
        let addrs = [
            try Multiaddr("/ip4/1.2.3.4/tcp/4001"),
            try Multiaddr("/ip4/1.2.3.4/udp/4001/quic-v1"),
        ]
        let groups = ranker.rankAddresses(addrs)
        #expect(groups[0].delay == .zero)
    }

    @Test("subsequent groups have delay")
    func subsequentGroupsHaveDelay() throws {
        let ranker = DefaultDialRanker(groupDelay: .milliseconds(250))
        let addrs = [
            try Multiaddr("/ip6/::1/udp/4001/quic-v1"),
            try Multiaddr("/ip4/1.2.3.4/tcp/4001"),
        ]
        let groups = ranker.rankAddresses(addrs)
        #expect(groups.count >= 2)
        #expect(groups[1].delay == .milliseconds(250))
    }

    @Test("all same type in one group")
    func sameTypeOneGroup() throws {
        let ranker = DefaultDialRanker()
        let addrs = [
            try Multiaddr("/ip4/1.2.3.4/tcp/4001"),
            try Multiaddr("/ip4/5.6.7.8/tcp/4001"),
        ]
        let groups = ranker.rankAddresses(addrs)
        #expect(groups.count == 1)
        #expect(groups[0].addresses.count == 2)
    }
}
