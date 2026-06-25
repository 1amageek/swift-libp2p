// YamuxFrameTests.swift
// Round-trip + buffer-boundary (off-by-one) coverage for the `[UInt8]` Yamux frame
// codec — the boundary the milestone calls out for fuzzing.

import Testing
@testable import LibP2PNode

@Suite("Yamux [UInt8] frame codec")
struct YamuxFrameTests {

    @Test("Header-only frames round-trip exactly")
    func headerOnlyRoundTrip() throws {
        let frames: [YamuxFrame] = [
            .makeData(streamID: 1, flags: .syn, payload: []),
            .makeData(streamID: 2, flags: .ack, payload: []),
            .makeData(streamID: 7, flags: .fin, payload: []),
            .makeData(streamID: 9, flags: .rst, payload: []),
            .makeWindowUpdate(streamID: 0, delta: 65536),
            .makePing(opaque: 0xDEADBEEF, ack: false),
            .makePing(opaque: 0x01020304, ack: true),
            .makeGoAway(reason: .normal),
        ]
        for frame in frames {
            let encoded = frame.encode()
            #expect(encoded.count == yamuxHeaderSize)
            let outcome = try YamuxFrame.decode(from: encoded, at: 0)
            guard case .frame(let decoded, let consumed) = outcome else {
                Issue.record("expected a complete frame")
                return
            }
            #expect(consumed == encoded.count)
            #expect(decoded == frame)
        }
    }

    @Test("Data frames round-trip the payload")
    func dataRoundTrip() throws {
        let payloads: [[UInt8]] = [
            [],
            [0x00],
            [UInt8](0..<255),
            [UInt8](repeating: 0xAB, count: 4096),
        ]
        for payload in payloads {
            let frame = YamuxFrame.makeData(streamID: 3, flags: [.syn, .fin], payload: payload)
            let encoded = frame.encode()
            #expect(encoded.count == yamuxHeaderSize + payload.count)
            let outcome = try YamuxFrame.decode(from: encoded, at: 0)
            guard case .frame(let decoded, let consumed) = outcome else {
                Issue.record("expected a complete frame")
                return
            }
            #expect(consumed == encoded.count)
            #expect(decoded.data == payload)
            #expect(decoded.length == UInt32(payload.count))
        }
    }

    @Test("Truncated buffers return needMoreData at every prefix length (off-by-one)")
    func truncatedNeedsMore() throws {
        let payload = [UInt8](1...50)
        let frame = YamuxFrame.makeData(streamID: 5, flags: [], payload: payload)
        let encoded = frame.encode()

        // Every strict prefix of the encoding must be incomplete.
        for prefixLen in 0..<encoded.count {
            let prefix = Array(encoded[0..<prefixLen])
            let outcome = try YamuxFrame.decode(from: prefix, at: 0)
            #expect(outcome == .needMoreData, "prefix length \(prefixLen) should be incomplete")
        }
        // The exact full length decodes.
        let full = try YamuxFrame.decode(from: encoded, at: 0)
        guard case .frame(_, let consumed) = full else {
            Issue.record("full buffer should decode")
            return
        }
        #expect(consumed == encoded.count)
    }

    @Test("Concatenated frames decode one at a time with exact offsets")
    func streamingDecode() throws {
        var wire = [UInt8]()
        let f1 = YamuxFrame.makeData(streamID: 1, flags: .syn, payload: [0xAA, 0xBB])
        let f2 = YamuxFrame.makePing(opaque: 42, ack: false)
        let f3 = YamuxFrame.makeData(streamID: 1, flags: .fin, payload: [UInt8](repeating: 7, count: 100))
        wire.append(contentsOf: f1.encode())
        wire.append(contentsOf: f2.encode())
        wire.append(contentsOf: f3.encode())

        var offset = 0
        var decoded: [YamuxFrame] = []
        while offset < wire.count {
            let outcome = try YamuxFrame.decode(from: wire, at: offset)
            guard case .frame(let frame, let consumed) = outcome else {
                Issue.record("expected frame at offset \(offset)")
                return
            }
            decoded.append(frame)
            offset += consumed
        }
        #expect(offset == wire.count)
        #expect(decoded == [f1, f2, f3])
    }

    @Test("Oversize Data length is rejected before slicing")
    func oversizeRejected() {
        // Craft a header declaring a Data length above the max frame size.
        var header = [UInt8](repeating: 0, count: yamuxHeaderSize)
        header[0] = yamuxVersion
        header[1] = YamuxFrameType.data.rawValue
        let big = yamuxMaxFrameSize + 1
        header[8] = UInt8(truncatingIfNeeded: big >> 24)
        header[9] = UInt8(truncatingIfNeeded: big >> 16)
        header[10] = UInt8(truncatingIfNeeded: big >> 8)
        header[11] = UInt8(truncatingIfNeeded: big)
        #expect(throws: NodeError.yamuxFrameTooLarge) {
            _ = try YamuxFrame.decode(from: header, at: 0)
        }
    }

    @Test("Bad version is a protocol error")
    func badVersion() {
        var header = [UInt8](repeating: 0, count: yamuxHeaderSize)
        header[0] = 9   // not version 0
        header[1] = YamuxFrameType.ping.rawValue
        #expect(throws: NodeError.yamuxProtocolError) {
            _ = try YamuxFrame.decode(from: header, at: 0)
        }
    }
}
