/// WebRTC Muxed Stream
///
/// Wraps a WebRTC data channel as a MuxedStream for libp2p.

import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PTransport
import P2PMux
import WebRTC
import DataChannel

/// A WebRTC data channel that conforms to MuxedStream.
///
/// Closing a stream is local-only: the underlying SCTP stream stays open
/// because DCEP has no close message and SCTP stream reset (RFC 6525) is
/// not implemented by the WebRTC layer. The peer learns about closure at
/// the application protocol level.
public final class WebRTCMuxedStream: MuxedStream, Sendable {

    public let id: UInt64
    public let protocolID: String?

    /// The underlying data channel ID (SCTP stream ID).
    let channelID: UInt16

    /// Cap on bytes buffered ahead of `read()` calls. A peer that keeps
    /// sending while the application does not read is violating
    /// application-level flow control; the stream fails instead of
    /// growing without bound.
    private static let maxReadBufferBytes = 1 << 20

    private let connection: WebRTCConnection

    /// Invoked exactly once when the stream terminates (close/reset/failure)
    /// so the owning connection can drop its bookkeeping entries.
    private let onTerminate: @Sendable (UInt64, UInt16) -> Void

    private let streamState: Mutex<StreamState>

    private struct StreamState: Sendable {
        var readBuffer: [ByteBuffer] = []
        var readBufferedBytes: Int = 0
        var readWaiters: [(id: UInt64, continuation: CheckedContinuation<ByteBuffer, Error>)] = []
        var nextWaiterID: UInt64 = 0
        var isReadClosed: Bool = false
        var isWriteClosed: Bool = false
        /// Terminal failure delivered to current and future reads/writes.
        var failure: Error?
        var didTerminate: Bool = false
    }

    init(
        id: UInt64,
        channel: DataChannel,
        connection: WebRTCConnection,
        protocolID: String?,
        onTerminate: @escaping @Sendable (UInt64, UInt16) -> Void = { _, _ in }
    ) {
        self.id = id
        self.channelID = channel.id
        self.connection = connection
        self.protocolID = protocolID
        self.onTerminate = onTerminate
        self.streamState = Mutex(StreamState())
    }

    // MARK: - MuxedStream

    /// Reads data from the data channel.
    ///
    /// Supports task cancellation: a cancelled read resumes with
    /// `CancellationError` without disturbing other waiters.
    public func read() async throws -> ByteBuffer {
        let waiterID = streamState.withLock { s -> UInt64 in
            let id = s.nextWaiterID
            s.nextWaiterID += 1
            return id
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enum ReadResult {
                    case data(ByteBuffer)
                    case failed(Error)
                    case waiting
                }

                let result = streamState.withLock { s -> ReadResult in
                    if !s.readBuffer.isEmpty {
                        let buffer = s.readBuffer.removeFirst()
                        s.readBufferedBytes -= buffer.readableBytes
                        return .data(buffer)
                    }
                    if let failure = s.failure {
                        return .failed(failure)
                    }
                    if s.isReadClosed {
                        return .failed(WebRTCStreamError.streamClosed)
                    }
                    // A task cancelled before the waiter is registered has
                    // already run its onCancel handler against an empty
                    // waiter list — fail here instead of waiting forever
                    if Task.isCancelled {
                        return .failed(CancellationError())
                    }
                    s.readWaiters.append((id: waiterID, continuation: continuation))
                    return .waiting
                }

                switch result {
                case .data(let data):
                    continuation.resume(returning: data)
                case .failed(let error):
                    continuation.resume(throwing: error)
                case .waiting:
                    // Resume responsibility delegated to deliver(),
                    // closeRead(), fail(), or the cancellation handler
                    break
                }
            }
        } onCancel: {
            let waiter = streamState.withLock { s -> CheckedContinuation<ByteBuffer, Error>? in
                guard let index = s.readWaiters.firstIndex(where: { $0.id == waiterID }) else {
                    return nil
                }
                return s.readWaiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Writes data to the data channel.
    public func write(_ data: ByteBuffer) async throws {
        let failure = streamState.withLock { s -> Error? in
            if let failure = s.failure { return failure }
            if s.isWriteClosed { return WebRTCStreamError.streamClosed }
            return nil
        }
        if let failure {
            throw failure
        }
        do {
            try connection.send(Data(buffer: data), on: channelID, binary: true)
        } catch {
            // A send failure means the connection is unusable for this
            // stream — surface it as a transport-level closure
            throw TransportError.connectionFailed(underlying: error)
        }
    }

    /// Half-close for writing.
    public func closeWrite() async throws {
        streamState.withLock { $0.isWriteClosed = true }
    }

    /// Half-close for reading.
    public func closeRead() async throws {
        let waiters = streamState.withLock { s -> [CheckedContinuation<ByteBuffer, Error>] in
            s.isReadClosed = true
            let w = s.readWaiters.map(\.continuation)
            s.readWaiters.removeAll()
            s.readBuffer.removeAll()
            s.readBufferedBytes = 0
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
        terminateIfNeeded()
    }

    /// Abrupt close. Local-only, like `close()` — see the type-level note.
    public func reset() async throws {
        try await close()
    }

    // MARK: - Internal

    /// Deliver data received from the WebRTC connection.
    ///
    /// Data arriving after `closeRead()` is dropped — the local reader
    /// explicitly relinquished interest. Exceeding the read-buffer cap
    /// fails the stream instead of dropping data silently.
    func deliver(_ data: Data) {
        enum DeliverAction {
            case resume(CheckedContinuation<ByteBuffer, Error>)
            case buffered
            case dropped
            case overflow
        }

        let action = streamState.withLock { s -> DeliverAction in
            if s.isReadClosed || s.failure != nil {
                return .dropped
            }
            if !s.readWaiters.isEmpty {
                return .resume(s.readWaiters.removeFirst().continuation)
            }
            if s.readBufferedBytes + data.count > Self.maxReadBufferBytes {
                return .overflow
            }
            s.readBuffer.append(ByteBuffer(bytes: data))
            s.readBufferedBytes += data.count
            return .buffered
        }

        switch action {
        case .resume(let waiter):
            waiter.resume(returning: ByteBuffer(bytes: data))
        case .buffered, .dropped:
            break
        case .overflow:
            fail(WebRTCStreamError.receiveBufferExceeded(limit: Self.maxReadBufferBytes))
        }
    }

    /// Terminate the stream with an error. Pending and future reads and
    /// writes surface the error. Used when the parent connection fails.
    func fail(_ error: Error) {
        let waiters = streamState.withLock { s -> [CheckedContinuation<ByteBuffer, Error>] in
            guard s.failure == nil else { return [] }
            s.failure = error
            s.isReadClosed = true
            s.isWriteClosed = true
            s.readBuffer.removeAll()
            s.readBufferedBytes = 0
            let w = s.readWaiters.map(\.continuation)
            s.readWaiters.removeAll()
            return w
        }
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
        terminateIfNeeded()
    }

    /// Invoke the termination callback exactly once.
    private func terminateIfNeeded() {
        let shouldNotify = streamState.withLock { s -> Bool in
            if s.didTerminate { return false }
            s.didTerminate = true
            return true
        }
        if shouldNotify {
            onTerminate(id, channelID)
        }
    }
}

/// Errors for WebRTC stream operations.
public enum WebRTCStreamError: Error, Sendable {
    case streamClosed
    /// The peer sent more data than the local reader consumed, exceeding
    /// the per-stream read buffer cap.
    case receiveBufferExceeded(limit: Int)
}
