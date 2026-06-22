/// MplexFrame - Mplex frame encoding/decoding
///
/// Frame format:
/// ```
/// [header: varint] [length: varint] [data: bytes]
///
/// header = (streamID << 3) | flag
/// ```
import Foundation
import P2PCore
import NIOCore

/// Mplex protocol identifier.
public let mplexProtocolID = "/mplex/6.7.0"

/// Maximum allowed frame data size (1MB) to prevent memory exhaustion attacks.
public let mplexMaxFrameSize: UInt64 = 1024 * 1024

/// Maximum read buffer size (8MB)
let mplexMaxReadBufferSize = 8 * 1024 * 1024

/// Threshold for compacting the read buffer (64KB)
let mplexReadBufferCompactThreshold = 64 * 1024

/// Mplex frame flags.
///
/// The flag indicates both the message type and the sender's perspective
/// (initiator or receiver).
public enum MplexFlag: UInt8, Sendable {
    /// New stream (includes stream name as data)
    case newStream = 0
    /// Data from receiver's perspective
    case messageReceiver = 1
    /// Data from initiator's perspective
    case messageInitiator = 2
    /// Half-close from receiver's perspective
    case closeReceiver = 3
    /// Half-close from initiator's perspective
    case closeInitiator = 4
    /// Reset from receiver's perspective
    case resetReceiver = 5
    /// Reset from initiator's perspective
    case resetInitiator = 6
}

/// A Mplex frame.
public struct MplexFrame: Sendable, Equatable {
    /// The stream ID.
    public let streamID: UInt64

    /// The frame flag.
    public let flag: MplexFlag

    /// The frame data (optional).
    public let data: ByteBuffer

    /// Creates a new Mplex frame.
    public init(streamID: UInt64, flag: MplexFlag, data: ByteBuffer = ByteBuffer()) {
        self.streamID = streamID
        self.flag = flag
        self.data = data
    }

    /// Convenience initializer for legacy Data-based callers.
    public init(streamID: UInt64, flag: MplexFlag, data: Data) {
        self.init(streamID: streamID, flag: flag, data: ByteBuffer(bytes: data))
    }

    // MARK: - Factory Methods

    /// Creates a new stream frame.
    ///
    /// - Parameters:
    ///   - id: The stream ID
    ///   - name: Optional stream name (typically empty)
    public static func newStream(id: UInt64, name: String = "") -> MplexFrame {
        MplexFrame(streamID: id, flag: .newStream, data: ByteBuffer(string: name))
    }

    /// Creates a message frame.
    ///
    /// - Parameters:
    ///   - id: The stream ID
    ///   - isInitiator: Whether the sender is the stream initiator
    ///   - data: The message data
    public static func message(id: UInt64, isInitiator: Bool, data: ByteBuffer) -> MplexFrame {
        MplexFrame(
            streamID: id,
            flag: isInitiator ? .messageInitiator : .messageReceiver,
            data: data
        )
    }

    public static func message(id: UInt64, isInitiator: Bool, data: Data) -> MplexFrame {
        message(id: id, isInitiator: isInitiator, data: ByteBuffer(bytes: data))
    }

    /// Creates a close frame (half-close).
    ///
    /// - Parameters:
    ///   - id: The stream ID
    ///   - isInitiator: Whether the sender is the stream initiator
    public static func close(id: UInt64, isInitiator: Bool) -> MplexFrame {
        MplexFrame(
            streamID: id,
            flag: isInitiator ? .closeInitiator : .closeReceiver
        )
    }

    /// Creates a reset frame.
    ///
    /// - Parameters:
    ///   - id: The stream ID
    ///   - isInitiator: Whether the sender is the stream initiator
    public static func reset(id: UInt64, isInitiator: Bool) -> MplexFrame {
        MplexFrame(
            streamID: id,
            flag: isInitiator ? .resetInitiator : .resetReceiver
        )
    }

    // MARK: - Encoding

    /// Encodes the frame to bytes.
    public func encode() -> Data {
        var buffer = ByteBuffer()
        encode(into: &buffer)
        return Data(buffer: buffer)
    }

    /// Encodes the frame into an existing ByteBuffer.
    public func encode(into buffer: inout ByteBuffer) {
        Varint.encode((streamID << 3) | UInt64(flag.rawValue), into: &buffer)
        Varint.encode(UInt64(data.readableBytes), into: &buffer)
        var payload = data
        buffer.writeBuffer(&payload)
    }

    // MARK: - Decoding

    /// Decodes a frame from bytes.
    ///
    /// - Parameters:
    ///   - buffer: The buffer to decode from
    ///   - maxFrameSize: Maximum allowed frame data size (default: global limit)
    /// - Returns: The decoded frame and bytes consumed, or nil if more data is needed
    /// - Throws: `MplexError` if the frame is malformed
    public static func decode(
        from buffer: Data,
        maxFrameSize: UInt64 = mplexMaxFrameSize
    ) throws -> (frame: MplexFrame, bytesConsumed: Int)? {
        var byteBuffer = ByteBuffer(bytes: buffer)
        let start = byteBuffer.readerIndex
        guard let frame = try decode(from: &byteBuffer, maxFrameSize: maxFrameSize) else {
            return nil
        }
        return (frame, byteBuffer.readerIndex - start)
    }

