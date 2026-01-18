/// QUIC Stream wrapper implementing MuxedStream protocol.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import QUIC

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
        var isClosed: Bool = false
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
    /// - Throws: Error if read fails.
    public func read() async throws -> Data {
        try await stream.read()
    }

    /// Writes data to the stream.
    ///
    /// - Parameter data: The data to write.
    /// - Throws: Error if write fails.
    public func write(_ data: Data) async throws {
        try await stream.write(data)
    }

    /// Closes the write side of the stream (sends FIN).
    ///
    /// After calling this, no more data can be written, but reads
    /// can continue until the peer closes their write side.
    public func closeWrite() async throws {
        try await stream.closeWrite()
    }

    /// Closes the stream completely.
    ///
    /// This closes both read and write sides.
    public func close() async throws {
        let alreadyClosed = state.withLock { s in
            let was = s.isClosed
            s.isClosed = true
            return was
        }

        guard !alreadyClosed else { return }

        try await stream.closeWrite()
    }

    /// Resets the stream with an error code.
    ///
    /// This abruptly closes the stream, signaling an error to the peer.
    public func reset() async throws {
        state.withLock { $0.isClosed = true }
        await stream.reset(errorCode: 0)
    }
}
