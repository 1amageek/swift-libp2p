/// P2PMux - Stream multiplexing for swift-libp2p
///
/// Provides multiplexing protocols and implementations:
/// - Yamux
/// - Mplex
/// - Muxer protocol abstractions

import P2PCore

/// A multiplexed stream within a connection.
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
    func closeWrite() async throws

    /// Closes the stream completely.
    func close() async throws

    /// Resets the stream (abrupt close).
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
