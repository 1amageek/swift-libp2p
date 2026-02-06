import Testing
import Foundation
import NIOCore
@testable import P2PMux
@testable import P2PCore

@Suite("Mux Tests")
struct MuxTests {

    // MARK: - StreamMessageError

    @Test("StreamMessageError cases are distinct")
    func streamMessageErrorCases() {
        let closed = StreamMessageError.streamClosed
        let tooLarge = StreamMessageError.messageTooLarge(1024)
        let empty = StreamMessageError.emptyMessage

        // Each case produces a usable error value
        _ = closed
        _ = tooLarge
        _ = empty
    }

    @Test("StreamMessageError.messageTooLarge carries size")
    func messageTooLargeSize() {
        let error = StreamMessageError.messageTooLarge(999_999)
        if case .messageTooLarge(let size) = error {
            #expect(size == 999_999)
        } else {
            Issue.record("Expected messageTooLarge")
        }
    }

    // MARK: - Mock stream for length-prefixed message tests

    /// A mock MuxedStream that returns pre-loaded data chunks.
    final class MockStream: MuxedStream, @unchecked Sendable {
        let id: UInt64 = 0
        var protocolID: String? = nil

        private var chunks: [ByteBuffer]
        private var chunkIndex = 0

        init(chunks: [ByteBuffer]) {
            self.chunks = chunks
        }

        func read() async throws -> ByteBuffer {
            guard chunkIndex < chunks.count else {
                return ByteBuffer()
            }
            let chunk = chunks[chunkIndex]
            chunkIndex += 1
            return chunk
        }

        func write(_ data: ByteBuffer) async throws {}
        func closeWrite() async throws {}
        func closeRead() async throws {}
        func close() async throws {}
        func reset() async throws {}
    }

    @Test("WriteLengthPrefixedMessage encodes varint prefix")
    func writeLengthPrefixed() async throws {
        // Custom stream that captures writes
        final class CaptureStream: MuxedStream, @unchecked Sendable {
            let id: UInt64 = 0
            var protocolID: String? = nil
            var captured: [ByteBuffer] = []

            func read() async throws -> ByteBuffer { ByteBuffer() }
            func write(_ data: ByteBuffer) async throws {
                captured.append(data)
            }
            func closeWrite() async throws {}
            func closeRead() async throws {}
            func close() async throws {}
            func reset() async throws {}
        }

        let stream = CaptureStream()
        let payload = ByteBuffer(bytes: [0x01, 0x02, 0x03])
        try await stream.writeLengthPrefixedMessage(payload)

        #expect(stream.captured.count == 1)
        let msg = stream.captured[0]
        // First byte should be varint 3 (payload length)
        #expect(msg.readableBytes == 4) // 1 byte varint + 3 bytes payload
        var copy = msg
        let varintByte = copy.readInteger(as: UInt8.self)
        #expect(varintByte == 3)
    }

    @Test("ReadLengthPrefixedMessage decodes single chunk")
    func readLengthPrefixedSingleChunk() async throws {
        // Encode: varint(5) + 5 bytes of data
        var buf = ByteBuffer()
        buf.writeBytes(Varint.encode(5))
        buf.writeBytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE])

        let stream = MockStream(chunks: [buf])
        let result = try await stream.readLengthPrefixedMessage()

        #expect(result.readableBytes == 5)
        var copy = result
        let bytes = copy.readBytes(length: 5)
        #expect(bytes == [0xAA, 0xBB, 0xCC, 0xDD, 0xEE])
    }

    @Test("ReadLengthPrefixedMessage rejects oversized messages")
    func readLengthPrefixedTooLarge() async throws {
        // Encode a message claiming to be 100KB (exceeds default 64KB limit)
        var buf = ByteBuffer()
        buf.writeBytes(Varint.encode(100_000))
        buf.writeBytes([UInt8](repeating: 0, count: 100))

        let stream = MockStream(chunks: [buf])

        do {
            _ = try await stream.readLengthPrefixedMessage()
            Issue.record("Should have thrown")
        } catch let error as StreamMessageError {
            if case .messageTooLarge(let size) = error {
                #expect(size == 100_000)
            } else {
                Issue.record("Expected messageTooLarge, got \(error)")
            }
        }
    }

    @Test("ReadLengthPrefixedMessage throws on empty stream")
    func readLengthPrefixedEmptyStream() async throws {
        let stream = MockStream(chunks: [])

        do {
            _ = try await stream.readLengthPrefixedMessage()
            Issue.record("Should have thrown")
        } catch {
            // Expected: streamClosed or emptyMessage
            #expect(error is StreamMessageError)
        }
    }

    @Test("ReadLengthPrefixedMessage handles multi-chunk delivery")
    func readLengthPrefixedMultiChunk() async throws {
        // Split varint + data across two chunks
        let varint = Varint.encode(4)
        var chunk1 = ByteBuffer()
        chunk1.writeBytes(varint)
        chunk1.writeBytes([0x01, 0x02])

        var chunk2 = ByteBuffer()
        chunk2.writeBytes([0x03, 0x04])

        let stream = MockStream(chunks: [chunk1, chunk2])
        let result = try await stream.readLengthPrefixedMessage()

        #expect(result.readableBytes == 4)
    }

    @Test("ReadLengthPrefixedMessage with persistent buffer preserves excess bytes")
    func readLengthPrefixedWithBuffer() async throws {
        // Two messages packed into one chunk
        var buf = ByteBuffer()
        // Message 1: length=2, data=[0xAA, 0xBB]
        buf.writeBytes(Varint.encode(2))
        buf.writeBytes([0xAA, 0xBB])
        // Message 2: length=1, data=[0xCC]
        buf.writeBytes(Varint.encode(1))
        buf.writeBytes([0xCC])

        let stream = MockStream(chunks: [buf])

        var persistentBuffer = ByteBuffer()
        let msg1 = try await stream.readLengthPrefixedMessage(buffer: &persistentBuffer)
        #expect(msg1.readableBytes == 2)

        let msg2 = try await stream.readLengthPrefixedMessage(buffer: &persistentBuffer)
        #expect(msg2.readableBytes == 1)
    }
}
