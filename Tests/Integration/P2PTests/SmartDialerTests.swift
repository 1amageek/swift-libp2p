import Testing
import P2PCore
import Synchronization
@testable import P2P

@Suite("SmartDialer")
struct SmartDialerTests {

    @Test("successful dial returns peer ID and address", .timeLimit(.minutes(1)))
    func successfulDial() async throws {
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let addr = try Multiaddr("/ip4/1.2.3.4/tcp/4001")

        let dialer = SmartDialer(
            dialRanker: DefaultDialRanker(),
            configuration: .init(dialTimeout: .seconds(5))
        )

        let (resultPeer, resultAddr) = try await dialer.dialRanked(
            addresses: [addr],
            dialFn: { _ in peerID }
        )

        #expect(resultPeer == peerID)
        #expect(resultAddr == addr)
    }

    @Test("first successful address wins", .timeLimit(.minutes(1)))
    func firstSuccessWins() async throws {
        let fastPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let slowPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let addr1 = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let addr2 = try Multiaddr("/ip4/5.6.7.8/tcp/4001")

        let dialer = SmartDialer(
            dialRanker: DefaultDialRanker(),
            configuration: .init(dialTimeout: .seconds(5))
        )

        let (resultPeer, _) = try await dialer.dialRanked(
            addresses: [addr1, addr2],
            dialFn: { addr in
                if addr == addr1 {
                    return fastPeer
                }
                try await Task.sleep(for: .seconds(10))
                return slowPeer
            }
        )

        #expect(resultPeer == fastPeer)
    }

    @Test("empty addresses throws noAddresses", .timeLimit(.minutes(1)))
    func emptyAddressesThrows() async throws {
        let dialer = SmartDialer(dialRanker: DefaultDialRanker())

        do {
            _ = try await dialer.dialRanked(
                addresses: [],
                dialFn: { _ in
                    PeerID(publicKey: KeyPair.generateEd25519().publicKey)
                }
            )
            Issue.record("Expected SmartDialerError.noAddresses")
        } catch is SmartDialerError {
            // Expected
        }
    }

    @Test("all dials failing throws allDialsFailed", .timeLimit(.minutes(1)))
    func allDialsFailing() async throws {
        let addr = try Multiaddr("/ip4/1.2.3.4/tcp/4001")

        let dialer = SmartDialer(
            dialRanker: DefaultDialRanker(),
            configuration: .init(dialTimeout: .seconds(5))
        )

        do {
            _ = try await dialer.dialRanked(
                addresses: [addr],
                dialFn: { _ in
                    throw SmartDialerError.allDialsFailed
                }
            )
            Issue.record("Expected error")
        } catch {
            // Expected - allDialsFailed or the wrapped error
        }
    }

    @Test("timeout triggers when all dials are slow", .timeLimit(.minutes(1)))
    func timeoutTriggered() async throws {
        let addr = try Multiaddr("/ip4/1.2.3.4/tcp/4001")

        let dialer = SmartDialer(
            dialRanker: DefaultDialRanker(),
            configuration: .init(dialTimeout: .milliseconds(200))
        )

        do {
            _ = try await dialer.dialRanked(
                addresses: [addr],
                dialFn: { _ in
                    try await Task.sleep(for: .seconds(10))
                    return PeerID(publicKey: KeyPair.generateEd25519().publicKey)
                }
            )
            Issue.record("Expected timeout")
        } catch is SmartDialerError {
            // Expected: timeout
        }
    }

    @Test("relay addresses are tried after direct addresses", .timeLimit(.minutes(1)))
    func relayAfterDirect() async throws {
        let directAddr = try Multiaddr("/ip4/1.2.3.4/udp/4001/quic-v1")
        let relayAddr = try Multiaddr("/ip4/5.6.7.8/tcp/4001/p2p-circuit")
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let dialer = SmartDialer(
            dialRanker: DefaultDialRanker(
                groupDelay: .milliseconds(100),
                relayDelay: .milliseconds(200)
            ),
            configuration: .init(dialTimeout: .seconds(5))
        )

        let orderMutex = Mutex<[Multiaddr]>([])

        let (_, resultAddr) = try await dialer.dialRanked(
            addresses: [relayAddr, directAddr],
            dialFn: { addr in
                orderMutex.withLock { $0.append(addr) }
                return peerID
            }
        )

        let order = orderMutex.withLock { $0 }
        // Direct address should be dialed first (it's in the first group)
        #expect(order.first == directAddr)
        #expect(resultAddr == directAddr)
    }
}
