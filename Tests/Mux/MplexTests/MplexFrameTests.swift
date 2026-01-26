/// MplexFrameTests - Tests for Mplex frame encoding/decoding
import Testing
import Foundation
@testable import P2PMuxMplex

@Suite("MplexFrame Tests")
struct MplexFrameTests {

    // MARK: - Varint Encoding/Decoding

    @Test("Encode and decode small varint")
    func encodeDecodeSmallVarint() {
        let values: [UInt64] = [0, 1, 127]
        for value in values {
            let encoded = encodeVarint(value)
            #expect(encoded.count == 1)
            let (decoded, size) = decodeVarint(from: Data(encoded), at: 0)!
            #expect(decoded == value)
            #expect(size == 1)
        }
    }

    @Test("Encode and decode medium varint")
    func encodeDecodeMediumVarint() {
        let values: [UInt64] = [128, 255, 300, 16383]
        for value in values {
            let encoded = encodeVarint(value)
            #expect(encoded.count == 2)
            let (decoded, size) = decodeVarint(from: Data(encoded), at: 0)!
            #expect(decoded == value)
            #expect(size == 2)
        }
    }

    @Test("Encode and decode large varint")
    func encodeDecodeLargeVarint() {
        let values: [UInt64] = [0x100000, 0x7FFFFFFF, UInt64.max]
        for value in values {
            let encoded = encodeVarint(value)
            let (decoded, size) = decodeVarint(from: Data(encoded), at: 0)!
            #expect(decoded == value)
            #expect(size == encoded.count)
        }
    }

    @Test("Decode incomplete varint returns nil")
    func decodeIncompleteVarint() {
        // A continuation byte (0x80 set) with no following byte
        let incompleteData = Data([0x80])
        let result = decodeVarint(from: incompleteData, at: 0)
        #expect(result == nil)
    }

    // MARK: - Frame Encoding/Decoding

    @Test("Encode and decode NewStream frame")
    func encodeDecodeNewStream() throws {
        let frame = MplexFrame.newStream(id: 1, name: "test")
        let encoded = frame.encode()

        let result = try MplexFrame.decode(from: encoded)
        #expect(result != nil)

        let (decoded, bytesConsumed) = result!
        #expect(decoded == frame)
        #expect(bytesConsumed == encoded.count)
        #expect(decoded.streamID == 1)
        #expect(decoded.flag == .newStream)
        #expect(String(data: decoded.data, encoding: .utf8) == "test")
    }

    @Test("Encode and decode Message frame (initiator)")
    func encodeDecodeMessageInitiator() throws {
        let data = Data("Hello, World!".utf8)
        let frame = MplexFrame.message(id: 5, isInitiator: true, data: data)
        let encoded = frame.encode()

        let result = try MplexFrame.decode(from: encoded)
        #expect(result != nil)

        let (decoded, _) = result!
        #expect(decoded == frame)
        #expect(decoded.streamID == 5)
        #expect(decoded.flag == .messageInitiator)
        #expect(decoded.data == data)
    }

    @Test("Encode and decode Message frame (receiver)")
    func encodeDecodeMessageReceiver() throws {
        let data = Data("Hello, World!".utf8)
        let frame = MplexFrame.message(id: 6, isInitiator: false, data: data)
        let encoded = frame.encode()

        let result = try MplexFrame.decode(from: encoded)
        #expect(result != nil)

        let (decoded, _) = result!
        #expect(decoded == frame)
        #expect(decoded.flag == .messageReceiver)
    }

    @Test("Encode and decode Close frame")
    func encodeDecodeClose() throws {
        let frameInit = MplexFrame.close(id: 3, isInitiator: true)
        let frameRecv = MplexFrame.close(id: 4, isInitiator: false)

        let (decodedInit, _) = try MplexFrame.decode(from: frameInit.encode())!
        let (decodedRecv, _) = try MplexFrame.decode(from: frameRecv.encode())!

        #expect(decodedInit.flag == .closeInitiator)
        #expect(decodedRecv.flag == .closeReceiver)
        #expect(decodedInit.data.isEmpty)
        #expect(decodedRecv.data.isEmpty)
    }

    @Test("Encode and decode Reset frame")
    func encodeDecodeReset() throws {
        let frameInit = MplexFrame.reset(id: 7, isInitiator: true)
        let frameRecv = MplexFrame.reset(id: 8, isInitiator: false)

        let (decodedInit, _) = try MplexFrame.decode(from: frameInit.encode())!
        let (decodedRecv, _) = try MplexFrame.decode(from: frameRecv.encode())!

        #expect(decodedInit.flag == .resetInitiator)
        #expect(decodedRecv.flag == .resetReceiver)
    }

    @Test("Decode with incomplete data returns nil")
    func decodeIncompleteData() throws {
        let frame = MplexFrame.message(id: 1, isInitiator: true, data: Data("test data".utf8))
        let encoded = frame.encode()

        // Try decoding with partial data
        let partial = Data(encoded.prefix(encoded.count - 1))
        let result = try MplexFrame.decode(from: partial)
        #expect(result == nil)
    }

    @Test("Decode multiple frames from buffer")
    func decodeMultipleFrames() throws {
        let frame1 = MplexFrame.newStream(id: 1)
        let frame2 = MplexFrame.message(id: 1, isInitiator: true, data: Data("hello".utf8))
        let frame3 = MplexFrame.close(id: 1, isInitiator: true)

        var buffer = frame1.encode()
        buffer.append(frame2.encode())
        buffer.append(frame3.encode())

        var offset = 0
        var frames: [MplexFrame] = []

        while offset < buffer.count {
            let slice = Data(buffer[offset...])
            if let (frame, consumed) = try MplexFrame.decode(from: slice) {
                frames.append(frame)
                offset += consumed
            } else {
                break
            }
        }

        #expect(frames.count == 3)
        #expect(frames[0].flag == .newStream)
        #expect(frames[1].flag == .messageInitiator)
        #expect(frames[2].flag == .closeInitiator)
    }

    @Test("Header encoding preserves stream ID and flag")
    func headerEncoding() throws {
        // Stream ID 100, flag messageInitiator (2)
        // header = (100 << 3) | 2 = 802
        let frame = MplexFrame(streamID: 100, flag: .messageInitiator, data: Data())
        let encoded = frame.encode()

        let (decoded, _) = try MplexFrame.decode(from: encoded)!
        #expect(decoded.streamID == 100)
        #expect(decoded.flag == .messageInitiator)
    }

    @Test("Large stream ID encoding")
    func largeStreamIDEncoding() throws {
        let largeID: UInt64 = 0x1FFFFFFF // Large stream ID
        let frame = MplexFrame(streamID: largeID, flag: .newStream, data: Data())
        let encoded = frame.encode()

        let (decoded, _) = try MplexFrame.decode(from: encoded)!
        #expect(decoded.streamID == largeID)
    }

    @Test("Frame with empty data")
    func frameWithEmptyData() throws {
        let frame = MplexFrame(streamID: 1, flag: .messageInitiator, data: Data())
        let encoded = frame.encode()

        let (decoded, _) = try MplexFrame.decode(from: encoded)!
        #expect(decoded.data.isEmpty)
    }

    @Test("Invalid flag throws error")
    func invalidFlag() {
        // Create invalid frame data manually: header with flag 7 (invalid)
        var data = Data()
        let header: UInt64 = (1 << 3) | 7 // stream ID 1, flag 7
        data.append(contentsOf: encodeVarint(header))
        data.append(contentsOf: encodeVarint(0)) // length 0

        #expect(throws: MplexError.self) {
            _ = try MplexFrame.decode(from: data)
        }
    }
}
