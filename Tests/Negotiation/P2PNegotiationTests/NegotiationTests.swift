import Testing
@testable import P2PNegotiation
import P2PCore
import Synchronization

@Suite("Multistream-Select Tests")
struct MultistreamSelectTests {

    @Test("Encode adds length prefix and newline")
    func encodeBasic() throws {
        let encoded = MultistreamSelect.encode("/noise")
        #expect(bytes(encoded).first == 7)
        #expect(String(decoding: encoded.readableBytesView.dropFirst(), as: UTF8.self) == "/noise\n")
    }

    @Test("Encode multistream protocol ID")
    func encodeMultistreamProtocol() throws {
        let encoded = MultistreamSelect.encode("/multistream/1.0.0")
        #expect(bytes(encoded).first == 19)
        #expect(String(decoding: encoded.readableBytesView.dropFirst(), as: UTF8.self) == "/multistream/1.0.0\n")
    }

    @Test("Decode valid message")
    func decodeBasic() throws {
        let encoded = MultistreamSelect.encode("/noise")
        let (decoded, consumed) = try MultistreamSelect.decode(encoded)
        #expect(decoded == "/noise")
        #expect(consumed == encoded.readableBytes)
    }

    @Test("Encode/Decode round trip")
    func encodeDecodeRoundTrip() throws {
        let protocols = [
            "/multistream/1.0.0",
            "/noise",
            "/yamux/1.0.0",
            "/ipfs/id/1.0.0",
            "/ipfs/ping/1.0.0",
            "na"
        ]

        for proto in protocols {
            let encoded = MultistreamSelect.encode(proto)
            let (decoded, consumed) = try MultistreamSelect.decode(encoded)
            #expect(decoded == proto, "Round trip failed for: \(proto)")
            #expect(consumed == encoded.readableBytes)
        }
    }

    @Test("Decode empty protocol")
    func decodeEmptyProtocol() throws {
        let encoded = MultistreamSelect.encode("")
        let (decoded, _) = try MultistreamSelect.decode(encoded)
        #expect(decoded == "")
    }

    @Test("Decode message without newline throws error")
    func decodeWithoutNewline() throws {
        awaitInvalidDecode(buffer([5] + Array("/test".utf8)), error: .invalidMessage)
    }

    @Test("Decode truncated message throws error")
    func decodeTruncatedMessage() throws {
        awaitInvalidDecode(buffer([10] + Array("/test".utf8)), error: .invalidMessage)
    }

