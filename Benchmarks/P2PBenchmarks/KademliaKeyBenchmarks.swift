/// KademliaKeyBenchmarks - Benchmarks for KademliaKey (4xUInt64 vs Data)
import Testing
import Foundation
import Crypto
import P2PKademlia

@Suite("KademliaKey Benchmarks")
struct KademliaKeyBenchmarks {

    @Test("init(bytes:) - 32 bytes Data to 4xUInt64")
    func initFromBytes() {
        let bytes = Data((0..<32).map { UInt8($0) })
        benchmark("KademliaKey.init(bytes:)", iterations: 1_000_000) {
            blackHole(KademliaKey(bytes: bytes))
        }
    }

    @Test("init(hashing:) - SHA-256 + UInt64 conversion")
    func initHashing() {
        let data = Data("some arbitrary data for hashing".utf8)
        benchmark("KademliaKey.init(hashing:)", iterations: 100_000) {
            blackHole(KademliaKey(hashing: data))
        }
    }

    @Test("distance(to:) - 4xUInt64 XOR (stack-only)")
    func distance() {
        let a = KademliaKey(bytes: Data((0..<32).map { UInt8($0) }))
        let b = KademliaKey(bytes: Data((0..<32).map { UInt8($0 &+ 128) }))
        benchmark("KademliaKey.distance(to:)", iterations: 10_000_000) {
            blackHole(a.distance(to: b))
        }
    }

    @Test("leadingZeroBits - UInt64.leadingZeroBitCount")
    func leadingZeroBits() {
        let key = KademliaKey(w0: 0, w1: 0, w2: 0x0000_0001_0000_0000, w3: 0xFFFF_FFFF_FFFF_FFFF)
        benchmark("KademliaKey.leadingZeroBits", iterations: 10_000_000) {
            blackHole(key.leadingZeroBits)
        }
    }

    @Test("< comparison - max 4 integer comparisons")
    func lessThan() {
        let a = KademliaKey(w0: 0x0000_0000_0000_0001, w1: 0, w2: 0, w3: 0)
        let b = KademliaKey(w0: 0x0000_0000_0000_0002, w1: 0, w2: 0, w3: 0)
        benchmark("KademliaKey.<", iterations: 10_000_000) {
            blackHole(a < b)
        }
    }

    @Test("isCloser(to:than:) - 2x distance + comparison")
    func isCloser() {
        let target = KademliaKey(bytes: Data((0..<32).map { UInt8($0) }))
        let a = KademliaKey(bytes: Data((0..<32).map { UInt8($0 &+ 10) }))
        let b = KademliaKey(bytes: Data((0..<32).map { UInt8($0 &+ 50) }))
        benchmark("KademliaKey.isCloser(to:than:)", iterations: 5_000_000) {
            blackHole(a.isCloser(to: target, than: b))
        }
    }

    @Test("hash(into:) - 4xUInt64 combine")
    func hashInto() {
        let key = KademliaKey(bytes: Data((0..<32).map { UInt8($0) }))
        benchmark("KademliaKey.hash(into:)", iterations: 10_000_000) {
            var hasher = Hasher()
            key.hash(into: &hasher)
            blackHole(hasher.finalize())
        }
    }

    @Test("Dictionary lookup - 100 entries")
    func dictionaryLookup() {
        var dict: [KademliaKey: Int] = [:]
        var keys: [KademliaKey] = []
        for i in 0..<100 {
            var bytes = Data(repeating: 0, count: 32)
            bytes[0] = UInt8(i)
            let key = KademliaKey(bytes: bytes)
            dict[key] = i
            keys.append(key)
        }
        benchmark("KademliaKey Dictionary lookup (100)", iterations: 1_000_000) {
            for key in keys {
                blackHole(dict[key])
            }
        }
    }

    // MARK: - Baselines (pre-optimization implementations)

    @Test("BASELINE: Data XOR distance (32-byte loop)")
    func baselineDataXOR() {
        let a = Data((0..<32).map { UInt8($0) })
        let b = Data((0..<32).map { UInt8($0 &+ 128) })
        benchmark("BASELINE: Data XOR", iterations: 10_000_000) {
            var result = Data(count: 32)
            for i in 0..<32 {
                result[i] = a[i] ^ b[i]
            }
            blackHole(result)
        }
    }

    @Test("BASELINE: Data leadingZeros (byte loop)")
    func baselineDataLeadingZeros() {
        var data = Data(repeating: 0, count: 32)
        data[16] = 0x01
        benchmark("BASELINE: Data leadingZeros", iterations: 10_000_000) {
            var zeros = 0
            for byte in data {
                if byte == 0 {
                    zeros += 8
                } else {
                    zeros += byte.leadingZeroBitCount
                    break
                }
            }
            blackHole(zeros)
        }
    }
}
