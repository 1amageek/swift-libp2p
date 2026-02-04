/// Benchmarks for partial sort optimizations.
import Foundation
import P2PCore
import Testing

struct PartialSortBenchmarks {

    // MARK: - Baseline: Full Sort + Prefix

    @Test("Full sort + prefix (k=20, n=100)")
    func fullSortSmall() {
        let data = (0..<100).shuffled()
        benchmark("Full sort + prefix (k=20, n=100)", iterations: 100_000) {
            let result = data.sorted().prefix(20)
            blackHole(result)
        }
    }

    @Test("Full sort + prefix (k=20, n=500)")
    func fullSortMedium() {
        let data = (0..<500).shuffled()
        benchmark("Full sort + prefix (k=20, n=500)", iterations: 10_000) {
            let result = data.sorted().prefix(20)
            blackHole(result)
        }
    }

    @Test("Full sort + prefix (k=20, n=1000)")
    func fullSortLarge() {
        let data = (0..<1000).shuffled()
        benchmark("Full sort + prefix (k=20, n=1000)", iterations: 5_000) {
            let result = data.sorted().prefix(20)
            blackHole(result)
        }
    }

    // MARK: - Optimized: Partial Sort

    @Test("Partial sort (k=20, n=100)")
    func partialSortSmall() {
        let data = (0..<100).shuffled()
        benchmark("Partial sort (k=20, n=100)", iterations: 100_000) {
            let result = data.smallest(20, by: <)
            blackHole(result)
        }
    }

    @Test("Partial sort (k=20, n=500)")
    func partialSortMedium() {
        let data = (0..<500).shuffled()
        benchmark("Partial sort (k=20, n=500)", iterations: 10_000) {
            let result = data.smallest(20, by: <)
            blackHole(result)
        }
    }

    @Test("Partial sort (k=20, n=1000)")
    func partialSortLarge() {
        let data = (0..<1000).shuffled()
        benchmark("Partial sort (k=20, n=1000)", iterations: 5_000) {
            let result = data.smallest(20, by: <)
            blackHole(result)
        }
    }

    // MARK: - Edge Cases

    @Test("Partial sort when k == n")
    func partialSortFullSize() {
        let data = (0..<100).shuffled()
        benchmark("Partial sort when k == n", iterations: 50_000) {
            let result = data.smallest(100, by: <)
            blackHole(result)
        }
    }

    @Test("Partial sort when k > n (fallback)")
    func partialSortOversized() {
        let data = (0..<50).shuffled()
        benchmark("Partial sort when k > n", iterations: 50_000) {
            let result = data.smallest(100, by: <)
            blackHole(result)
        }
    }

    @Test("Partial sort with k=1 (min element)")
    func partialSortMinElement() {
        let data = (0..<500).shuffled()
        benchmark("Partial sort with k=1", iterations: 50_000) {
            let result = data.smallest(1, by: <)
            blackHole(result)
        }
    }

    // MARK: - Realistic Scenarios

    @Test("KademliaQuery selectCandidates simulation")
    func kademliaSelectCandidates() {
        // Simulate 200 peers, select 20 closest (α parameter)
        struct MockPeer: Comparable {
            let distance: UInt64
            static func < (lhs: MockPeer, rhs: MockPeer) -> Bool {
                lhs.distance < rhs.distance
            }
        }

        let peers = (0..<200).map { _ in MockPeer(distance: UInt64.random(in: 0...UInt64.max)) }

        benchmark("KademliaQuery selectCandidates (n=200, k=20)", iterations: 10_000) {
            let result = peers.smallest(20, by: <)
            blackHole(result)
        }
    }

    @Test("ConnectionPool trim simulation")
    func connectionPoolTrim() {
        // Simulate 150 connections, trim 30 lowest-priority
        struct MockConnection: Comparable {
            let tags: Int
            let lastActivity: Int

            static func < (lhs: MockConnection, rhs: MockConnection) -> Bool {
                if lhs.tags != rhs.tags { return lhs.tags < rhs.tags }
                return lhs.lastActivity < rhs.lastActivity
            }
        }

        let connections = (0..<150).map { i in
            MockConnection(
                tags: Int.random(in: 0...10),
                lastActivity: i
            )
        }

        benchmark("ConnectionPool trim (n=150, k=30)", iterations: 10_000) {
            let result = connections.smallest(30, by: <)
            blackHole(result)
        }
    }

    @Test("RoutingTable closestPeers simulation")
    func routingTableClosestPeers() {
        // Simulate 120 routing table entries, find 20 closest
        struct MockEntry {
            let distance: UInt64
        }

        let entries = (0..<120).map { _ in MockEntry(distance: UInt64.random(in: 0...UInt64.max)) }

        benchmark("RoutingTable closestPeers (n=120, k=20)", iterations: 10_000) {
            let result = entries.smallest(20, by: { $0.distance < $1.distance })
            blackHole(result)
        }
    }

    // MARK: - Comparison Metrics

    @Test("Speedup comparison (k=20, n=500)")
    func speedupComparison() {
        let data = (0..<500).shuffled()

        // Measure full sort
        let fullStart = ContinuousClock.now
        for _ in 0..<10_000 {
            let result = data.sorted().prefix(20)
            blackHole(result)
        }
        let fullDuration = ContinuousClock.now - fullStart
        let fullSortTime = Double(fullDuration.components.attoseconds) / 1e18

        // Measure partial sort
        let partialStart = ContinuousClock.now
        for _ in 0..<10_000 {
            let result = data.smallest(20, by: <)
            blackHole(result)
        }
        let partialDuration = ContinuousClock.now - partialStart
        let partialSortTime = Double(partialDuration.components.attoseconds) / 1e18

        let speedup = fullSortTime / partialSortTime
        print("Full sort:    \(String(format: "%.6f", fullSortTime))s (10,000 iterations)")
        print("Partial sort: \(String(format: "%.6f", partialSortTime))s (10,000 iterations)")
        print("Speedup:      \(String(format: "%.2f", speedup))x")
    }
}
