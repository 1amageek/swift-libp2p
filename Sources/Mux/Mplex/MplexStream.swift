/// MplexStream - MuxedStream implementation for Mplex
import Foundation
import NIOCore
import P2PCore
import P2PMux
import Synchronization

private let logger = Logger(label: "p2p.mux.mplex.stream")

/// Internal state for MplexStream.
///
/// Stream state model (bidirectional, independent):
/// ```
///        Local                      Remote
///     +-----------+               +-----------+
///     |  Write    | ----CLOSE---> |  Read     |
///     |  Side     |               |  Side     |
///     +-----------+               +-----------+
///
///     +-----------+               +-----------+
///     |  Read     | <---CLOSE---- |  Write    |
///     |  Side     |               |  Side     |
///     +-----------+               +-----------+
/// ```
private struct MplexStreamState: Sendable {
    var readBuffer: ByteBuffer = ByteBuffer()

    /// Queue of readers waiting for data
    var readContinuations: [CheckedContinuation<ByteBuffer, Error>] = []

    // Write direction state
    /// Local has closed write side (sent CLOSE)
    var localWriteClosed = false

    // Read direction state
    /// Local has closed read side (no longer interested in receiving)
    var localReadClosed = false
    /// Remote has closed write side (received CLOSE, no more data coming)
    var remoteWriteClosed = false

    /// Stream has been reset (abrupt termination)
    var isReset = false

    /// Negotiated protocol for this stream
    var protocolID: String?
}

/// A multiplexed stream over a Mplex connection.
public final class MplexStream: MuxedStream, Sendable {
    /// The stream ID.
    public let id: UInt64

    /// Whether this stream was initiated by us (vs. the remote peer).
    let isInitiator: Bool

    /// The negotiated protocol for this stream.
    public var protocolID: String? {
        get { state.withLock { $0.protocolID } }
        set { state.withLock { $0.protocolID = newValue } }
    }

    private let state: Mutex<MplexStreamState>
    private let connection: MplexConnection

    /// Maximum read buffer size before reset (DoS protection).
    private let maxReadBufferSize: Int

    init(id: UInt64, connection: MplexConnection, isInitiator: Bool, maxReadBufferSize: Int = 1024 * 1024) {
        self.id = id
        self.connection = connection
        self.isInitiator = isInitiator
        self.maxReadBufferSize = maxReadBufferSize
        self.state = Mutex(MplexStreamState())
    }

