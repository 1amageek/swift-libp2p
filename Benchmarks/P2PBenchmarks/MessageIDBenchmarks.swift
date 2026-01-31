/// MessageIDBenchmarks - Benchmarks for MessageID (FNV-1a cache vs per-op hash)
import Testing
import Foundation
import Crypto
import P2PGossipSub

@Suite("MessageID Benchmarks")
struct MessageIDBenchmarks {

    @Test("init(bytes:) - FNV-1a hash computation (20B)")
    func initBytes20() {
        let bytes = Data((0..<20).map { UInt8($0) })
        benchmark("MessageID.init(bytes:) 20B", iterations: 5_000_000) {
            blackHole(MessageID(bytes: bytes))
        }
    }

    @Test("hash(into:) - cached O(1)")
    func hashInto() {
        let id = MessageID(bytes: Data((0..<20).map { UInt8($0) }))
        benchmark("MessageID.hash(into:)", iterations: 10_000_000) {
            var hasher = Hasher()
            id.hash(into: &hasher)
            blackHole(hasher.finalize())
        }
    }

    @Test("== same - hash match + bytes compare")
    func equalSame() {
        let a = MessageID(bytes: Data((0..<20).map { UInt8($0) }))
        let b = MessageID(bytes: Data((0..<20).map { UInt8($0) }))
        benchmark("MessageID == (same)", iterations: 10_000_000) {
            blackHole(a == b)
        }
    }

    @Test("== different - hash mismatch early return")
    func equalDifferent() {
        let a = MessageID(bytes: Data((0..<20).map { UInt8($0) }))
        let b = MessageID(bytes: Data((0..<20).map { UInt8($0 &+ 1) }))
        benchmark("MessageID == (different)", iterations: 10_000_000) {
            blackHole(a == b)
        }
    }

    @Test("Set insert 1000 items")
    func setInsert() {
        let ids = (0..<1000).map { i -> MessageID in
            var bytes = Data(repeating: 0, count: 20)
            bytes[0] = UInt8(i & 0xFF)
            bytes[1] = UInt8((i >> 8) & 0xFF)
            return MessageID(bytes: bytes)
        }
        benchmark("MessageID Set insert x1000", iterations: 10_000) {
            var set = Set<MessageID>()
            set.reserveCapacity(1000)
            for id in ids {
                set.insert(id)
            }
            blackHole(set.count)
        }
    }

    @Test("Set contains - 1000 entries")
    func setContains() {
        var set = Set<MessageID>()
        set.reserveCapacity(1000)
        let ids = (0..<1000).map { i -> MessageID in
            var bytes = Data(repeating: 0, count: 20)
            bytes[0] = UInt8(i & 0xFF)
            bytes[1] = UInt8((i >> 8) & 0xFF)
            return MessageID(bytes: bytes)
        }
        for id in ids {
            set.insert(id)
        }
        benchmark("MessageID Set contains (1000)", iterations: 5_000_000) {
            blackHole(set.contains(ids[500]))
        }
    }

    @Test("computeFromHash - SHA-256 -> MessageID")
    func computeFromHash() {
        let data = Data("test message payload for hashing".utf8)
        benchmark("MessageID.computeFromHash", iterations: 100_000) {
            blackHole(MessageID.computeFromHash(data))
        }
    }

    // MARK: - Baseline

    @Test("BASELINE: Data standard hash (full scan each time)")
    func baselineDataHash() {
        let bytes = Data((0..<20).map { UInt8($0) })
        benchmark("BASELINE: Data.hash", iterations: 10_000_000) {
            var hasher = Hasher()
            bytes.hash(into: &hasher)
            blackHole(hasher.finalize())
        }
    }
}