    /// Decodes a frame from a ByteBuffer, advancing the reader index on success.
    public static func decode(
        from buffer: inout ByteBuffer,
        maxFrameSize: UInt64 = mplexMaxFrameSize
    ) throws -> MplexFrame? {
        let readableBytes = buffer.readableBytes
        guard readableBytes > 0 else { return nil }

        let headerAndLength = try buffer.withUnsafeReadableBytes { ptr -> ((UInt64, Int)?, (UInt64, Int)?) in
            let raw = UnsafeRawBufferPointer(ptr)
            let header = try decodeVarintAt(raw, offset: 0)
            guard let (_, headerBytes) = header else {
                return (nil, nil)
            }
            let length = try decodeVarintAt(raw, offset: headerBytes)
            return (header, length)
        }

        guard
            let (header, headerSize) = headerAndLength.0,
            let (length, lengthSize) = headerAndLength.1
        else {
            return nil
        }

        if length > maxFrameSize {
            throw MplexError.frameTooLarge(size: length, max: maxFrameSize)
        }

        let totalHeaderBytes = headerSize + lengthSize
        guard readableBytes >= totalHeaderBytes + Int(length) else {
            return nil
        }

        let streamID = header >> 3
        let flagValue = UInt8(header & 0x07)
        guard let flag = MplexFlag(rawValue: flagValue) else {
            throw MplexError.invalidFlag(flagValue)
        }

        buffer.moveReaderIndex(forwardBy: totalHeaderBytes)
        guard let payload = buffer.readSlice(length: Int(length)) else {
            return nil
        }

        return MplexFrame(streamID: streamID, flag: flag, data: payload)
    }

    /// Decodes a varint from data at the given offset using P2PCore.Varint.
    ///
    /// Returns nil if the data is incomplete (needs more bytes).
    /// Throws on malformed varint (overflow) to trigger connection shutdown.
    private static func decodeVarintAt(_ data: Data, offset: Int) throws -> (value: UInt64, size: Int)? {
        do {
            let (value, bytesRead) = try Varint.decode(from: data, at: offset)
            return (value, bytesRead)
        } catch VarintError.insufficientData {
            return nil
        }
        // VarintError.overflow propagates → readLoop shuts down connection
    }

    private static func decodeVarintAt(_ data: UnsafeRawBufferPointer, offset: Int) throws -> (value: UInt64, size: Int)? {
        guard offset < data.count else { return nil }
        do {
            let (value, bytesRead) = try Varint.decode(from: data, at: offset)
            return (value, bytesRead)
        } catch VarintError.insufficientData {
            return nil
        }
    }
}

// MARK: - Errors

/// Mplex-specific errors.
public enum MplexError: Error, Sendable {
    /// Invalid flag value
    case invalidFlag(UInt8)
    /// Frame exceeds maximum size
    case frameTooLarge(size: UInt64, max: UInt64)
    /// Stream is closed
    case streamClosed
    /// Connection is closed
    case connectionClosed
    /// Protocol error
    case protocolError(String)
    /// Read buffer overflow (DoS protection)
    case readBufferOverflow
    /// Stream ID exhausted
    case streamIDExhausted
}

// MARK: - Configuration

/// Configuration for Mplex connections.
public struct MplexConfiguration: Sendable {
    /// Maximum number of concurrent streams per connection.
    ///
    /// When this limit is reached, new inbound streams are rejected with RST.
    /// Default: 1000
    public var maxConcurrentStreams: Int

    /// Maximum number of pending inbound streams in the delivery buffer.
    ///
    /// When this limit is reached, new inbound streams are rejected with RST.
    /// Default: 100
    public var maxPendingInboundStreams: Int

    /// Maximum frame data size.
    ///
    /// Default: 1MB
    public var maxFrameSize: Int

    /// Maximum connection-level read buffer size.
    ///
    /// Default: 8MB
    public var maxReadBufferSize: Int

    /// Maximum per-stream receive buffer size before the stream is reset.
    ///
    /// Mplex has no flow control, so an unread stream's buffer is bounded by
    /// resetting the stream when it overflows. This is a distinct concern from
    /// `maxFrameSize` (the size of a single wire frame): a stream may receive
    /// many in-bound frames before the application reads, so its buffer cap must
    /// be configured independently rather than borrowing the frame-size limit.
    /// Default: 1MB
    public var maxReadBufferSizePerStream: Int

    /// Creates a Mplex configuration.
    public init(
        maxConcurrentStreams: Int = 1000,
        maxPendingInboundStreams: Int = 100,
        maxFrameSize: Int = 1024 * 1024,
        maxReadBufferSize: Int = 8 * 1024 * 1024,
        maxReadBufferSizePerStream: Int = 1024 * 1024
    ) {
        self.maxConcurrentStreams = maxConcurrentStreams
        self.maxPendingInboundStreams = maxPendingInboundStreams
        self.maxFrameSize = maxFrameSize
        self.maxReadBufferSize = maxReadBufferSize
        self.maxReadBufferSizePerStream = maxReadBufferSizePerStream
    }

    /// Default configuration.
    public static let `default` = MplexConfiguration()
}
