import Synchronization
import P2PCore
import P2PMux

/// A stream wrapper that returns pre-buffered bytes before reading the underlying stream.
internal final class BufferedMuxedStream: MuxedStream, Sendable {
    private let stream: MuxedStream
    private let buffer: Mutex<ByteBuffer>

    var id: UInt64 { stream.id }
    var protocolID: String? { stream.protocolID }

    init(stream: MuxedStream, initialBuffer: Data = Data()) {
        self.stream = stream
        self.buffer = Mutex(ByteBuffer(bytes: initialBuffer))
    }

    func read() async throws -> ByteBuffer {
        let buffered = buffer.withLock { buffer -> ByteBuffer? in
            guard buffer.readableBytes > 0 else { return nil }
            let data = buffer
            buffer = ByteBuffer()
            return data
        }

        if let buffered {
            return buffered
        }
        return try await stream.read()
    }

    func write(_ data: ByteBuffer) async throws {
        try await stream.write(data)
    }

    func closeWrite() async throws {
        try await stream.closeWrite()
    }

    func closeRead() async throws {
        try await stream.closeRead()
    }

    func close() async throws {
        try await stream.close()
    }

    func reset() async throws {
        try await stream.reset()
    }
}
