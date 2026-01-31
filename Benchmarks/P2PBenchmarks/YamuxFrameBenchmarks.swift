/// YamuxFrameBenchmarks - Benchmarks for YamuxFrame encode/decode
import Testing
import Foundation
@testable import P2PMuxYamux
import NIOCore

@Suite("YamuxFrame Benchmarks")
struct YamuxFrameBenchmarks {

    @Test("encode - header only (windowUpdate)")
    func encodeHeaderOnly() {
        let frame = YamuxFrame.windowUpdate(streamID: 1, delta: 65536)
        benchmark("YamuxFrame encode headerOnly", iterations: 5_000_000) {
            blackHole(frame.encode())
        }
    }

    @Test("encode - 1KB payload")
    func encode1KB() {
        let payload = ByteBuffer(repeating: 0xAB, count: 1024)
        let frame = YamuxFrame.data(streamID: 1, data: payload)
        benchmark("YamuxFrame encode 1KB", iterations: 1_000_000) {
            blackHole(frame.encode())
        }
    }

    @Test("encode - 64KB payload")
    func encode64KB() {
        let payload = ByteBuffer(repeating: 0xAB, count: 65536)
        let frame = YamuxFrame.data(streamID: 1, data: payload)
        benchmark("YamuxFrame encode 64KB", iterations: 500_000) {
            blackHole(frame.encode())
        }
    }

    @Test("encode - windowUpdate control")
    func encodeWindowUpdate() {
        let frame = YamuxFrame.windowUpdate(streamID: 42, delta: 262144)
        benchmark("YamuxFrame encode windowUpdate", iterations: 5_000_000) {
            blackHole(frame.encode())
        }
    }

    @Test("encode - ping control")
    func encodePing() {
        let frame = YamuxFrame.ping(opaque: 12345)
        benchmark("YamuxFrame encode ping", iterations: 5_000_000) {
            blackHole(frame.encode())
        }
    }

    @Test("decode - header only")
    func decodeHeaderOnly() throws {
        let frame = YamuxFrame.windowUpdate(streamID: 1, delta: 65536)
        let encoded = frame.encode()
        try benchmark("YamuxFrame decode headerOnly", iterations: 5_000_000) {
            var buf = encoded
            blackHole(try YamuxFrame.decode(from: &buf))
        }
    }

    @Test("decode - 1KB payload")
    func decode1KB() throws {
        let payload = ByteBuffer(repeating: 0xAB, count: 1024)
        let frame = YamuxFrame.data(streamID: 1, data: payload)
        let encoded = frame.encode()
        try benchmark("YamuxFrame decode 1KB", iterations: 1_000_000) {
            var buf = encoded
            blackHole(try YamuxFrame.decode(from: &buf))
        }
    }

    @Test("decode - 64KB payload")
    func decode64KB() throws {
        let payload = ByteBuffer(repeating: 0xAB, count: 65536)
        let frame = YamuxFrame.data(streamID: 1, data: payload)
        let encoded = frame.encode()
        try benchmark("YamuxFrame decode 64KB", iterations: 500_000) {
            var buf = encoded
            blackHole(try YamuxFrame.decode(from: &buf))
        }
    }

    @Test("roundtrip - 1KB")
    func roundtrip1KB() throws {
        let payload = ByteBuffer(repeating: 0xCD, count: 1024)
        let frame = YamuxFrame.data(streamID: 7, flags: .syn, data: payload)
        try benchmark("YamuxFrame roundtrip 1KB", iterations: 1_000_000) {
            let encoded = frame.encode()
            var buf = encoded
            blackHole(try YamuxFrame.decode(from: &buf))
        }
    }

    @Test("decode - 10 consecutive frames (streaming)")
    func decode10Streaming() throws {
        // Build a buffer with 10 consecutive window update frames
        var combined = ByteBuffer()
        for i: UInt32 in 0..<10 {
            let frame = YamuxFrame.windowUpdate(streamID: i + 1, delta: 4096)
            var encoded = frame.encode()
            combined.writeBuffer(&encoded)
        }
        try benchmark("YamuxFrame decode x10 streaming", iterations: 500_000) {
            var buf = combined
            for _ in 0..<10 {
                blackHole(try YamuxFrame.decode(from: &buf))
            }
        }
    }
}
