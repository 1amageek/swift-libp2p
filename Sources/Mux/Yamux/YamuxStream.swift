/// YamuxStream - MuxedStream implementation for Yamux
import Foundation
import NIOCore
import P2PCore
import P2PMux
import Synchronization

/// Internal state for YamuxStream.
///
/// Stream state model (bidirectional, independent):
/// ```
///        Local                      Remote
///     ┌──────────┐               ┌──────────┐
///     │  Write   │ ────FIN────>  │  Read    │
///     │  Side    │               │  Side    │
///     └──────────┘               └──────────┘
///
///     ┌──────────┐               ┌──────────┐
///     │  Read    │ <───FIN────   │  Write   │
///     │  Side    │               │  Side    │
///     └──────────┘               └──────────┘
/// ```
private struct YamuxStreamState: Sendable {
    /// Initial window size from configuration (immutable after creation)
    let initialWindowSize: UInt32
    var readBuffer: ByteBuffer = ByteBuffer()
    /// Queue of readers waiting for data (supports concurrent reads)
    var readContinuations: [CheckedContinuation<ByteBuffer, Error>] = []
    /// Queue of writers waiting for window space (supports concurrent writes)
    var windowWaitContinuations: [CheckedContinuation<Void, Error>] = []
    var sendWindow: UInt32

    // Write direction state
    /// Local has closed write side (sent FIN)
    var localWriteClosed = false

    // Read direction state
    /// Local has closed read side (no longer interested in receiving)
    var localReadClosed = false
    /// Remote has closed write side (received FIN, no more data coming)
    var remoteWriteClosed = false

    /// Stream has been reset (abrupt termination)
    var isReset = false
    var protocolID: String?

    init(initialWindowSize: UInt32) {
        self.initialWindowSize = initialWindowSize
        self.sendWindow = initialWindowSize
    }
}

/// A multiplexed stream over a Yamux connection.
public final class YamuxStream: MuxedStream, Sendable {

    public let id: UInt64
    public var protocolID: String? {
        get { state.withLock { $0.protocolID } }
        set { state.withLock { $0.protocolID = newValue } }
    }

    /// Stream ID as UInt32 for Yamux frame construction.
    /// Yamux spec uses 32-bit stream IDs; validated at init.
    private let yamuxStreamID: UInt32

    private let state: Mutex<YamuxStreamState>
    private let connection: YamuxConnection
    /// Per-stream flow controller for OnRead window updates and auto-tuning (B1/B2).
    private let flowController: FlowController

    init(id: UInt64, connection: YamuxConnection, initialWindowSize: UInt32 = yamuxDefaultWindowSize) {
        precondition(id <= UInt32.max, "Yamux stream IDs must fit in UInt32")
        self.id = id
        self.yamuxStreamID = UInt32(id)
        self.connection = connection
        self.state = Mutex(YamuxStreamState(initialWindowSize: initialWindowSize))
        self.flowController = FlowController(
            initialWindowSize: initialWindowSize,
            rtt: connection.rttEstimator,
            connectionWindowLimit: connection.configuration.maxAutoTuneWindow,
            autoTuneEnabled: connection.configuration.enableWindowAutoTuning
        )
    }

