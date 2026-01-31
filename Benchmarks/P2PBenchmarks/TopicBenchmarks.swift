/// TopicBenchmarks - Benchmarks for Topic (hash cache vs per-op hash)
import Testing
import Foundation
import P2PGossipSub

@Suite("Topic Benchmarks")
struct TopicBenchmarks {

    @Test("init - short string (\"blocks\")")
    func initShortString() {
        benchmark("Topic.init short", iterations: 5_000_000) {
            blackHole(Topic("blocks"))
        }
    }

    @Test("init - long string (46 chars)")
    func initLongString() {
        let longTopic = "/meshsub/1.1.0/some-application/blocks/v1/json"
        benchmark("Topic.init long", iterations: 5_000_000) {
            blackHole(Topic(longTopic))
        }
    }

    @Test("hash(into:) - cached O(1)")
    func hashInto() {
        let topic = Topic("blocks")
        benchmark("Topic.hash(into:)", iterations: 10_000_000) {
            var hasher = Hasher()
            topic.hash(into: &hasher)
            blackHole(hasher.finalize())
        }
    }

    @Test("Dictionary lookup - 50 entries")
    func dictionaryLookup() {
        var dict: [Topic: Int] = [:]
        dict.reserveCapacity(50)
        var topics: [Topic] = []
        for i in 0..<50 {
            let topic = Topic("topic-\(i)")
            dict[topic] = i
            topics.append(topic)
        }
        benchmark("Topic Dictionary lookup (50)", iterations: 5_000_000) {
            blackHole(dict[topics[25]])
        }
    }

    @Test("== same / different")
    func equality() {
        let a = Topic("blocks")
        let b = Topic("blocks")
        let c = Topic("transactions")
        benchmark("Topic == (same)", iterations: 10_000_000) {
            blackHole(a == b)
        }
        benchmark("Topic == (different)", iterations: 10_000_000) {
            blackHole(a == c)
        }
    }

    // MARK: - Baseline

    @Test("BASELINE: String hash (per-op Hasher)")
    func baselineStringHash() {
        let value = "blocks"
        benchmark("BASELINE: String.hash", iterations: 10_000_000) {
            var hasher = Hasher()
            hasher.combine(value)
            blackHole(hasher.finalize())
        }
    }
}
