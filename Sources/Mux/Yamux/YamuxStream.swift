/// YamuxStream - MuxedStream implementation for Yamux
import Foundation
import P2PCore
import P2PMux
import Synchronization

/// Internal state for YamuxStream.
private struct YamuxStreamState: Sendable {
    /// Initial window size from configuration (immutable after creation)
    let initialWindowSize: UInt32
    var readBuffer: Data = Data()
    /// Queue of readers waiting for data (supports concurrent reads)
    var readContinuations: [CheckedContinuation<Data, Error>] = []
    /// Queue of writers waiting for window space (supports concurrent writes)
    var windowWaitContinuations: [CheckedContinuation<Void, Error>] = []
    var sendWindow: UInt32
    var recvWindow: UInt32
    var localClosed = false
    var remoteClosed = false
    var isReset = false
    var protocolID: String?

    init(initialWindowSize: UInt32) {
        self.initialWindowSize = initialWindowSize
        self.sendWindow = initialWindowSize
        self.recvWindow = initialWindowSize
    }
}

/// A multiplexed stream over a Yamux connection.
public final class YamuxStream: MuxedStream, Sendable {

    public let id: UInt64
    public var protocolID: String? {
        get { state.withLock { $0.protocolID } }
        set { state.withLock { $0.protocolID = newValue } }
    }

    private let state: Mutex<YamuxStreamState>
    private let connection: YamuxConnection

    init(id: UInt64, connection: YamuxConnection, initialWindowSize: UInt32 = yamuxDefaultWindowSize) {
        self.id = id
        self.connection = connection
        self.state = Mutex(YamuxStreamState(initialWindowSize: initialWindowSize))
    }

    public func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if state.isReset {
                    continuation.resume(throwing: YamuxError.streamClosed)
                    return
                }

                if !state.readBuffer.isEmpty {
                    let data = state.readBuffer
                    state.readBuffer = Data()
                    continuation.resume(returning: data)
                } else if state.remoteClosed {
                    continuation.resume(throwing: YamuxError.streamClosed)
                } else {
                    // Queue this reader to wait for data
                    state.readContinuations.append(continuation)
                }
            }
        }
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

    public func write(_ data: Data) async throws {
        let isClosed = state.withLock { state in state.localClosed || state.isReset }
        if isClosed {
            throw YamuxError.streamClosed
        }

        // Send data in chunks based on available send window
        // Use index tracking to avoid O(n) copies on each iteration
        var offset = 0
        let dataCount = data.count

        while offset < dataCount {
            // Check for task cancellation
            try Task.checkCancellation()

            // Atomically check state, calculate chunk size, and reserve window space
            // This prevents TOCTOU race conditions with concurrent writes
            let reserveResult: WindowReserveResult = state.withLock { state in
                // Check if stream is closed
                if state.localClosed || state.isReset {
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
                // Create Data slice only when sending (single copy for the frame)
                let chunk = Data(data[offset..<(offset + chunkSize)])
                offset += chunkSize

                let frame = YamuxFrame.data(
                    streamID: UInt32(id),
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
                                if state.localClosed || state.isReset {
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
        let shouldSend = state.withLock { state -> Bool in
            if state.localClosed || state.isReset { return false }
            state.localClosed = true
            return true
        }

        if shouldSend {
            let frame = YamuxFrame(
                type: .data,
                flags: .fin,
                streamID: UInt32(id),
                length: 0,
                data: nil
            )
            try await connection.sendFrame(frame)
        }
    }

    public func close() async throws {
        try await closeWrite()
        let (readConts, windowConts) = state.withLock { state -> ([CheckedContinuation<Data, Error>], [CheckedContinuation<Void, Error>]) in
            state.remoteClosed = true
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
        connection.removeStream(id)
    }

    public func reset() async throws {
        let (readConts, windowConts) = state.withLock { state -> ([CheckedContinuation<Data, Error>], [CheckedContinuation<Void, Error>]) in
            state.isReset = true
            state.localClosed = true
            state.remoteClosed = true
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
            streamID: UInt32(id),
            length: 0,
            data: nil
        )
        try await connection.sendFrame(frame)
        connection.removeStream(id)
    }

    // MARK: - Internal

    /// Called when data is received for this stream.
    ///
    /// - Returns: `true` if the data was accepted, `false` if it exceeded
    ///   the receive window (protocol violation).
    func dataReceived(_ data: Data) -> Bool {
        let (accepted, continuation, errorConts) = state.withLock { state -> (Bool, CheckedContinuation<Data, Error>?, [CheckedContinuation<Data, Error>]) in
            // Check for receive window violation
            let dataSize = UInt32(data.count)
            if dataSize > state.recvWindow {
                // Protocol violation: data exceeds receive window
                state.isReset = true
                state.localClosed = true
                state.remoteClosed = true
                let conts = state.readContinuations
                state.readContinuations = []
                return (false, nil, conts)
            }

            // Update receive window
            state.recvWindow -= dataSize

            if !state.readContinuations.isEmpty {
                // Resume first waiting reader (FIFO)
                let cont = state.readContinuations.removeFirst()
                return (true, cont, [])
            } else {
                state.readBuffer.append(data)
                return (true, nil, [])
            }
        }

        // Resume continuations outside of lock to avoid deadlock
        if !accepted {
            for cont in errorConts {
                cont.resume(throwing: YamuxError.windowExceeded)
            }
            return false
        }

        continuation?.resume(returning: data)

        // Send window update if needed
        // Only calculate delta, don't update window yet (will update after successful send)
        let (needsUpdate, delta) = state.withLock { state -> (Bool, UInt32) in
            if state.recvWindow < state.initialWindowSize / 2 {
                let d = state.initialWindowSize - state.recvWindow
                return (true, d)
            }
            return (false, 0)
        }

        if needsUpdate {
            Task { [weak self, connection, id] in
                let frame = YamuxFrame.windowUpdate(streamID: UInt32(id), delta: delta)
                do {
                    try await connection.sendFrame(frame)
                    // Only update window AFTER successful send
                    self?.state.withLock { state in
                        state.recvWindow += delta
                    }
                } catch {
                    // Window update failed - don't update local window
                    // Peer will continue respecting old window
                    // Connection is likely closing
                }
            }
        }

        return true
    }

    /// Called when remote closes the stream.
    func remoteClose() {
        let (readConts, windowConts) = state.withLock { state -> ([CheckedContinuation<Data, Error>], [CheckedContinuation<Void, Error>]) in
            state.remoteClosed = true
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

    /// Called when the stream is reset by remote.
    func remoteReset() {
        let (readConts, windowConts) = state.withLock { state -> ([CheckedContinuation<Data, Error>], [CheckedContinuation<Void, Error>]) in
            state.isReset = true
            state.localClosed = true
            state.remoteClosed = true
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