    public func read() async throws -> ByteBuffer {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                // Reset state - immediate failure
                if state.isReset {
                    continuation.resume(throwing: MplexError.streamClosed)
                    return
                }

                // Local closed read side - immediate failure
                if state.localReadClosed {
                    continuation.resume(throwing: MplexError.streamClosed)
                    return
                }

                // Return buffered data if available
                if state.readBuffer.readableBytes > 0 {
                    let data = state.readBuffer
                    state.readBuffer = ByteBuffer()
                    continuation.resume(returning: data)
                } else if state.remoteWriteClosed {
                    // Remote closed and buffer empty - no more data coming
                    continuation.resume(throwing: MplexError.streamClosed)
                } else {
                    // Queue this reader to wait for data
                    state.readContinuations.append(continuation)
                }
            }
        }
    }

    public func write(_ data: ByteBuffer) async throws {
        let isClosed = state.withLock { state in
            state.localWriteClosed || state.isReset
        }
        if isClosed {
            throw MplexError.streamClosed
        }

        // Mplex has no flow control, send data directly
        let frameData = Data(buffer: data)
        let frame = MplexFrame.message(id: id, isInitiator: isInitiator, data: frameData)
        try await connection.sendFrame(frame)
    }

    public func closeWrite() async throws {
        let shouldSend = state.withLock { state -> Bool in
            if state.localWriteClosed || state.isReset { return false }
            state.localWriteClosed = true
            return true
        }

        if shouldSend {
            let frame = MplexFrame.close(id: id, isInitiator: isInitiator)
            try await connection.sendFrame(frame)
        }
    }

    public func closeRead() async throws {
        // Mark read side as closed locally
        // Received data after this will be discarded
        let readConts = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
            if state.localReadClosed || state.isReset { return [] }
            state.localReadClosed = true
            state.readBuffer = ByteBuffer()
            let r = state.readContinuations
            state.readContinuations = []
            return r
        }

        // Resume all waiting readers with error
        for cont in readConts {
            cont.resume(throwing: MplexError.streamClosed)
        }
    }

    public func close() async throws {
        // Close both directions
        try await closeWrite()
        try await closeRead()
        connection.removeStream(id: id, initiatedLocally: isInitiator)
    }

    public func reset() async throws {
        let readConts = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
            state.isReset = true
            state.localWriteClosed = true
            state.localReadClosed = true
            state.remoteWriteClosed = true
            state.readBuffer = ByteBuffer()
            let r = state.readContinuations
            state.readContinuations = []
            return r
        }

        // Resume all waiting readers with error (outside lock)
        for cont in readConts {
            cont.resume(throwing: MplexError.streamClosed)
        }

        let frame = MplexFrame.reset(id: id, isInitiator: isInitiator)
        try await connection.sendFrame(frame)
        connection.removeStream(id: id, initiatedLocally: isInitiator)
    }

    // MARK: - Internal

    /// Called when data is received for this stream.
    func dataReceived(_ data: Data) {
        let shouldReset: Bool = state.withLock { state in
            // Ignore if reset or read-closed
            if state.isReset || state.localReadClosed {
                return false
            }

            // Deliver to waiting reader or buffer
            if !state.readContinuations.isEmpty {
                let cont = state.readContinuations.removeFirst()
                cont.resume(returning: ByteBuffer(bytes: data))
                return false
            } else {
                // Check buffer size limit (DoS protection)
                // Mplex has no flow control, so reset is the only safe response
                if state.readBuffer.readableBytes + data.count > maxReadBufferSize {
                    state.isReset = true
                    state.localWriteClosed = true
                    state.localReadClosed = true
                    state.remoteWriteClosed = true
                    state.readBuffer = ByteBuffer()
                    let conts = state.readContinuations
                    state.readContinuations = []
                    for cont in conts {
                        cont.resume(throwing: MplexError.readBufferOverflow)
                    }
                    return true
                }
                state.readBuffer.writeData(data)
                return false
            }
        }

        // Send reset frame outside lock to avoid deadlock
        if shouldReset {
            Task { [weak self] in
                guard let self else { return }
                let frame = MplexFrame.reset(id: self.id, isInitiator: self.isInitiator)
                do {
                    try await self.connection.sendFrame(frame)
                } catch {
                    logger.debug("Failed to send reset for overflowed Mplex stream \(self.id): \(error)")
                }
                self.connection.removeStream(id: self.id, initiatedLocally: self.isInitiator)
            }
        }
    }

    /// Called when remote closes the stream (received CLOSE).
    ///
    /// This is a half-close: remote stopped sending, but we can still write.
    func remoteClose() {
        let readConts = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
            state.remoteWriteClosed = true
            let r = state.readContinuations
            state.readContinuations = []
            return r
        }

        // Resume read waiters outside of lock
        for cont in readConts {
            cont.resume(throwing: MplexError.streamClosed)
        }
    }

    /// Called when the stream is reset by remote (received RESET).
    func remoteReset() {
        let readConts = state.withLock { state -> [CheckedContinuation<ByteBuffer, Error>] in
            state.isReset = true
            state.localWriteClosed = true
            state.localReadClosed = true
            state.remoteWriteClosed = true
            state.readBuffer = ByteBuffer()
            let r = state.readContinuations
            state.readContinuations = []
            return r
        }

        // Resume all waiting continuations outside of lock
        for cont in readConts {
            cont.resume(throwing: MplexError.streamClosed)
        }
    }
}
