/// VarintBenchmarks - Benchmarks for Varint (stack buffer vs heap)
import Testing
import Foundation
import P2PCore
import NIOCore

@Suite("Varint Benchmarks")
struct VarintBenchmarks {

    @Test("encode(0) - 1 byte output")
    func encodeZero() {
        benchmark("Varint.encode(0)", iterations: 10_000_000) {
            blackHole(Varint.encode(0))
        }
    }

    @Test("encode(300) - 2 byte output")
    func encode300() {
        benchmark("Varint.encode(300)", iterations: 10_000_000) {
            blackHole(Varint.encode(300))
        }
    }

    @Test("encode(UInt64.max) - 10 byte output")
    func encodeMax() {
        benchmark("Varint.encode(UInt64.max)", iterations: 10_000_000) {
            blackHole(Varint.encode(UInt64.max))
        }
    }

    @Test("encode(into:) - zero allocation buffer write")
    func encodeIntoBuffer() {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 10, alignment: 1)
        defer { buffer.deallocate() }
        benchmark("Varint.encode(into:)", iterations: 10_000_000) {
            blackHole(Varint.encode(300, into: buffer))
        }
    }

    @Test("decode 1-byte value")
    func decode1Byte() throws {
        let encoded = Varint.encode(42)
        try benchmark("Varint.decode 1-byte", iterations: 10_000_000) {
            blackHole(try Varint.decode(encoded))
        }
    }

    @Test("decode(from:at:) - UnsafeRawBufferPointer")
    func decodeFromBuffer() throws {
        let encoded = Varint.encode(300)
        try benchmark("Varint.decode(from:at:)", iterations: 10_000_000) {
            try encoded.withUnsafeBytes { buffer in
                blackHole(try Varint.decode(from: buffer, at: 0))
            }
        }
    }

    @Test("round-trip 10 values")
    func roundTrip10() throws {
        let values: [UInt64] = [0, 1, 127, 128, 255, 300, 16384, 1_000_000, UInt64(Int32.max), UInt64.max]
        try benchmark("Varint round-trip x10", iterations: 1_000_000) {
            for v in values {
                let encoded = Varint.encode(v)
                let (decoded, _) = try Varint.decode(encoded)
                blackHole(decoded)
            }
        }
    }

    // MARK: - Baseline (pre-optimization)

    @Test("BASELINE: [UInt8] encode (Array append)")
    func baselineArrayEncode() {
        benchmark("BASELINE: [UInt8] encode", iterations: 10_000_000) {
            var result: [UInt8] = []
            var n: UInt64 = 300
            while n >= 0x80 {
                result.append(UInt8(n & 0x7F) | 0x80)
                n >>= 7
            }
            result.append(UInt8(n))
            blackHole(Data(result))
        }
    }

    // MARK: - ByteBuffer Optimizations (NIO zero-copy)

    @Test("ByteBuffer encode - zero allocation")
    func byteBufferEncode() {
        let allocator = ByteBufferAllocator()
        benchmark("Varint.encode(into: ByteBuffer)", iterations: 10_000_000) {
            var buffer = allocator.buffer(capacity: 10)
            _ = Varint.encode(300, into: &buffer)
            blackHole(buffer)
        }
    }

    @Test("ByteBuffer decode - zero copy")
    func byteBufferDecode() throws {
        let allocator = ByteBufferAllocator()
        var encoded = allocator.buffer(capacity: 10)
        _ = Varint.encode(300, into: &encoded)

        try benchmark("Varint.decode(from: ByteBuffer)", iterations: 10_000_000) {
            var buffer = encoded
            let value = try Varint.decode(from: &buffer)
            blackHole(value)
        }
    }

    @Test("ByteBuffer round-trip - NIO native")
    func byteBufferRoundTrip() throws {
        let allocator = ByteBufferAllocator()
        let values: [UInt64] = [0, 1, 127, 128, 255, 300, 16384, 1_000_000, UInt64(Int32.max), UInt64.max]

        try benchmark("Varint ByteBuffer round-trip x10", iterations: 1_000_000) {
            for v in values {
                var buffer = allocator.buffer(capacity: 10)
                _ = Varint.encode(v, into: &buffer)
                let decoded = try Varint.decode(from: &buffer)
                blackHole(decoded)
            }
        }
    }
}
