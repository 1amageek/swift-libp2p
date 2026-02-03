import Testing
import Foundation
import NIOCore
@testable import P2PMuxYamux

@Suite("YamuxFrame Tests")
struct YamuxFrameTests {

    // MARK: - Constants

    @Test("Header size is 12 bytes")
    func headerSize() {
        #expect(yamuxHeaderSize == 12)
    }

    @Test("Default window size is 256KB")
    func defaultWindowSize() {
        #expect(yamuxDefaultWindowSize == 256 * 1024)
    }

    @Test("Protocol version is 0")
    func protocolVersion() {
        #expect(yamuxVersion == 0)
    }

    // MARK: - Frame Type Values

    @Test("Frame type raw values match spec")
    func frameTypeRawValues() {
        #expect(YamuxFrameType.data.rawValue == 0)
        #expect(YamuxFrameType.windowUpdate.rawValue == 1)
        #expect(YamuxFrameType.ping.rawValue == 2)
        #expect(YamuxFrameType.goAway.rawValue == 3)
    }

    // MARK: - Flag Values

    @Test("Flag raw values match spec")
    func flagRawValues() {
        #expect(YamuxFlags.syn.rawValue == 0x0001)
        #expect(YamuxFlags.ack.rawValue == 0x0002)
        #expect(YamuxFlags.fin.rawValue == 0x0004)
        #expect(YamuxFlags.rst.rawValue == 0x0008)
    }

    @Test("Flags can be combined")
    func flagsCombination() {
        let combined: YamuxFlags = [.syn, .fin]
        #expect(combined.contains(.syn))
        #expect(combined.contains(.fin))
        #expect(!combined.contains(.ack))
        #expect(!combined.contains(.rst))
        #expect(combined.rawValue == 0x0005)
    }

    @Test("All flags combined")
    func allFlagsCombined() {
        let all: YamuxFlags = [.syn, .ack, .fin, .rst]
        #expect(all.rawValue == 0x000F)
    }

    // MARK: - GoAway Reason Values

    @Test("GoAway reason raw values match spec")
    func goAwayReasonRawValues() {
        #expect(YamuxGoAwayReason.normal.rawValue == 0)
        #expect(YamuxGoAwayReason.protocolError.rawValue == 1)
        #expect(YamuxGoAwayReason.internalError.rawValue == 2)
    }

    // MARK: - Data Frame Encoding

    @Test("Encode data frame without payload")
    func encodeDataFrameEmpty() {
        let frame = YamuxFrame.data(streamID: 1, data: ByteBuffer())
        let encoded = Data(buffer: frame.encode())

        #expect(encoded.count == 12)

        // Version
        #expect(encoded[0] == 0)
        // Type (data = 0)
        #expect(encoded[1] == 0)
        // Flags (0)
        #expect(encoded[2] == 0)
        #expect(encoded[3] == 0)
        // Stream ID (1)
        #expect(encoded[4] == 0)
        #expect(encoded[5] == 0)
        #expect(encoded[6] == 0)
        #expect(encoded[7] == 1)
        // Length (0)
        #expect(encoded[8] == 0)
        #expect(encoded[9] == 0)
        #expect(encoded[10] == 0)
        #expect(encoded[11] == 0)
    }

