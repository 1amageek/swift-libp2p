import P2PCore
import Testing

@Suite("CollectionPartialSort Tests")
struct CollectionPartialSortTests {
    @Test("smallest matches sorted prefix for integers")
    func smallestMatchesSortedPrefix() {
        let values = [9, 4, 7, 1, 3, 8, 2, 6, 5]
        let result = values.smallest(4, by: <)
        #expect(result == Array(values.sorted().prefix(4)))
    }

    @Test("comparable overload matches sorted prefix")
    func comparableOverloadMatchesSortedPrefix() {
        let values = [9, 4, 7, 1, 3, 8, 2, 6, 5]
        let result = values.smallest(4)
        #expect(result == Array(values.sorted().prefix(4)))
    }

    @Test("smallest with k == 1 returns minimum element")
    func smallestSingleElement() {
        let values = [42, 7, 19, 3, 12]
        let result = values.smallest(1, by: <)
        #expect(result == [3])
    }

    @Test("comparable overload with k == 1 returns minimum element")
    func comparableOverloadSingleElement() {
        let values = [42, 7, 19, 3, 12]
        let result = values.smallest(1)
        #expect(result == [3])
    }

    @Test("smallest with oversized k returns fully sorted collection")
    func smallestOversizedK() {
        let values = [5, 1, 4, 1, 3]
        let result = values.smallest(10, by: <)
        #expect(result == values.sorted())
    }
}
