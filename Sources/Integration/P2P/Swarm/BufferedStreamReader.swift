import Synchronization
import P2PCore
import P2PMux

/// A helper for reading length-prefixed messages from a stream while preserving any unread remainder.
internal final class BufferedStreamReader: Sendable {
    private let stream: MuxedStream
    private let state: Mutex<ByteBuffer>
    private let maxMessageSize: Int

    /// Maximum buffer size to prevent DoS (default 64KB for multistream-select).
    static let defaultMaxMessageSize = 64 * 1024

    init(stream: MuxedStream, maxMessageSize: Int = defaultMaxMessageSize) {
        self.stream = stream
        self.state = Mutex(ByteBuffer())
        self.maxMessageSize = maxMessageSize
    }

    /// Returns and clears any bytes buffered beyond consumed negotiation messages.
    func drainRemainder() -> ByteBuffer {
        state.withLock { buffer in
            let remainder = buffer
            buffer.clear()
            return remainder
        }
    }

    private enum ExtractResult {
        case message(ByteBuffer)
        case needMoreData
        case invalidData(Error)
    }

    func readMessage() async throws -> ByteBuffer {
        while true {
            let result: ExtractResult = state.withLock { buffer in
                guard buffer.readableBytes > 0 else { return .needMoreData }

                do {
                    let (length, lengthBytes) = try buffer.withUnsafeReadableBytes { ptr in
                        try Varint.decode(from: UnsafeRawBufferPointer(ptr), at: 0)
                    }

                    guard length <= UInt64(maxMessageSize) else {
                        return .invalidData(NodeError.messageTooLarge(
                            size: Int(min(length, UInt64(Int.max))),
                            max: maxMessageSize
                        ))
                    }
                    let messageLength = Int(length)
                    let totalNeeded = lengthBytes + messageLength

                    guard buffer.readableBytes >= totalNeeded else {
                        return .needMoreData
                    }

                    guard let message = buffer.readSlice(length: totalNeeded) else {
                        return .needMoreData
                    }
                    return .message(message)
                } catch let error as VarintError {
                    switch error {
                    case .insufficientData:
                        return .needMoreData
                    case .overflow, .valueExceedsIntMax:
                        return .invalidData(error)
                    }
                } catch {
                    return .invalidData(error)
                }
            }

            switch result {
            case .message(let message):
                return message
            case .needMoreData:
                break
            case .invalidData(let error):
                throw error
            }

            let currentSize = state.withLock { $0.readableBytes }
            if currentSize > maxMessageSize {
                throw NodeError.messageTooLarge(size: currentSize, max: maxMessageSize)
            }

            let chunk = try await stream.read()
            if chunk.readableBytes == 0 {
                throw NodeError.streamClosed
            }

            state.withLock { buffer in
                var mutableChunk = chunk
                buffer.writeBuffer(&mutableChunk)
            }
        }
    }
}
