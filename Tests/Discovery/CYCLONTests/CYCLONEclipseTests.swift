/// CYCLONEclipseTests - Age-poisoning / eclipse resistance for the partial view.
import Testing
import P2PCore
@testable import P2PDiscoveryCYCLON

@Suite("CYCLON Eclipse Resistance")
struct CYCLONEclipseTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeEntry(age: UInt64 = 0) -> CYCLONEntry {
        CYCLONEntry(peerID: makePeerID(), addresses: [], age: age)
    }

    @Test("attacker forged age cannot evict non-sent legitimate peers")
    func ageCannotEclipse() {
        let selfID = makePeerID()
        let view = CYCLONPartialView(cacheSize: 6)

        // Establish a view full of legitimate peers (their local age is 0).
        let legit = (0..<6).map { _ in makeEntry(age: 0) }
        for e in legit { view.add(e) }
        #expect(view.count == 6)

        // A real shuffle sends a bounded subset (here: 2 entries) and receives a
        // bounded subset back. The attacker forges a huge age on its replies and
        // echoes our kept peers with a huge age too. With age-based eviction this
        // would let the attacker selectively purge our legitimate peers; with
        // insertion-order eviction + age sanitization, our NON-sent legitimate
        // peers are protected.
        let sent = Array(legit.prefix(2))
        let poisonedEchoes = legit.dropFirst(2).map {
            CYCLONEntry(peerID: $0.peerID, addresses: [], age: .max)
        }
        let attackerEntries = (0..<2).map { _ in makeEntry(age: .max) }

        view.merge(
            received: Array(poisonedEchoes) + attackerEntries,
            sent: sent,
            selfID: selfID
        )

        // The 4 legitimate peers we did NOT shuffle out must all survive: a
        // forged age cannot evict them.
        let keptLegit = legit.dropFirst(2)
        for peer in keptLegit {
            #expect(view.entry(for: peer.peerID) != nil)
            // And their stored age must be the LOCAL value, never the forged max.
            #expect(view.entry(for: peer.peerID)?.age != .max)
        }
        #expect(view.count <= 6)
    }

    @Test("received age is not trusted (reset to 0)")
    func receivedAgeReset() {
        let selfID = makePeerID()
        let view = CYCLONPartialView(cacheSize: 10)
        let entry = makeEntry(age: 999_999)
        view.merge(received: [entry], sent: [], selfID: selfID)
        let stored = view.entry(for: entry.peerID)
        #expect(stored != nil)
        // Local age must be 0, not the attacker-supplied 999999.
        #expect(stored?.age == 0)
    }

    @Test("addAll resets received age to 0")
    func addAllResetsAge() {
        let selfID = makePeerID()
        let view = CYCLONPartialView(cacheSize: 10)
        let entry = makeEntry(age: 12345)
        view.addAll([entry], selfID: selfID)
        #expect(view.entry(for: entry.peerID)?.age == 0)
    }

    @Test("merge dedupes echoed sent entries")
    func mergeDedupesSent() {
        let selfID = makePeerID()
        let view = CYCLONPartialView(cacheSize: 10)

        let mine = makeEntry(age: 0)
        view.add(mine)

        // Attacker echoes our own sent entry back. It must not be re-inserted as
        // a "received" entry (we sent it, so it is excluded).
        let echoed = CYCLONEntry(peerID: mine.peerID, addresses: [], age: .max)
        view.merge(received: [echoed], sent: [mine], selfID: selfID)

        // mine may have been removed as a sent entry (only if over capacity);
        // here capacity is not exceeded so it stays, but its age must remain the
        // local value, never the echoed age.
        if let stored = view.entry(for: mine.peerID) {
            #expect(stored.age == 0)
        }
    }

    @Test("insertion-order eviction evicts oldest insertion, not highest age")
    func insertionOrderEviction() {
        let view = CYCLONPartialView(cacheSize: 2)
        // Insert in a known order, with ages that would mislead age-based eviction.
        let first = makeEntry(age: 0)    // oldest insertion
        let second = makeEntry(age: 100) // highest age
        view.add(first)
        view.add(second)
        // Adding a third evicts the oldest INSERTION (first), not the highest age.
        let third = makeEntry(age: 50)
        view.add(third)
        #expect(view.entry(for: first.peerID) == nil)   // evicted (oldest insertion)
        #expect(view.entry(for: second.peerID) != nil)  // kept despite high age
        #expect(view.entry(for: third.peerID) != nil)
    }
}