    @Test("Initiator negotiation succeeds with first protocol")
    func initiatorSuccessFirstProtocol() async throws {
        let mockChannel = MockChannel()
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.negotiate(
            protocols: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")
        let written = mockChannel.writtenData
        #expect(written.count == 2)
        #expect(try MultistreamSelect.decode(written[0]).0 == "/multistream/1.0.0")
        #expect(try MultistreamSelect.decode(written[1]).0 == "/noise")
    }

    @Test("Initiator negotiation falls back to second protocol")
    func initiatorFallbackToSecondProtocol() async throws {
        let mockChannel = MockChannel()
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("na"))
        mockChannel.queueRead(MultistreamSelect.encode("/yamux/1.0.0"))

        let result = try await MultistreamSelect.negotiate(
            protocols: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/yamux/1.0.0")
        let written = mockChannel.writtenData
        #expect(written.count == 3)
        #expect(try MultistreamSelect.decode(written[0]).0 == "/multistream/1.0.0")
        #expect(try MultistreamSelect.decode(written[1]).0 == "/noise")
        #expect(try MultistreamSelect.decode(written[2]).0 == "/yamux/1.0.0")
    }

    @Test("Initiator negotiation fails with no agreement")
    func initiatorNoAgreement() async throws {
        let mockChannel = MockChannel()
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("na"))
        mockChannel.queueRead(MultistreamSelect.encode("na"))

        await #expect(throws: NegotiationError.noAgreement) {
            _ = try await MultistreamSelect.negotiate(
                protocols: ["/noise", "/yamux/1.0.0"],
                read: { try await mockChannel.read() },
                write: { try await mockChannel.write($0) }
            )
        }
    }

    @Test("Initiator negotiation fails on multistream header mismatch")
    func initiatorHeaderMismatch() async throws {
        let mockChannel = MockChannel()
        mockChannel.queueRead(MultistreamSelect.encode("/wrong/1.0.0"))

        await #expect(throws: NegotiationError.protocolMismatch) {
            _ = try await MultistreamSelect.negotiate(
                protocols: ["/noise"],
                read: { try await mockChannel.read() },
                write: { try await mockChannel.write($0) }
            )
        }
    }

    @Test("Responder negotiation succeeds with supported protocol")
    func responderSuccessWithSupportedProtocol() async throws {
        let mockChannel = MockChannel()
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.handle(
            supported: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")
        let written = mockChannel.writtenData
        #expect(written.count == 2)
        #expect(try MultistreamSelect.decode(written[0]).0 == "/multistream/1.0.0")
        #expect(try MultistreamSelect.decode(written[1]).0 == "/noise")
    }

    @Test("Responder sends na then accepts supported protocol")
    func responderRejectsUnsupportedThenAccepts() async throws {
        let mockChannel = MockChannel()
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("/unknown"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.handle(
            supported: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")
        let written = mockChannel.writtenData
        #expect(written.count == 3)
        #expect(try MultistreamSelect.decode(written[1]).0 == "na")
        #expect(try MultistreamSelect.decode(written[2]).0 == "/noise")
    }

    @Test("Responder handles ls command with correct wire format")
    func responderHandlesLsCommand() async throws {
        let mockChannel = MockChannel()
        mockChannel.queueRead(MultistreamSelect.encode("/multistream/1.0.0"))
        mockChannel.queueRead(MultistreamSelect.encode("ls"))
        mockChannel.queueRead(MultistreamSelect.encode("/noise"))

        let result = try await MultistreamSelect.handle(
            supported: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")
        let written = mockChannel.writtenData
        #expect(written.count == 3)

        let lsResponse = written[1]
        let (outerLength, outerLengthBytes) = try decodeVarint(lsResponse)
        let inner = dropped(lsResponse, outerLengthBytes)
        #expect(inner.readableBytes == Int(outerLength))
        #expect(String(decoding: inner.readableBytesView, as: UTF8.self) == "/noise\n/yamux/1.0.0\n\n")
    }

    @Test("NegotiationResult stores protocol ID and remainder")
    func negotiationResultStoresRemainder() {
        let remainder = buffer([1, 2, 3, 4])
        let result = NegotiationResult(protocolID: "/noise", remainderBuffer: remainder)
        #expect(result.protocolID == "/noise")
        #expect(equalBytes(result.remainderBuffer, remainder))
    }

    @Test("Decode returns correct bytes consumed with trailing data")
    func decodeWithTrailingData() throws {
        let combinedBuffer = combine(MultistreamSelect.encode("/noise"), MultistreamSelect.encode("/yamux/1.0.0"))
        let (decoded, consumed) = try MultistreamSelect.decode(combinedBuffer)
        #expect(decoded == "/noise")

        let remaining = dropped(combinedBuffer, consumed)
        let (decoded2, consumed2) = try MultistreamSelect.decode(remaining)
        #expect(decoded2 == "/yamux/1.0.0")
        #expect(consumed2 == remaining.readableBytes)
    }

    @Test("Responder handles V1Lazy coalesced header and protocol")
    func responderHandlesCoalescedLazy() async throws {
        let mockChannel = MockChannel()
        mockChannel.queueRead(combine(
            MultistreamSelect.encode("/multistream/1.0.0"),
            MultistreamSelect.encode("/noise")
        ))

        let result = try await MultistreamSelect.handle(
            supported: ["/noise", "/yamux/1.0.0"],
            read: { try await mockChannel.read() },
            write: { try await mockChannel.write($0) }
        )

        #expect(result.protocolID == "/noise")
    }

    private func awaitInvalidDecode(_ buffer: ByteBuffer, error: NegotiationError) {
        #expect(throws: error) {
            _ = try MultistreamSelect.decode(buffer)
        }
    }
}

func buffer(_ bytes: [UInt8]) -> ByteBuffer {
    var buffer = ByteBuffer()
    buffer.writeBytes(bytes)
    return buffer
}

func bytes(_ buffer: ByteBuffer) -> [UInt8] {
    Array(buffer.readableBytesView)
}

func combine(_ parts: ByteBuffer...) -> ByteBuffer {
    var combined = ByteBuffer()
    for var part in parts {
        combined.writeBuffer(&part)
    }
    return combined
}

func dropped(_ buffer: ByteBuffer, _ count: Int) -> ByteBuffer {
    var copy = buffer
    copy.moveReaderIndex(forwardBy: count)
    copy.discardReadBytes()
    return copy
}

func equalBytes(_ lhs: ByteBuffer, _ rhs: ByteBuffer) -> Bool {
    lhs.readableBytesView.elementsEqual(rhs.readableBytesView)
}

func decodeVarint(_ buffer: ByteBuffer) throws -> (UInt64, Int) {
    try buffer.withUnsafeReadableBytes { ptr in
        try Varint.decode(from: UnsafeRawBufferPointer(ptr), at: 0)
    }
}

final class MockChannel: Sendable {
    private struct State: Sendable {
        var readQueue: [ByteBuffer] = []
        var writtenData: [ByteBuffer] = []
    }

    private let state = Mutex<State>(State())

    func queueRead(_ data: ByteBuffer) {
        state.withLock { $0.readQueue.append(data) }
    }

    func read() async throws -> ByteBuffer {
        try state.withLock { state in
            guard !state.readQueue.isEmpty else {
                throw MockChannelError.noMoreData
            }
            return state.readQueue.removeFirst()
        }
    }

    func write(_ data: ByteBuffer) async throws {
        state.withLock { $0.writtenData.append(data) }
    }

    var writtenData: [ByteBuffer] {
        state.withLock { $0.writtenData }
    }
}

enum MockChannelError: Error {
    case noMoreData
}
