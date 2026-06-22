/// MemoryChannel - Bidirectional in-memory data channel
///
/// Provides a pair of connected data streams for in-memory transport.

import Foundation
import NIOCore
import Synchronization
import P2PCore

/// Errors that can occur with memory channels.
internal enum MemoryChannelError: Error, Sendable {
    /// Multiple concurrent reads are not supported.
    case concurrentReadNotSupported
}

/// Outcome of a send operation on a memory channel direction.
internal enum MemorySendResult: Sendable {
    /// Data was delivered to a waiting reader or buffered.
    case accepted
    /// The direction is closed; the data was rejected.
    case closed
    /// The per-direction buffer is full; the data was rejected (backpressure).
    case bufferFull
}

/// Default maximum bytes buffered per direction when no reader is waiting.
///
/// Bounds memory a sender can pin by writing without the peer reading,
/// mirroring TCP's `tcpMaxReadBufferSize` DoS protection. 1MB.
internal let memoryChannelMaxBufferedBytes = 1024 * 1024

/// A bidirectional in-memory channel connecting two endpoints.
///
/// This is used internally by MemoryConnection to transfer data
/// between two sides of an in-memory connection.
internal final class MemoryChannel: Sendable {

    /// The state for one direction of the channel.
    private struct DirectionState: Sendable {
        var buffer: [ByteBuffer] = []
        /// Sum of `readableBytes` across `buffer` (kept in sync on append/remove)
        /// to bound buffered memory without re-summing the queue each send.
        var bufferedBytes = 0
        var isClosed = false
        var waitingContinuation: CheckedContinuation<ByteBuffer, any Error>?
    }

    /// State for A to B direction.
    private let aToBState: Mutex<DirectionState>

    /// State for B to A direction.
    private let bToAState: Mutex<DirectionState>

    /// Maximum bytes buffered per direction when no reader is waiting.
    private let maxBufferedBytes: Int

    /// Creates a new memory channel.
    ///
    /// - Parameter maxBufferedBytes: Per-direction buffer cap (DoS protection).
    init(maxBufferedBytes: Int = memoryChannelMaxBufferedBytes) {
        self.maxBufferedBytes = maxBufferedBytes
        self.aToBState = Mutex(DirectionState())
        self.bToAState = Mutex(DirectionState())
    }

    // MARK: - A Side Operations

    /// Sends data from A to B.
    ///
    /// - Parameter data: The data to send
    /// - Returns: `.accepted` if delivered/buffered, `.closed` if the direction
    ///   is closed, or `.bufferFull` if the per-direction buffer cap is reached.
    func sendFromA(_ data: ByteBuffer) -> MemorySendResult {
        aToBState.withLock { state in
            send(&state, data)
        }
    }

    /// Receives data at A (from B).
    ///
    /// - Throws: `MemoryChannelError.concurrentReadNotSupported` if another read is already waiting
    func receiveAtA() async throws -> ByteBuffer {
        try await withCheckedThrowingContinuation { continuation in
            bToAState.withLock { state in
                if state.waitingContinuation != nil {
                    continuation.resume(throwing: MemoryChannelError.concurrentReadNotSupported)
                    return
                }

                if !state.buffer.isEmpty {
                    let data = state.buffer.removeFirst()
                    state.bufferedBytes -= data.readableBytes
                    continuation.resume(returning: data)
                } else if state.isClosed {
                    continuation.resume(returning: ByteBuffer())
                } else {
                    state.waitingContinuation = continuation
                }
            }
        }
    }

    // MARK: - B Side Operations

    /// Sends data from B to A.
    ///
    /// - Parameter data: The data to send
    /// - Returns: `.accepted` if delivered/buffered, `.closed` if the direction
    ///   is closed, or `.bufferFull` if the per-direction buffer cap is reached.
    func sendFromB(_ data: ByteBuffer) -> MemorySendResult {
        bToAState.withLock { state in
            send(&state, data)
        }
    }

    /// Shared send logic for one direction. Must be called while holding the
    /// direction's lock.
    private func send(_ state: inout DirectionState, _ data: ByteBuffer) -> MemorySendResult {
        if state.isClosed { return .closed }

        if let continuation = state.waitingContinuation {
            state.waitingContinuation = nil
            continuation.resume(returning: data)
            return .accepted
        }

        // No reader waiting: bound the buffer to prevent memory-exhaustion DoS.
        // Always admit the first message so a single oversized write is not
        // permanently stuck, but reject once the cap is reached.
        if !state.buffer.isEmpty && state.bufferedBytes + data.readableBytes > maxBufferedBytes {
            return .bufferFull
        }
        state.bufferedBytes += data.readableBytes
        state.buffer.append(data)
        return .accepted
    }

    /// Receives data at B (from A).
    ///
    /// - Throws: `MemoryChannelError.concurrentReadNotSupported` if another read is already waiting
    func receiveAtB() async throws -> ByteBuffer {
        try await withCheckedThrowingContinuation { continuation in
            aToBState.withLock { state in
                if state.waitingContinuation != nil {
                    continuation.resume(throwing: MemoryChannelError.concurrentReadNotSupported)
                    return
                }

                if !state.buffer.isEmpty {
                    let data = state.buffer.removeFirst()
                    state.bufferedBytes -= data.readableBytes
                    continuation.resume(returning: data)
                } else if state.isClosed {
                    continuation.resume(returning: ByteBuffer())
                } else {
                    state.waitingContinuation = continuation
                }
            }
        }
    }

    // MARK: - Close Operations

    /// Closes the A side (signals EOF to B).
    func closeA() {
        aToBState.withLock { state in
            state.isClosed = true
            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(returning: ByteBuffer())
            }
        }
    }

    /// Closes the B side (signals EOF to A).
    func closeB() {
        bToAState.withLock { state in
            state.isClosed = true
            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(returning: ByteBuffer())
            }
        }
    }

    /// Closes both sides of the channel.
    func close() {
        closeA()
        closeB()
    }
}
