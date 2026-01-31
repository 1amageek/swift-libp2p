import Testing
import P2PCore
@testable import P2PDiscoveryCYCLON

@Suite("CYCLON PartialView Tests")
struct CYCLONPartialViewTests {

    private func makePeerID() -> PeerID {
        let keyPair = KeyPair.generateEd25519()
        return keyPair.peerID
    }

    private func makeEntry(age: UInt64 = 0) -> CYCLONEntry {
        CYCLONEntry(peerID: makePeerID(), addresses: [], age: age)
    }

    @Test("Empty view")
    func emptyView() {
        let view = CYCLONPartialView(cacheSize: 5)
        #expect(view.count == 0)
        #expect(view.isEmpty)
        #expect(view.oldest() == nil)
        #expect(view.allEntries().isEmpty)
    }

    @Test("Add and retrieve entries")
    func addAndRetrieve() {
        let view = CYCLONPartialView(cacheSize: 5)
        let entry = makeEntry()
        view.add(entry)

        #expect(view.count == 1)
        #expect(!view.isEmpty)
        #expect(view.entry(for: entry.peerID) != nil)
        #expect(view.entry(for: entry.peerID)?.age == 0)
    }

    @Test("Evicts oldest when over capacity")
    func evictsOldest() {
        let view = CYCLONPartialView(cacheSize: 3)
        let e1 = makeEntry(age: 10)
        let e2 = makeEntry(age: 5)
        let e3 = makeEntry(age: 1)
        view.add(e1)
        view.add(e2)
        view.add(e3)
        #expect(view.count == 3)

        // Adding a 4th should evict e1 (age 10)
        let e4 = makeEntry(age: 0)
        view.add(e4)
        #expect(view.count == 3)
        #expect(view.entry(for: e1.peerID) == nil)
        #expect(view.entry(for: e4.peerID) != nil)
    }

    @Test("Increment ages")
    func incrementAges() {
        let view = CYCLONPartialView(cacheSize: 5)
        let entry = makeEntry(age: 3)
        view.add(entry)

        view.incrementAges()
        #expect(view.entry(for: entry.peerID)?.age == 4)

        view.incrementAges()
        #expect(view.entry(for: entry.peerID)?.age == 5)
    }

    @Test("Oldest returns entry with highest age")
    func oldestEntry() {
        let view = CYCLONPartialView(cacheSize: 10)
        let e1 = makeEntry(age: 5)
        let e2 = makeEntry(age: 15)
        let e3 = makeEntry(age: 10)
        view.add(e1)
        view.add(e2)
        view.add(e3)

        let oldest = view.oldest()
        #expect(oldest?.peerID == e2.peerID)
        #expect(oldest?.age == 15)
    }

    @Test("Random subset respects count and exclusion")
    func randomSubset() {
        let view = CYCLONPartialView(cacheSize: 10)
        let entries = (0..<5).map { _ in makeEntry() }
        for e in entries { view.add(e) }

        let subset = view.randomSubset(count: 3)
        #expect(subset.count == 3)

        // With exclusion
        let excluded = entries[0].peerID
        let filtered = view.randomSubset(count: 10, excluding: excluded)
        #expect(filtered.count == 4) // 5 - 1 excluded
        #expect(!filtered.contains(where: { $0.peerID == excluded }))
    }

    @Test("Random subset returns all when count exceeds size")
    func randomSubsetExceedsSize() {
        let view = CYCLONPartialView(cacheSize: 10)
        let entries = (0..<3).map { _ in makeEntry() }
        for e in entries { view.add(e) }

        let subset = view.randomSubset(count: 100)
        #expect(subset.count == 3)
    }

    @Test("Remove entry")
    func removeEntry() {
        let view = CYCLONPartialView(cacheSize: 5)
        let entry = makeEntry()
        view.add(entry)
        #expect(view.count == 1)

        let removed = view.remove(entry.peerID)
        #expect(removed != nil)
        #expect(view.count == 0)
        #expect(view.entry(for: entry.peerID) == nil)
    }

    @Test("Merge integrates received entries")
    func merge() {
        let selfID = makePeerID()
        let view = CYCLONPartialView(cacheSize: 5)

        // Pre-populate with some entries
        let e1 = makeEntry(age: 2)
        let e2 = makeEntry(age: 3)
        view.add(e1)
        view.add(e2)

        // Simulate shuffle: sent e1, received new entries
        let r1 = makeEntry(age: 0)
        let r2 = makeEntry(age: 1)
        view.merge(received: [r1, r2], sent: [e1], selfID: selfID)

        // r1 and r2 should be in the view
        #expect(view.entry(for: r1.peerID) != nil)
        #expect(view.entry(for: r2.peerID) != nil)
        // e2 should still be there
        #expect(view.entry(for: e2.peerID) != nil)
    }

    @Test("Merge excludes self")
    func mergeExcludesSelf() {
        let selfID = makePeerID()
        let view = CYCLONPartialView(cacheSize: 5)

        let selfEntry = CYCLONEntry(peerID: selfID, addresses: [], age: 0)
        let other = makeEntry(age: 0)
        view.merge(received: [selfEntry, other], sent: [], selfID: selfID)

        #expect(view.entry(for: selfID) == nil)
        #expect(view.entry(for: other.peerID) != nil)
    }

    @Test("AddAll skips self")
    func addAllSkipsSelf() {
        let selfID = makePeerID()
        let view = CYCLONPartialView(cacheSize: 5)
        let selfEntry = CYCLONEntry(peerID: selfID, addresses: [], age: 0)
        let other = makeEntry()
        view.addAll([selfEntry, other], selfID: selfID)

        #expect(view.count == 1)
        #expect(view.entry(for: selfID) == nil)
    }

    @Test("Clear removes all entries")
    func clear() {
        let view = CYCLONPartialView(cacheSize: 5)
        for _ in 0..<3 { view.add(makeEntry()) }
        #expect(view.count == 3)

        view.clear()
        #expect(view.count == 0)
        #expect(view.isEmpty)
    }
}
