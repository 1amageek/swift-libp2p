/// QUIC Stream wrapper implementing MuxedStream protocol.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import QUIC
import os

private let logger = Logger(subsystem: "swift-libp2p", category: "QUICMuxedStream")

/// A QUIC stream wrapped as a MuxedStream.
///
/// This class wraps a `QUICStreamProtocol` to conform to the libp2p
/// `MuxedStream` protocol, enabling QUIC streams to be used with
/// libp2p's protocol negotiation and stream handling.
public final class QUICMuxedStream: MuxedStream, @unchecked Sendable {

    private let stream: any QUICStreamProtocol
    private let state: Mutex<StreamState>

    private struct StreamState: Sendable {
        var protocolID: String?
        var readClosed: Bool = false
        var writeClosed: Bool = false
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
    public init(stream: any QUICStreamProtocol, protocolID: String? = nil) {
        self.stream = stream
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
    /// - Returns: The data read, or empty Data if the stream is finished.
    /// - Throws: Error if read fails or stream is closed for reading.
    public func read() async throws -> Data {
        try await stream.read()
    }

    /// Writes data to the stream.
    ///
    /// - Parameter data: The data to write.
    /// - Throws: Error if write fails or stream is closed for writing.
    public func write(_ data: Data) async throws {
        try await stream.write(data)
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
    }
}
