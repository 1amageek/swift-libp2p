/// MemoryChannel - Bidirectional in-memory data channel
///
/// Provides a pair of connected data streams for in-memory transport.

import Foundation
import Synchronization
import P2PCore

/// Errors that can occur with memory channels.
internal enum MemoryChannelError: Error, Sendable {
    /// Multiple concurrent reads are not supported.
    case concurrentReadNotSupported
}

/// A bidirectional in-memory channel connecting two endpoints.
///
/// This is used internally by MemoryConnection to transfer data
/// between two sides of an in-memory connection.
internal final class MemoryChannel: Sendable {

    /// The state for one direction of the channel.
    private struct DirectionState: Sendable {
        var buffer: [Data] = []
        var isClosed = false
        var waitingContinuation: CheckedContinuation<Data, any Error>?
    }

    /// State for A to B direction.
    private let aToBState: Mutex<DirectionState>

    /// State for B to A direction.
    private let bToAState: Mutex<DirectionState>

    /// Creates a new memory channel.
    init() {
        self.aToBState = Mutex(DirectionState())
        self.bToAState = Mutex(DirectionState())
    }

    // MARK: - A Side Operations

    /// Sends data from A to B.
    ///
    /// - Parameter data: The data to send
    /// - Returns: `true` if the data was sent, `false` if the channel is closed
    @discardableResult
    func sendFromA(_ data: Data) -> Bool {
        aToBState.withLock { state in
            if state.isClosed { return false }

            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(returning: data)
            } else {
                state.buffer.append(data)
            }
            return true
        }
    }

    /// Receives data at A (from B).
    ///
    /// - Throws: `MemoryChannelError.concurrentReadNotSupported` if another read is already waiting
    func receiveAtA() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            bToAState.withLock { state in
                if state.waitingContinuation != nil {
                    continuation.resume(throwing: MemoryChannelError.concurrentReadNotSupported)
                    return
                }

                if !state.buffer.isEmpty {
                    let data = state.buffer.removeFirst()
                    continuation.resume(returning: data)
                } else if state.isClosed {
                    continuation.resume(returning: Data())
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
    /// - Returns: `true` if the data was sent, `false` if the channel is closed
    @discardableResult
    func sendFromB(_ data: Data) -> Bool {
        bToAState.withLock { state in
            if state.isClosed { return false }

            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(returning: data)
            } else {
                state.buffer.append(data)
            }
            return true
        }
    }

    /// Receives data at B (from A).
    ///
    /// - Throws: `MemoryChannelError.concurrentReadNotSupported` if another read is already waiting
    func receiveAtB() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            aToBState.withLock { state in
                if state.waitingContinuation != nil {
                    continuation.resume(throwing: MemoryChannelError.concurrentReadNotSupported)
                    return
                }

                if !state.buffer.isEmpty {
                    let data = state.buffer.removeFirst()
                    continuation.resume(returning: data)
                } else if state.isClosed {
                    continuation.resume(returning: Data())
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
                continuation.resume(returning: Data())
            }
        }
    }

    /// Closes the B side (signals EOF to A).
    func closeB() {
        bToAState.withLock { state in
            state.isClosed = true
            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(returning: Data())
            }
        }
    }

    /// Closes both sides of the channel.
    func close() {
        closeA()
        closeB()
    }
}