    public func read() async throws -> ByteBuffer {
        let data: ByteBuffer = try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                // Reset state - immediate failure
                if state.isReset {
                    continuation.resume(throwing: YamuxError.streamClosed)
                    return
                }

                // Local closed read side - immediate failure (we're not interested)
                if state.localReadClosed {
                    continuation.resume(throwing: YamuxError.streamClosed)
                    return
                }

                // Return buffered data if available
                if state.readBuffer.readableBytes > 0 {
                    let buffered = state.readBuffer
                    state.readBuffer = ByteBuffer()
                    continuation.resume(returning: buffered)
                } else if state.remoteWriteClosed {
                    // Remote closed write side and buffer is empty - no more data coming
                    continuation.resume(throwing: YamuxError.streamClosed)
                } else {
                    // Queue this reader to wait for data
                    state.readContinuations.append(continuation)
                }
            }
        }

        // OnRead mode (B2): send window update when data is consumed by the application
        let consumed = UInt32(data.readableBytes)
        if consumed > 0, let delta = flowController.dataConsumed(count: consumed) {
            Task { [connection, yamuxStreamID] in
                let frame = YamuxFrame.windowUpdate(streamID: yamuxStreamID, delta: delta)
                do {
                    try await connection.sendFrame(frame)
                } catch {
                    // Window update failed - connection likely closing
                }
            }
        }

        return data
    }

    /// Result of attempting to reserve send window space.
    private enum WindowReserveResult {
        /// Successfully reserved window space. Associated value is chunk size to send.
        case reserved(Int)
        /// No window available, need to wait for window update.
        case noWindow
        /// Stream is closed.
        case closed
    }

    public func write(_ data: ByteBuffer) async throws {
        let isClosed = state.withLock { state in state.localWriteClosed || state.isReset }
        if isClosed {
            throw YamuxError.streamClosed
        }

        // Send data in chunks based on available send window
        // Use index tracking to avoid O(n) copies on each iteration
        var offset = 0
        let dataCount = data.readableBytes

        while offset < dataCount {
            // Check for task cancellation
            try Task.checkCancellation()

            // Atomically check state, calculate chunk size, and reserve window space
            // This prevents TOCTOU race conditions with concurrent writes
            let reserveResult: WindowReserveResult = state.withLock { state in
                // Check if stream is closed for writing
                if state.localWriteClosed || state.isReset {
                    return .closed
                }

                // Check available window
                if state.sendWindow == 0 {
                    return .noWindow
                }

                // Calculate chunk size and reserve window atomically
                let remainingBytes = dataCount - offset
                let chunkSize = min(Int(state.sendWindow), remainingBytes)
                state.sendWindow -= UInt32(chunkSize)
                return .reserved(chunkSize)
            }

            switch reserveResult {
            case .reserved(let chunkSize):
                // Create Data slice only when sending
                let readerOffset = data.readerIndex + offset
                guard let chunk = data.getSlice(at: readerOffset, length: chunkSize) else {
                    throw YamuxError.protocolError("Buffer slice failed at offset \(readerOffset), length \(chunkSize)")
                }
                offset += chunkSize

                let frame = YamuxFrame.data(
                    streamID: yamuxStreamID,
                    data: chunk
                )
                try await connection.sendFrame(frame)

            case .closed:
                throw YamuxError.streamClosed

            case .noWindow:
                // Wait for window update using async signaling (no polling)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    // Wait for window update signal
                    group.addTask {
                        try await withCheckedThrowingContinuation { continuation in
                            let shouldResume = self.state.withLock { state -> Bool in
                                if state.localWriteClosed || state.isReset {
                                    continuation.resume(throwing: YamuxError.streamClosed)
                                    return true
                                }
                                if state.sendWindow > 0 {
                                    // Window already available
                                    continuation.resume()
                                    return true
                                }
                                // Queue this writer to wait for window space
                                state.windowWaitContinuations.append(continuation)
                                return false
                            }
                            // If already resumed, nothing to do
                            _ = shouldResume
                        }
                    }

                    // Add timeout task
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        throw YamuxError.protocolError("Write timeout: no window update received")
                    }

                    // Wait for first to complete (either window update or timeout)
                    try await group.next()
                    group.cancelAll()
                }
            }
        }
    }

    public func closeWrite() async throws {
        let (shouldSend, windowConts) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Error>]) in
            if state.localWriteClosed || state.isReset { return (false, []) }
            state.localWriteClosed = true
            // Cancel any pending writers waiting for window space
            let w = state.windowWaitContinuations
            state.windowWaitContinuations = []
            return (true, w)
        }

        // Resume all waiting writers with error (outside lock)
        for cont in windowConts {
            cont.resume(throwing: YamuxError.streamClosed)
        }

        if shouldSend {
            let frame = YamuxFrame(
                type: .data,
                flags: .fin,
                streamID: yamuxStreamID,
                length: 0,
                data: nil
            )
            try await connection.sendFrame(frame)
        }
    }

    public func closeRead() async throws {
        // Yamux doesn't have an explicit "stop receiving" signal like QUIC's STOP_SENDING.
        // We mark the read side as closed locally, which will cause subsequent reads to fail.
        // The peer will continue sending until their window is exhausted or they close.
        // Received data after closeRead() will be discarded in dataReceived().
        let readConts = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
            if state.localReadClosed || state.isReset { return [] }
            state.localReadClosed = true
            // Clear buffer - we're no longer interested in any data
            state.readBuffer = ByteBuffer()
            let r = state.readContinuations
            state.readContinuations = []
            return r
        }
        // Resume all waiting readers with error
        for cont in readConts {
            cont.resume(throwing: YamuxError.streamClosed)
        }
    }

    public func close() async throws {
        // Close both directions - ensure closeRead runs even if closeWrite fails
        // (e.g. when connection is already closed, FIN send fails but we still
        // need to cancel read continuations to prevent hangs)
        var writeError: (any Error)?
        do {
            try await closeWrite()
        } catch {
            writeError = error
        }
        try await closeRead()
        connection.removeStream(id)
        if let writeError { throw writeError }
    }

    public func reset() async throws {
        let (readConts, windowConts) = state.withLock { state -> ([CheckedContinuation<ByteBuffer, Error>], [CheckedContinuation<Void, Error>]) in
            state.isReset = true
            state.localWriteClosed = true
            state.localReadClosed = true
            state.remoteWriteClosed = true
            state.readBuffer = ByteBuffer()
            let r = state.readContinuations
            let w = state.windowWaitContinuations
            state.readContinuations = []
            state.windowWaitContinuations = []
            return (r, w)
        }
        // Resume all waiting continuations outside of lock to avoid deadlock
        for cont in readConts {
            cont.resume(throwing: YamuxError.streamClosed)
        }
        for cont in windowConts {
            cont.resume(throwing: YamuxError.streamClosed)
        }

        let frame = YamuxFrame(
            type: .data,
            flags: .rst,
            streamID: yamuxStreamID,
            length: 0,
            data: nil
        )
        try await connection.sendFrame(frame)
        connection.removeStream(id)
    }

    // MARK: - Internal

    /// Called when data is received for this stream.
    ///
    /// Uses FlowController for window management (B1/B2).
    /// In OnRead mode, window updates are NOT sent here — they are sent
    /// when the application calls read() and consumes the data.
    ///
    /// - Returns: `true` if the data was accepted, `false` if it exceeded
    ///   the receive window (protocol violation).
    func dataReceived(_ data: ByteBuffer) -> Bool {
        enum DataReceivedResult {
            case accepted(continuation: CheckedContinuation<ByteBuffer, Error>?)
            case discarded  // localReadClosed - data discarded
            case windowViolation(errorConts: [CheckedContinuation<ByteBuffer, Error>])
        }

        // Guard against data exceeding UInt32 range (Yamux uses 32-bit lengths)
        guard data.readableBytes <= UInt32.max else {
            let errorConts = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
                state.isReset = true
                state.localWriteClosed = true
                state.localReadClosed = true
                state.remoteWriteClosed = true
                let conts = state.readContinuations
                state.readContinuations = []
                return conts
            }
            for cont in errorConts {
                cont.resume(throwing: YamuxError.windowExceeded)
            }
            return false
        }
        let dataSize = UInt32(data.readableBytes)

        // Check receive window via FlowController (B1/B2)
        guard flowController.dataReceived(count: dataSize) else {
            let errorConts = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
                state.isReset = true
                state.localWriteClosed = true
                state.localReadClosed = true
                state.remoteWriteClosed = true
                let conts = state.readContinuations
                state.readContinuations = []
                return conts
            }
            for cont in errorConts {
                cont.resume(throwing: YamuxError.windowExceeded)
            }
            return false
        }

        let result: DataReceivedResult = state.withLock { state in
            // If local read is closed, discard the data
            if state.localReadClosed {
                return .discarded
            }

            // Normal case: deliver to waiting reader or buffer
            if !state.readContinuations.isEmpty {
                let cont = state.readContinuations.removeFirst()
                return .accepted(continuation: cont)
            } else {
                var mutableData = data
                state.readBuffer.writeBuffer(&mutableData)
                return .accepted(continuation: nil)
            }
        }

        // Process result outside of lock
        switch result {
        case .windowViolation:
            // Already handled above, should not reach here
            return false

        case .discarded:
            return true

        case .accepted(let continuation):
            continuation?.resume(returning: data)
            // No window update here — OnRead mode sends updates in read()
            return true
        }
    }

    /// Called when remote closes the stream (received FIN).
    ///
    /// This is a half-close: remote stopped sending, but we can still write.
    /// Only read waiters are cancelled; write waiters continue normally.
    func remoteClose() {
        let readConts = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
            state.remoteWriteClosed = true
            // Only cancel read waiters - write side is unaffected (half-close)
            let r = state.readContinuations
            state.readContinuations = []
            return r
            // Note: windowWaitContinuations NOT touched - we can still write!
        }
        // Resume read waiters outside of lock
        for cont in readConts {
            cont.resume(throwing: YamuxError.streamClosed)
        }
    }

    /// Called when the stream is reset by remote (received RST).
    ///
    /// This is an abrupt close: both directions are immediately terminated.
    func remoteReset() {
        let (readConts, windowConts) = state.withLock { state -> ([CheckedContinuation<ByteBuffer, Error>], [CheckedContinuation<Void, Error>]) in
            state.isReset = true
            state.localWriteClosed = true
            state.localReadClosed = true
            state.remoteWriteClosed = true
            state.readBuffer = ByteBuffer()
            let r = state.readContinuations
            let w = state.windowWaitContinuations
            state.readContinuations = []
            state.windowWaitContinuations = []
            return (r, w)
        }
        // Resume all waiting continuations outside of lock to avoid deadlock
        for cont in readConts {
            cont.resume(throwing: YamuxError.streamClosed)
        }
        for cont in windowConts {
            cont.resume(throwing: YamuxError.streamClosed)
        }
    }

    /// Called when a window update is received.
    func windowUpdate(delta: UInt32) {
        let continuations = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            // Overflow protection: use UInt64 for arithmetic, cap at max window size
            let newWindow = UInt64(state.sendWindow) + UInt64(delta)
            state.sendWindow = UInt32(min(newWindow, UInt64(yamuxMaxWindowSize)))

            let conts = state.windowWaitContinuations
            state.windowWaitContinuations = []
            return conts
        }
        // Resume all waiting writers outside of lock to avoid deadlock
        for cont in continuations {
            cont.resume()
        }
    }
}