    @Test("Encode data frame with payload")
    func encodeDataFrameWithPayload() {
        let payload = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F])  // "Hello"
        let frame = YamuxFrame.data(streamID: 42, data: ByteBuffer(bytes: payload))
        let encoded = Data(buffer: frame.encode())

        #expect(encoded.count == 12 + 5)

        // Stream ID (42)
        #expect(encoded[4] == 0)
        #expect(encoded[5] == 0)
        #expect(encoded[6] == 0)
        #expect(encoded[7] == 42)
        // Length (5)
        #expect(encoded[8] == 0)
        #expect(encoded[9] == 0)
        #expect(encoded[10] == 0)
        #expect(encoded[11] == 5)
        // Payload
        #expect(encoded[12] == 0x48)
        #expect(encoded[13] == 0x65)
        #expect(encoded[14] == 0x6C)
        #expect(encoded[15] == 0x6C)
        #expect(encoded[16] == 0x6F)
    }

    @Test("Encode data frame with SYN flag")
    func encodeDataFrameWithSYN() {
        let frame = YamuxFrame.data(streamID: 1, flags: .syn, data: ByteBuffer())
        let encoded = Data(buffer: frame.encode())

        // Flags (SYN = 0x0001)
        #expect(encoded[2] == 0x00)
        #expect(encoded[3] == 0x01)
    }

    @Test("Encode data frame with multiple flags")
    func encodeDataFrameWithMultipleFlags() {
        let frame = YamuxFrame.data(streamID: 1, flags: [.syn, .fin], data: ByteBuffer())
        let encoded = Data(buffer: frame.encode())

        // Flags (SYN | FIN = 0x0005)
        #expect(encoded[2] == 0x00)
        #expect(encoded[3] == 0x05)
    }

    @Test("Encode data frame with large stream ID")
    func encodeDataFrameLargeStreamID() {
        let streamID: UInt32 = 0xDEADBEEF
        let frame = YamuxFrame.data(streamID: streamID, data: ByteBuffer())
        let encoded = Data(buffer: frame.encode())

        // Stream ID (big-endian)
        #expect(encoded[4] == 0xDE)
        #expect(encoded[5] == 0xAD)
        #expect(encoded[6] == 0xBE)
        #expect(encoded[7] == 0xEF)
    }

    // MARK: - Window Update Frame Encoding

    @Test("Encode window update frame")
    func encodeWindowUpdateFrame() {
        let frame = YamuxFrame.windowUpdate(streamID: 5, delta: 65536)
        let encoded = Data(buffer: frame.encode())

        #expect(encoded.count == 12)

        // Type (windowUpdate = 1)
        #expect(encoded[1] == 1)
        // Stream ID (5)
        #expect(encoded[7] == 5)
        // Length = delta (65536 = 0x00010000)
        #expect(encoded[8] == 0x00)
        #expect(encoded[9] == 0x01)
        #expect(encoded[10] == 0x00)
        #expect(encoded[11] == 0x00)
    }

    // MARK: - Ping Frame Encoding

    @Test("Encode ping request frame")
    func encodePingRequestFrame() {
        let frame = YamuxFrame.ping(opaque: 12345, ack: false)
        let encoded = Data(buffer: frame.encode())

        #expect(encoded.count == 12)

        // Type (ping = 2)
        #expect(encoded[1] == 2)
        // Flags (0 for request)
        #expect(encoded[2] == 0)
        #expect(encoded[3] == 0)
        // Stream ID (always 0 for ping)
        #expect(encoded[4] == 0)
        #expect(encoded[5] == 0)
        #expect(encoded[6] == 0)
        #expect(encoded[7] == 0)
        // Length = opaque value (12345 = 0x00003039)
        #expect(encoded[8] == 0x00)
        #expect(encoded[9] == 0x00)
        #expect(encoded[10] == 0x30)
        #expect(encoded[11] == 0x39)
    }

    @Test("Encode ping response frame")
    func encodePingResponseFrame() {
        let frame = YamuxFrame.ping(opaque: 12345, ack: true)
        let encoded = Data(buffer: frame.encode())

        // Flags (ACK = 0x0002)
        #expect(encoded[2] == 0x00)
        #expect(encoded[3] == 0x02)
    }

    // MARK: - GoAway Frame Encoding

    @Test("Encode goaway frame with normal reason")
    func encodeGoAwayNormal() {
        let frame = YamuxFrame.goAway(reason: .normal)
        let encoded = Data(buffer: frame.encode())

        #expect(encoded.count == 12)

        // Type (goAway = 3)
        #expect(encoded[1] == 3)
        // Stream ID (always 0 for goaway)
        #expect(encoded[4] == 0)
        #expect(encoded[5] == 0)
        #expect(encoded[6] == 0)
        #expect(encoded[7] == 0)
        // Length = reason (normal = 0)
        #expect(encoded[11] == 0)
    }

    @Test("Encode goaway frame with protocol error")
    func encodeGoAwayProtocolError() {
        let frame = YamuxFrame.goAway(reason: .protocolError)
        let encoded = Data(buffer: frame.encode())

        // Length = reason (protocolError = 1)
        #expect(encoded[11] == 1)
    }

    @Test("Encode goaway frame with internal error")
    func encodeGoAwayInternalError() {
        let frame = YamuxFrame.goAway(reason: .internalError)
        let encoded = Data(buffer: frame.encode())

        // Length = reason (internalError = 2)
        #expect(encoded[11] == 2)
    }

    // MARK: - Frame Decoding

    @Test("Decode data frame without payload")
    func decodeDataFrameEmpty() throws {
        var buffer = ByteBuffer(bytes: [
            0,      // version
            0,      // type (data)
            0, 0,   // flags
            0, 0, 0, 1,  // stream ID
            0, 0, 0, 0   // length
        ] as [UInt8])

        let frame = try YamuxFrame.decode(from: &buffer)
        #expect(frame != nil)

        #expect(frame!.type == .data)
        #expect(frame!.flags == [])
        #expect(frame!.streamID == 1)
        #expect(frame!.length == 0)
        #expect(frame!.data == nil)
        #expect(buffer.readerIndex == 12)
    }

    @Test("Decode data frame with payload")
    func decodeDataFrameWithPayload() throws {
        var buffer = ByteBuffer(bytes: [
            0,      // version
            0,      // type (data)
            0, 0,   // flags
            0, 0, 0, 5,  // stream ID
            0, 0, 0, 5,  // length
            0x48, 0x65, 0x6C, 0x6C, 0x6F  // "Hello"
        ] as [UInt8])

        let frame = try YamuxFrame.decode(from: &buffer)
        #expect(frame != nil)

        #expect(frame!.type == .data)
        #expect(frame!.streamID == 5)
        #expect(frame!.length == 5)
        #expect(frame!.data == ByteBuffer(bytes: [0x48, 0x65, 0x6C, 0x6C, 0x6F] as [UInt8]))
        #expect(buffer.readerIndex == 17)
    }

    @Test("Decode data frame with SYN flag")
    func decodeDataFrameWithSYN() throws {
        var buffer = ByteBuffer(bytes: [
            0,      // version
            0,      // type (data)
            0, 1,   // flags (SYN)
            0, 0, 0, 1,  // stream ID
            0, 0, 0, 0   // length
        ] as [UInt8])

        let frame = try YamuxFrame.decode(from: &buffer)
        #expect(frame != nil)
        #expect(frame!.flags.contains(.syn))
    }

    @Test("Decode window update frame")
    func decodeWindowUpdateFrame() throws {
        var buffer = ByteBuffer(bytes: [
            0,      // version
            1,      // type (windowUpdate)
            0, 0,   // flags
            0, 0, 0, 7,  // stream ID
            0, 1, 0, 0   // delta (65536)
        ] as [UInt8])

        let frame = try YamuxFrame.decode(from: &buffer)
        #expect(frame != nil)

        #expect(frame!.type == .windowUpdate)
        #expect(frame!.streamID == 7)
        #expect(frame!.length == 65536)
        #expect(frame!.data == nil)
    }

    @Test("Decode ping frame")
    func decodePingFrame() throws {
        var buffer = ByteBuffer(bytes: [
            0,      // version
            2,      // type (ping)
            0, 2,   // flags (ACK)
            0, 0, 0, 0,  // stream ID
            0, 0, 0x30, 0x39  // opaque (12345)
        ] as [UInt8])

        let frame = try YamuxFrame.decode(from: &buffer)
        #expect(frame != nil)

        #expect(frame!.type == .ping)
        #expect(frame!.flags.contains(.ack))
        #expect(frame!.streamID == 0)
        #expect(frame!.length == 12345)
    }

    @Test("Decode goaway frame")
    func decodeGoAwayFrame() throws {
        var buffer = ByteBuffer(bytes: [
            0,      // version
            3,      // type (goAway)
            0, 0,   // flags
            0, 0, 0, 0,  // stream ID
            0, 0, 0, 1   // reason (protocolError)
        ] as [UInt8])

        let frame = try YamuxFrame.decode(from: &buffer)
        #expect(frame != nil)

        #expect(frame!.type == .goAway)
        #expect(frame!.length == 1)  // protocolError
    }

    // MARK: - Roundtrip Tests

    @Test("Roundtrip data frame")
    func roundtripDataFrame() throws {
        let payload = ByteBuffer(bytes: [0xDE, 0xAD, 0xBE, 0xEF] as [UInt8])
        let original = YamuxFrame.data(streamID: 123, flags: [.syn, .ack], data: payload)
        var encoded = original.encode()
        let decoded = try YamuxFrame.decode(from: &encoded)

        #expect(decoded != nil)

        #expect(decoded!.type == original.type)
        #expect(decoded!.flags == original.flags)
        #expect(decoded!.streamID == original.streamID)
        #expect(decoded!.length == original.length)
        #expect(decoded!.data == original.data)
    }

    @Test("Roundtrip window update frame")
    func roundtripWindowUpdateFrame() throws {
        let original = YamuxFrame.windowUpdate(streamID: 999, delta: 131072)
        var encoded = original.encode()
        let decoded = try YamuxFrame.decode(from: &encoded)

        #expect(decoded != nil)

        #expect(decoded!.type == .windowUpdate)
        #expect(decoded!.streamID == 999)
        #expect(decoded!.length == 131072)
    }

    @Test("Roundtrip ping frame")
    func roundtripPingFrame() throws {
        let original = YamuxFrame.ping(opaque: 0xCAFEBABE, ack: true)
        var encoded = original.encode()
        let decoded = try YamuxFrame.decode(from: &encoded)

        #expect(decoded != nil)

        #expect(decoded!.type == .ping)
        #expect(decoded!.flags.contains(.ack))
        #expect(decoded!.length == 0xCAFEBABE)
    }

    @Test("Roundtrip goaway frame")
    func roundtripGoAwayFrame() throws {
        let original = YamuxFrame.goAway(reason: .internalError)
        var encoded = original.encode()
        let decoded = try YamuxFrame.decode(from: &encoded)

        #expect(decoded != nil)

        #expect(decoded!.type == .goAway)
        #expect(decoded!.length == 2)  // internalError
    }

    // MARK: - Partial Data Handling

    @Test("Decode returns nil for incomplete header")
    func decodeIncompleteHeader() throws {
        var buffer = ByteBuffer(bytes: [0, 0, 0, 0, 0] as [UInt8])  // Only 5 bytes

        let result = try YamuxFrame.decode(from: &buffer)
        #expect(result == nil)
    }

    @Test("Decode returns nil for incomplete payload")
    func decodeIncompletePayload() throws {
        var buffer = ByteBuffer(bytes: [
            0,      // version
            0,      // type (data)
            0, 0,   // flags
            0, 0, 0, 1,  // stream ID
            0, 0, 0, 10, // length = 10
            0x48, 0x65   // only 2 bytes of payload
        ] as [UInt8])

        let result = try YamuxFrame.decode(from: &buffer)
        #expect(result == nil)
    }

    // MARK: - Error Cases

    @Test("Decode throws for invalid version")
    func decodeInvalidVersion() throws {
        var buffer = ByteBuffer(bytes: [
            1,      // invalid version (should be 0)
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ] as [UInt8])

        #expect(throws: YamuxError.self) {
            _ = try YamuxFrame.decode(from: &buffer)
        }
    }

    @Test("Decode throws for invalid frame type")
    func decodeInvalidFrameType() throws {
        var buffer = ByteBuffer(bytes: [
            0,      // version
            99,     // invalid type
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ] as [UInt8])

        #expect(throws: YamuxError.self) {
            _ = try YamuxFrame.decode(from: &buffer)
        }
    }

    @Test("Decode throws for frame too large")
    func decodeFrameTooLarge() throws {
        // Frame with length > 16MB (yamuxMaxFrameSize)
        var buffer = ByteBuffer(bytes: [
            0,      // version
            0,      // type (data)
            0, 0,   // flags
            0, 0, 0, 1,  // stream ID
            0x01, 0x00, 0x00, 0x01  // length = 16777217 (> 16MB)
        ] as [UInt8])

        #expect(throws: YamuxError.self) {
            _ = try YamuxFrame.decode(from: &buffer)
        }
    }

    @Test("Decode accepts frame at max size limit")
    func decodeFrameAtMaxSize() throws {
        // Frame with length = 16MB (exactly at limit)
        var buffer = ByteBuffer(bytes: [
            0,      // version
            0,      // type (data)
            0, 0,   // flags
            0, 0, 0, 1,  // stream ID
            0x01, 0x00, 0x00, 0x00  // length = 16777216 (exactly 16MB)
        ] as [UInt8])

        // Should return nil because we don't have 16MB of payload
        // But it should NOT throw an error for frame size
        let result = try YamuxFrame.decode(from: &buffer)
        #expect(result == nil)  // Incomplete payload, not error
    }

    // MARK: - Boundary Tests

    @Test("Encode/decode max stream ID")
    func maxStreamID() throws {
        let maxID: UInt32 = UInt32.max
        let original = YamuxFrame.data(streamID: maxID, data: ByteBuffer())
        var encoded = original.encode()
        let decoded = try YamuxFrame.decode(from: &encoded)

        #expect(decoded != nil)
        #expect(decoded!.streamID == maxID)
    }

    @Test("Encode/decode max length")
    func maxLength() throws {
        let original = YamuxFrame.windowUpdate(streamID: 1, delta: UInt32.max)
        var encoded = original.encode()
        let decoded = try YamuxFrame.decode(from: &encoded)

        #expect(decoded != nil)
        #expect(decoded!.length == UInt32.max)
    }

    @Test("Stream ID 0 is valid for ping")
    func streamIDZeroForPing() throws {
        let frame = YamuxFrame.ping(opaque: 1, ack: false)
        #expect(frame.streamID == 0)
    }

    @Test("Stream ID 0 is valid for goaway")
    func streamIDZeroForGoAway() throws {
        let frame = YamuxFrame.goAway(reason: .normal)
        #expect(frame.streamID == 0)
    }

    // MARK: - Multiple Frames

    @Test("Decode multiple frames from buffer")
    func decodeMultipleFrames() throws {
        // Create buffer with two frames
        let frame1 = YamuxFrame.data(streamID: 1, data: ByteBuffer(bytes: [0x01] as [UInt8]))
        let frame2 = YamuxFrame.data(streamID: 2, data: ByteBuffer(bytes: [0x02] as [UInt8]))

        var buffer = frame1.encode()
        var buf2 = frame2.encode()
        buffer.writeBuffer(&buf2)

        // Decode first frame
        let decoded1 = try YamuxFrame.decode(from: &buffer)
        #expect(decoded1 != nil)
        #expect(decoded1!.streamID == 1)
        #expect(decoded1!.data == ByteBuffer(bytes: [0x01] as [UInt8]))

        // Decode second frame from remainder (buffer reader index already advanced)
        let decoded2 = try YamuxFrame.decode(from: &buffer)
        #expect(decoded2 != nil)
        #expect(decoded2!.streamID == 2)
        #expect(decoded2!.data == ByteBuffer(bytes: [0x02] as [UInt8]))
    }
}

