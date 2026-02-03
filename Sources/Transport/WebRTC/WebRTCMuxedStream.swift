/// WebRTC Muxed Stream
///
/// Wraps a WebRTC data channel as a MuxedStream for libp2p.

import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PMux
import WebRTC
import DataChannel

/// A WebRTC data channel that conforms to MuxedStream.
public final class WebRTCMuxedStream: MuxedStream, Sendable {

    public let id: UInt64
    public let protocolID: String?

    /// The underlying data channel ID (SCTP stream ID).
    let channelID: UInt16

    private let connection: WebRTCConnection
    private let streamState: Mutex<StreamState>

    private struct StreamState: Sendable {
        var readBuffer: [ByteBuffer] = []
        var readWaiters: [CheckedContinuation<ByteBuffer, Error>] = []
        var isReadClosed: Bool = false
        var isWriteClosed: Bool = false
    }

    init(
        id: UInt64,
        channel: DataChannel,
        connection: WebRTCConnection,
        protocolID: String?
    ) {
        self.id = id
        self.channelID = channel.id
        self.connection = connection
        self.protocolID = protocolID
        self.streamState = Mutex(StreamState())
    }

    // MARK: - MuxedStream

    /// Reads data from the data channel.
    public func read() async throws -> ByteBuffer {
        try await withCheckedThrowingContinuation { continuation in
            enum ReadResult {
                case data(ByteBuffer)
                case closed
                case waiting
            }

            let result = streamState.withLock { s -> ReadResult in
                if !s.readBuffer.isEmpty {
                    return .data(s.readBuffer.removeFirst())
                }
                if s.isReadClosed {
                    return .closed
                }
                s.readWaiters.append(continuation)
                return .waiting
            }

            switch result {
            case .data(let data):
                continuation.resume(returning: data)
            case .closed:
                continuation.resume(throwing: WebRTCStreamError.streamClosed)
            case .waiting:
                // Resume responsibility delegated to deliver() or closeRead()
                break
            }
        }
    }

    /// Writes data to the data channel.
    public func write(_ data: ByteBuffer) async throws {
        let isClosed = streamState.withLock { $0.isWriteClosed }
        guard !isClosed else {
            throw WebRTCStreamError.streamClosed
        }
        try connection.send(Data(buffer: data), on: channelID, binary: true)
    }

    /// Half-close for writing.
    public func closeWrite() async throws {
        streamState.withLock { $0.isWriteClosed = true }
    }

    /// Half-close for reading.
    public func closeRead() async throws {
        let waiters = streamState.withLock { s -> [CheckedContinuation<ByteBuffer, Error>] in
            s.isReadClosed = true
            let w = s.readWaiters
            s.readWaiters.removeAll()
            return w
        }
        for waiter in waiters {
            waiter.resume(throwing: WebRTCStreamError.streamClosed)
        }
    }

    /// Graceful close (both read and write).
    public func close() async throws {
        try await closeRead()
        try await closeWrite()
    }

    /// Abrupt close.
    public func reset() async throws {
        try await close()
    }

    // MARK: - Internal

    /// Deliver data received from the WebRTC connection.
    func deliver(_ data: Data) {
        let waiter = streamState.withLock { s -> CheckedContinuation<ByteBuffer, Error>? in
            if !s.readWaiters.isEmpty {
                return s.readWaiters.removeFirst()
            }
            s.readBuffer.append(ByteBuffer(bytes: data))
            return nil
        }
        waiter?.resume(returning: ByteBuffer(bytes: data))
    }
}

/// Errors for WebRTC stream operations.
public enum WebRTCStreamError: Error, Sendable {
    case streamClosed
}
