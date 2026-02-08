/// ObservedAddressManagerTests - Tests for observed address tracking

import Testing
import P2PCore
@testable import P2P

@Suite("ObservedAddressManager")
struct ObservedAddressManagerTests {

    private func makePeerID() -> PeerID {
        PeerID(publicKey: KeyPair.generateEd25519().publicKey)
    }

    @Test("no confirmed addresses without observations")
    func noObservations() {
        let mgr = ObservedAddressManager()
        #expect(mgr.confirmedAddresses().isEmpty)
    }

    @Test("single observation not confirmed")
    func singleNotConfirmed() throws {
        let mgr = ObservedAddressManager(confirmationThreshold: 4)
        let observed = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")

        mgr.recordObservation(observed: observed, by: makePeerID(), localAddr: local)
        #expect(mgr.confirmedAddresses().isEmpty)
    }

    @Test("4 distinct observers confirms address")
    func fourObserversConfirm() throws {
        let mgr = ObservedAddressManager(confirmationThreshold: 4)
        let observed = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")

        for _ in 0..<4 {
            mgr.recordObservation(observed: observed, by: makePeerID(), localAddr: local)
        }

        let confirmed = mgr.confirmedAddresses()
        #expect(confirmed.count == 1)
        #expect(confirmed.first == observed)
    }

    @Test("same observer counted once")
    func sameObserverOnce() throws {
        let mgr = ObservedAddressManager(confirmationThreshold: 4)
        let observed = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")
        let observer = makePeerID()

        for _ in 0..<10 {
            mgr.recordObservation(observed: observed, by: observer, localAddr: local)
        }

        // Only 1 distinct observer, threshold is 4
        #expect(mgr.confirmedAddresses().isEmpty)
    }

    @Test("allObservedAddresses returns counts")
    func allObservedAddresses() throws {
        let mgr = ObservedAddressManager()
        let addr1 = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let addr2 = try Multiaddr("/ip4/5.6.7.8/tcp/4001")
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")

        mgr.recordObservation(observed: addr1, by: makePeerID(), localAddr: local)
        mgr.recordObservation(observed: addr1, by: makePeerID(), localAddr: local)
        mgr.recordObservation(observed: addr2, by: makePeerID(), localAddr: local)

        let all = mgr.allObservedAddresses()
        #expect(all.count == 2)
        let addr1Entry = all.first { $0.address == addr1 }
        #expect(addr1Entry?.count == 2)
    }

    @Test("reset clears all observations")
    func resetClears() throws {
        let mgr = ObservedAddressManager()
        let observed = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")

        mgr.recordObservation(observed: observed, by: makePeerID(), localAddr: local)
        mgr.reset()
        #expect(mgr.allObservedAddresses().isEmpty)
    }

    @Test("thin waist grouping works across different ports")
    func thinWaistGrouping() throws {
        let mgr = ObservedAddressManager(confirmationThreshold: 2)
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")

        // Same IP, different ports -> same thin-waist group
        let addr1 = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let addr2 = try Multiaddr("/ip4/1.2.3.4/tcp/5001")

        mgr.recordObservation(observed: addr1, by: makePeerID(), localAddr: local)
        mgr.recordObservation(observed: addr2, by: makePeerID(), localAddr: local)

        let confirmed = mgr.confirmedAddresses()
        #expect(confirmed.count == 1)
    }

    @Test("different IPs are separate groups")
    func differentIPsSeparateGroups() throws {
        let mgr = ObservedAddressManager(confirmationThreshold: 2)
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")

        let addr1 = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let addr2 = try Multiaddr("/ip4/5.6.7.8/tcp/4001")

        mgr.recordObservation(observed: addr1, by: makePeerID(), localAddr: local)
        mgr.recordObservation(observed: addr2, by: makePeerID(), localAddr: local)

        // Each address has only 1 observer, threshold is 2
        #expect(mgr.confirmedAddresses().isEmpty)
    }

    @Test("most common address wins within a thin-waist group")
    func mostCommonAddressWins() throws {
        let mgr = ObservedAddressManager(confirmationThreshold: 3)
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")

        let addrPort4001 = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let addrPort5001 = try Multiaddr("/ip4/1.2.3.4/tcp/5001")

        // 2 observers report port 4001
        mgr.recordObservation(observed: addrPort4001, by: makePeerID(), localAddr: local)
        mgr.recordObservation(observed: addrPort4001, by: makePeerID(), localAddr: local)
        // 1 observer reports port 5001
        mgr.recordObservation(observed: addrPort5001, by: makePeerID(), localAddr: local)

        let confirmed = mgr.confirmedAddresses()
        #expect(confirmed.count == 1)
        #expect(confirmed.first == addrPort4001)
    }

    @Test("concurrent recording is safe", .timeLimit(.minutes(1)))
    func concurrentSafety() async throws {
        let mgr = ObservedAddressManager(confirmationThreshold: 4)
        let observed = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let local = try Multiaddr("/ip4/0.0.0.0/tcp/4001")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
                    mgr.recordObservation(observed: observed, by: peer, localAddr: local)
                }
            }
        }

        let confirmed = mgr.confirmedAddresses()
        #expect(!confirmed.isEmpty)
    }

    @Test("observer with different local addresses counted separately")
    func observerDifferentLocalAddresses() throws {
        let mgr = ObservedAddressManager(confirmationThreshold: 2)
        let observed = try Multiaddr("/ip4/1.2.3.4/tcp/4001")
        let local1 = try Multiaddr("/ip4/0.0.0.0/tcp/4001")
        let local2 = try Multiaddr("/ip4/0.0.0.0/tcp/5001")
        let observer = makePeerID()

        // Same observer, but different local addresses -> both kept
        mgr.recordObservation(observed: observed, by: observer, localAddr: local1)
        mgr.recordObservation(observed: observed, by: observer, localAddr: local2)

        // Still only 1 distinct observer for confirmation purposes
        #expect(mgr.confirmedAddresses().isEmpty)

        // But allObservedAddresses should show count 1 (same observer for same address)
        let all = mgr.allObservedAddresses()
        #expect(all.count == 1)
        #expect(all.first?.count == 1)
    }
}