@Suite("YamuxError Tests")
struct YamuxErrorTests {

    @Test("Invalid version error contains version number")
    func invalidVersionError() {
        let error = YamuxError.invalidVersion(5)
        if case .invalidVersion(let version) = error {
            #expect(version == 5)
        } else {
            Issue.record("Expected invalidVersion error")
        }
    }

    @Test("Invalid frame type error contains type number")
    func invalidFrameTypeError() {
        let error = YamuxError.invalidFrameType(99)
        if case .invalidFrameType(let frameType) = error {
            #expect(frameType == 99)
        } else {
            Issue.record("Expected invalidFrameType error")
        }
    }

    @Test("Protocol error contains message")
    func protocolError() {
        let error = YamuxError.protocolError("test message")
        if case .protocolError(let message) = error {
            #expect(message == "test message")
        } else {
            Issue.record("Expected protocolError")
        }
    }

    @Test("Frame too large error contains size and max")
    func frameTooLargeError() {
        let error = YamuxError.frameTooLarge(size: 20_000_000, max: 16_777_216)
        if case .frameTooLarge(let size, let max) = error {
            #expect(size == 20_000_000)
            #expect(max == 16_777_216)
        } else {
            Issue.record("Expected frameTooLarge error")
        }
    }

    @Test("Max streams exceeded error contains current and max")
    func maxStreamsExceededError() {
        let error = YamuxError.maxStreamsExceeded(current: 1000, max: 1000)
        if case .maxStreamsExceeded(let current, let max) = error {
            #expect(current == 1000)
            #expect(max == 1000)
        } else {
            Issue.record("Expected maxStreamsExceeded error")
        }
    }

