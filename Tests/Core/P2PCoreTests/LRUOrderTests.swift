import Testing
@testable import P2PCore

@Suite("LRUOrder Tests")
struct LRUOrderTests {

    @Test("Empty tracker")
    func emptyTracker() {
        let lru = LRUOrder<String>()
        #expect(lru.count == 0)
        #expect(lru.isEmpty)
        #expect(lru.oldest == nil)
        #expect(!lru.contains("a"))
    }

    @Test("Insert single key")
    func insertSingle() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        #expect(lru.count == 1)
        #expect(!lru.isEmpty)
        #expect(lru.oldest == "a")
        #expect(lru.contains("a"))
    }

    @Test("Insert preserves order")
    func insertOrder() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        lru.insert("b")
        lru.insert("c")

        #expect(lru.count == 3)
        #expect(lru.oldest == "a")
    }

    @Test("Duplicate insert moves to tail")
    func duplicateInsert() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        lru.insert("b")
        lru.insert("c")

        // Re-insert "a" should move it to tail
        lru.insert("a")
        #expect(lru.count == 3)
        #expect(lru.oldest == "b")

        // Remove oldest should return "b" then "c" then "a"
        #expect(lru.removeOldest() == "b")
        #expect(lru.removeOldest() == "c")
        #expect(lru.removeOldest() == "a")
    }

    @Test("Touch moves to tail")
    func touch() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        lru.insert("b")
        lru.insert("c")

        lru.touch("a")
        #expect(lru.oldest == "b")

        // Order should be: b, c, a
        #expect(lru.removeOldest() == "b")
        #expect(lru.removeOldest() == "c")
        #expect(lru.removeOldest() == "a")
    }

    @Test("Touch non-existent key does nothing")
    func touchNonExistent() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        lru.touch("z")
        #expect(lru.count == 1)
        #expect(lru.oldest == "a")
    }

    @Test("Remove specific key")
    func removeSpecific() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        lru.insert("b")
        lru.insert("c")

        let removed = lru.remove("b")
        #expect(removed)
        #expect(lru.count == 2)
        #expect(!lru.contains("b"))

        // Order should be: a, c
        #expect(lru.removeOldest() == "a")
        #expect(lru.removeOldest() == "c")
    }

    @Test("Remove non-existent key returns false")
    func removeNonExistent() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        let removed = lru.remove("z")
        #expect(!removed)
        #expect(lru.count == 1)
    }

    @Test("Remove head")
    func removeHead() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        lru.insert("b")
        lru.insert("c")

        let removed = lru.remove("a")
        #expect(removed)
        #expect(lru.oldest == "b")
    }

    @Test("Remove tail")
    func removeTail() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        lru.insert("b")
        lru.insert("c")

        let removed = lru.remove("c")
        #expect(removed)
        #expect(lru.count == 2)

        // Order: a, b
        #expect(lru.removeOldest() == "a")
        #expect(lru.removeOldest() == "b")
    }

    @Test("RemoveOldest returns FIFO order")
    func removeOldestFIFO() {
        var lru = LRUOrder<Int>()
        for i in 0..<5 {
            lru.insert(i)
        }

        for i in 0..<5 {
            #expect(lru.removeOldest() == i)
        }
        #expect(lru.isEmpty)
    }

    @Test("RemoveOldest on empty returns nil")
    func removeOldestEmpty() {
        var lru = LRUOrder<String>()
        #expect(lru.removeOldest() == nil)
    }

    @Test("RemoveAll clears tracker")
    func removeAll() {
        var lru = LRUOrder<String>()
        lru.insert("a")
        lru.insert("b")
        lru.insert("c")

        lru.removeAll()
        #expect(lru.count == 0)
        #expect(lru.isEmpty)
        #expect(lru.oldest == nil)
        #expect(!lru.contains("a"))
    }

    @Test("Index recycling after remove")
    func indexRecycling() {
        var lru = LRUOrder<String>()
        // Insert and remove to create free indices
        lru.insert("a")
        lru.insert("b")
        lru.insert("c")
        lru.remove("a")
        lru.remove("b")

        // New inserts should reuse freed indices
        lru.insert("d")
        lru.insert("e")

        #expect(lru.count == 3)
        #expect(lru.oldest == "c")
        #expect(lru.removeOldest() == "c")
        #expect(lru.removeOldest() == "d")
        #expect(lru.removeOldest() == "e")
    }

    @Test("Single element operations")
    func singleElement() {
        var lru = LRUOrder<String>()
        lru.insert("only")

        #expect(lru.oldest == "only")

        // Touch the only element (no-op since it's already tail)
        lru.touch("only")
        #expect(lru.oldest == "only")
        #expect(lru.count == 1)

        // Remove the only element
        #expect(lru.removeOldest() == "only")
        #expect(lru.isEmpty)
    }

    @Test("Many items ordering")
    func manyItems() {
        var lru = LRUOrder<Int>()
        for i in 0..<100 {
            lru.insert(i)
        }
        #expect(lru.count == 100)
        #expect(lru.oldest == 0)

        // Touch items 0-49 in order
        for i in 0..<50 {
            lru.touch(i)
        }

        // Now oldest should be 50
        #expect(lru.oldest == 50)

        // Remove oldest 50 items (50..99)
        for i in 50..<100 {
            #expect(lru.removeOldest() == i)
        }

        // Remaining: 0..49
        for i in 0..<50 {
            #expect(lru.removeOldest() == i)
        }
        #expect(lru.isEmpty)
    }
}
