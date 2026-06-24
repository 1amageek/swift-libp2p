/// QUIC Stream wrapper implementing MuxedStream protocol.

import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PMux
import QUIC
import Logging

private let logger = Logger(label: "swift-libp2p.QUICMuxedStream")

/// A QUIC stream wrapped as a MuxedStream.
///
/// This class wraps a `QUICStreamProtocol` to conform to the libp2p
/// `MuxedStream` protocol, enabling QUIC streams to be used with
/// libp2p's protocol negotiation and stream handling.
public final class QUICMuxedStream: MuxedStream, Sendable {

    private let stream: any QUICStreamProtocol

    /// Invoked exactly once when the stream terminates (both read and write
    /// closed, or reset) so the owning connection can decrement its open-stream
    /// count and become idle-reclaimable. Mirrors `WebRTCMuxedStream.onTerminate`.
    private let onTerminate: @Sendable (UInt64) -> Void

    private let state: Mutex<StreamState>

    private struct StreamState: Sendable {
        var protocolID: String?
        var readClosed: Bool = false
        var writeClosed: Bool = false
        /// Set once when the termination callback has fired, so the owning
        /// connection's open-stream count is decremented exactly once.
        var didTerminate: Bool = false
    }

    /// The stream ID.
    public var id: UInt64 {
        stream.id
    }

    /// The negotiated protocol for this stream.
    public var protocolID: String? {
        state.withLock { $0.protocolID }
    }

    /// Creates a new QUICMuxedStream wrapping the given QUIC stream.
    ///
    /// - Parameters:
    ///   - stream: The underlying QUIC stream
    ///   - protocolID: The negotiated protocol ID (if known)
    ///   - onTerminate: Invoked exactly once when the stream terminates, with the
    ///     stream ID, so the owning connection can drop its open-stream
    ///     bookkeeping. Defaults to a no-op for callers that do not track streams.
    public init(
        stream: any QUICStreamProtocol,
        protocolID: String? = nil,
        onTerminate: @escaping @Sendable (UInt64) -> Void = { _ in }
    ) {
        self.stream = stream
        self.onTerminate = onTerminate
        self.state = Mutex(StreamState(protocolID: protocolID))
    }

    /// Sets the negotiated protocol ID.
    ///
    /// This is called after protocol negotiation completes.
    ///
    /// - Parameter protocolID: The negotiated protocol ID
    public func setProtocolID(_ protocolID: String) {
        state.withLock { $0.protocolID = protocolID }
    }

    // MARK: - MuxedStream

    /// Reads data from the stream.
    ///
    /// - Returns: The data read, or empty ByteBuffer if the stream is finished.
    /// - Throws: Error if read fails or stream is closed for reading.
    public func read() async throws -> ByteBuffer {
        let data = try await stream.read()
        return ByteBuffer(bytes: data)
    }

    /// Writes data to the stream.
    ///
    /// - Parameter data: The data to write.
    /// - Throws: Error if write fails or stream is closed for writing.
    public func write(_ data: ByteBuffer) async throws {
        try await stream.write(Data(buffer: data))
    }

    /// Closes the write side of the stream (sends FIN).
    ///
    /// After calling this, no more data can be written, but reads
    /// can continue until the peer closes their write side.
    public func closeWrite() async throws {
        let alreadyClosed = state.withLock { s in
            let was = s.writeClosed
            s.writeClosed = true
            return was
        }
        guard !alreadyClosed else { return }

        logger.debug("closeWrite(): Stream \(self.id)")
        try await stream.closeWrite()
        // Half-closing the write side may complete termination (if the read side
        // was already closed). Notify the owning connection once both are closed.
        terminateIfNeeded()
    }

    /// Closes the read side of the stream (sends STOP_SENDING).
    ///
    /// After calling this, no more data can be read. Signals to the peer
    /// that we are no longer interested in receiving data.
    public func closeRead() async throws {
        let alreadyClosed = state.withLock { s in
            let was = s.readClosed
            s.readClosed = true
            return was
        }
        guard !alreadyClosed else { return }

        logger.debug("closeRead(): Stream \(self.id)")
        // QUIC STOP_SENDING frame tells peer we won't read anymore
        try await stream.stopSending(errorCode: 0)
        // Half-closing the read side may complete termination (if the write side
        // was already closed). Notify the owning connection once both are closed.
        terminateIfNeeded()
    }

    /// Closes the stream gracefully.
    ///
    /// This sends FIN to signal we're done writing. The stream will be fully
    /// closed when both sides have sent FIN. Does NOT send STOP_SENDING
    /// to avoid disrupting in-flight data.
    ///
    /// - Note: Use `reset()` if you need to abort the stream immediately.
    public func close() async throws {
        let writeAlreadyClosed = state.withLock { s in
            let writeWas = s.writeClosed
            s.readClosed = true
            s.writeClosed = true
            return writeWas
        }

        logger.debug("close(): Stream \(self.id)")

        // Close write side if not already closed
        // This sends FIN to signal we're done writing
        // Do NOT send STOP_SENDING as it removes the stream and loses pending data
        if !writeAlreadyClosed {
            try await stream.closeWrite()
        }
        // close() marks both read and write closed, so the stream is terminated.
        terminateIfNeeded()
    }

    /// Resets the stream (abrupt close).
    ///
    /// Immediately terminates the stream in both directions, signaling
    /// an error to the peer. Any pending data may be lost.
    public func reset() async throws {
        state.withLock { s in
            s.readClosed = true
            s.writeClosed = true
        }

        logger.debug("reset(): Stream \(self.id)")
        await stream.reset(errorCode: 0)
        // reset() marks both read and write closed, so the stream is terminated.
        terminateIfNeeded()
    }

    // MARK: - Termination

    /// Invokes the termination callback exactly once, when both the read and
    /// write sides are closed. Idempotent across `close`/`reset`/`closeWrite`+
    /// `closeRead`.
    private func terminateIfNeeded() {
        let shouldNotify = state.withLock { s -> Bool in
            guard s.readClosed, s.writeClosed, !s.didTerminate else { return false }
            s.didTerminate = true
            return true
        }
        if shouldNotify {
            onTerminate(id)
        }
    }
}
