/// P2PMux - Stream multiplexing for swift-libp2p
///
/// Provides multiplexing protocols and implementations:
/// - Yamux
/// - Mplex
/// - Muxer protocol abstractions

import P2PCore

/// A multiplexed stream within a connection.
///
/// Stream lifecycle methods:
/// - `closeWrite()`: Half-close for writing. Signals "I'm done sending" to peer.
///   Peer can still send data, and we can still read.
/// - `closeRead()`: Half-close for reading. Signals "I'm done receiving" to peer.
///   We can still send data, but reads will fail.
/// - `close()`: Graceful full close. Equivalent to `closeRead()` + `closeWrite()`.
///   Allows pending data to be transmitted before closing.
/// - `reset()`: Abrupt close. Immediately terminates the stream in both directions.
///   Pending data may be lost. Use for error conditions or forced shutdown.
public protocol MuxedStream: Sendable {
    /// The stream ID.
    var id: UInt64 { get }

    /// The negotiated protocol for this stream.
    var protocolID: String? { get }

    /// Reads data from the stream.
    func read() async throws -> Data

    /// Writes data to the stream.
    func write(_ data: Data) async throws

    /// Closes the stream for writing (half-close).
    ///
    /// After calling this, `write()` will fail but `read()` can still receive data
    /// from the peer until they close their write side.
    func closeWrite() async throws

    /// Closes the stream for reading (half-close).
    ///
    /// After calling this, `read()` will fail but `write()` can still send data
    /// to the peer. Signals to the peer that we won't read any more data.
    func closeRead() async throws

    /// Closes the stream completely (both read and write).
    ///
    /// This is a graceful close that allows pending data to be transmitted.
    /// Equivalent to calling both `closeRead()` and `closeWrite()`.
    func close() async throws

    /// Resets the stream (abrupt close).
    ///
    /// Immediately terminates the stream in both directions. Any pending data
    /// may be lost. Use this for error conditions or forced shutdown.
    func reset() async throws
}

/// A multiplexed connection that can create multiple streams.
public protocol MuxedConnection: Sendable {
    /// The local peer ID.
    var localPeer: PeerID { get }

    /// The remote peer ID.
    var remotePeer: PeerID { get }

    /// The local address (if known).
    var localAddress: Multiaddr? { get }

    /// The remote address.
    var remoteAddress: Multiaddr { get }

    /// Opens a new outbound stream.
    func newStream() async throws -> MuxedStream

    /// Accepts an incoming stream.
    func acceptStream() async throws -> MuxedStream

    /// Returns an async stream of incoming streams.
    var inboundStreams: AsyncStream<MuxedStream> { get }

    /// Closes all streams and the connection.
    func close() async throws
}

/// A muxer that upgrades secured connections.
public protocol Muxer: Sendable {
    /// The protocol ID (e.g., "/yamux/1.0.0").
    var protocolID: String { get }

    /// Multiplexes a secured connection.
    ///
    /// - Parameters:
    ///   - connection: The secured connection
    ///   - isInitiator: Whether we initiated the connection
    /// - Returns: A muxed connection
    func multiplex(
        _ connection: any SecuredConnection,
        isInitiator: Bool
    ) async throws -> MuxedConnection
}

// MARK: - Length-Prefixed Message I/O

/// Error for stream message operations.
public enum StreamMessageError: Error, Sendable {
    case streamClosed
    case messageTooLarge(UInt64)
    case emptyMessage
}

extension MuxedStream {

    /// Reads a length-prefixed message from the stream.
    ///
    /// - Parameter maxSize: Maximum allowed message size.
    /// - Returns: The message data.
    /// - Throws: `StreamMessageError` on failure.
    public func readLengthPrefixedMessage(maxSize: UInt64 = 64 * 1024) async throws -> Data {
        var buffer = Data()

        // Read until we have a complete varint (max 10 bytes)
        while true {
            let chunk = try await read()
            if chunk.isEmpty {
                throw StreamMessageError.streamClosed
            }
            buffer.append(chunk)

            // Check if we have a complete varint (byte with MSB = 0)
            var foundEnd = false
            for i in 0..<min(buffer.count, 10) {
                if buffer[i] & 0x80 == 0 {
                    foundEnd = true
                    break
                }
            }
            if foundEnd || buffer.count >= 10 {
                break
            }
        }

        guard !buffer.isEmpty else {
            throw StreamMessageError.emptyMessage
        }

        let (length, varintBytes) = try Varint.decode(buffer)
        guard length <= maxSize else {
            throw StreamMessageError.messageTooLarge(length)
        }
        // Ensure length fits in Int for memory operations
        guard length <= UInt64(Int.max) else {
            throw StreamMessageError.messageTooLarge(length)
        }

        // Use remaining bytes from buffer
        buffer.removeFirst(varintBytes)

        // Read more if needed
        while buffer.count < length {
            let chunk = try await read()
            if chunk.isEmpty {
                throw StreamMessageError.streamClosed
            }
            buffer.append(chunk)
        }

        // Return exactly length bytes (avoid copy if possible)
        if buffer.count == length {
            return buffer
        }
        return Data(buffer.prefix(Int(length)))
    }

    /// Writes a length-prefixed message to the stream.
    ///
    /// - Parameter data: The message data to write.
    public func writeLengthPrefixedMessage(_ data: Data) async throws {
        var message = Data(Varint.encode(UInt64(data.count)))
        message.append(data)
        try await write(message)
    }
}