    @Test("Stream ID reused error contains stream ID")
    func streamIDReusedError() {
        let error = YamuxError.streamIDReused(42)
        if case .streamIDReused(let streamID) = error {
            #expect(streamID == 42)
        } else {
            Issue.record("Expected streamIDReused error")
        }
    }
}

@Suite("YamuxConfiguration Tests")
struct YamuxConfigurationTests {

    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = YamuxConfiguration.default
        #expect(config.maxConcurrentStreams == 1000)
        #expect(config.initialWindowSize == 256 * 1024)
    }

    @Test("Default init uses default values")
    func defaultInit() {
        let config = YamuxConfiguration()
        #expect(config.maxConcurrentStreams == 1000)
        #expect(config.initialWindowSize == 256 * 1024)
    }

    @Test("Custom configuration values")
    func customConfiguration() {
        let config = YamuxConfiguration(
            maxConcurrentStreams: 500,
            initialWindowSize: 128 * 1024
        )
        #expect(config.maxConcurrentStreams == 500)
        #expect(config.initialWindowSize == 128 * 1024)
    }

    @Test("Configuration with minimum streams")
    func minimumStreams() {
        let config = YamuxConfiguration(maxConcurrentStreams: 1)
        #expect(config.maxConcurrentStreams == 1)
    }

    @Test("Configuration with large stream limit")
    func largeStreamLimit() {
        let config = YamuxConfiguration(maxConcurrentStreams: 10_000)
        #expect(config.maxConcurrentStreams == 10_000)
    }

    @Test("Configuration with custom window size")
    func customWindowSize() {
        let config = YamuxConfiguration(initialWindowSize: 1024 * 1024)
        #expect(config.initialWindowSize == 1024 * 1024)
    }
}
