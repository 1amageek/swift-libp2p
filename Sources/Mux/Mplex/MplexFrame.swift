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
    public let data: Data

    /// Creates a new Mplex frame.
    public init(streamID: UInt64, flag: MplexFlag, data: Data = Data()) {
        self.streamID = streamID
        self.flag = flag
        self.data = data
    }

    // MARK: - Factory Methods

    /// Creates a new stream frame.
    ///
    /// - Parameters:
    ///   - id: The stream ID
    ///   - name: Optional stream name (typically empty)
    public static func newStream(id: UInt64, name: String = "") -> MplexFrame {
        MplexFrame(streamID: id, flag: .newStream, data: Data(name.utf8))
    }

    /// Creates a message frame.
    ///
    /// - Parameters:
    ///   - id: The stream ID
    ///   - isInitiator: Whether the sender is the stream initiator
    ///   - data: The message data
    public static func message(id: UInt64, isInitiator: Bool, data: Data) -> MplexFrame {
        MplexFrame(
            streamID: id,
            flag: isInitiator ? .messageInitiator : .messageReceiver,
            data: data
        )
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
        // Estimate: 2 varints (max 10 bytes each) + data
        var result = Data(capacity: 20 + data.count)

        // Encode header: (streamID << 3) | flag
        let header = (streamID << 3) | UInt64(flag.rawValue)
        result.append(Varint.encode(header))

        // Encode length
        result.append(Varint.encode(UInt64(data.count)))

        // Append data
        result.append(data)

        return result
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
        var offset = 0

        // Decode header
        guard let (header, headerSize) = try decodeVarintAt(buffer, offset: offset) else {
            return nil
        }
        offset += headerSize

        // Decode length
        guard let (length, lengthSize) = try decodeVarintAt(buffer, offset: offset) else {
            return nil
        }
        offset += lengthSize

        // Validate frame size
        if length > maxFrameSize {
            throw MplexError.frameTooLarge(size: length, max: maxFrameSize)
        }

        // Check if we have enough data
        guard buffer.count >= offset + Int(length) else {
            return nil
        }

        // Extract stream ID and flag from header
        let streamID = header >> 3
        let flagValue = UInt8(header & 0x07)
        guard let flag = MplexFlag(rawValue: flagValue) else {
            throw MplexError.invalidFlag(flagValue)
        }

        // Extract data (use startIndex-relative addressing for Data slices)
        let dataStart = buffer.startIndex + offset
        let data = Data(buffer[dataStart..<dataStart + Int(length)])
        offset += Int(length)

        let frame = MplexFrame(streamID: streamID, flag: flag, data: data)
        return (frame, offset)
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

    /// Maximum read buffer size.
    ///
    /// Default: 8MB
    public var maxReadBufferSize: Int

    /// Creates a Mplex configuration.
    public init(
        maxConcurrentStreams: Int = 1000,
        maxPendingInboundStreams: Int = 100,
        maxFrameSize: Int = 1024 * 1024,
        maxReadBufferSize: Int = 8 * 1024 * 1024
    ) {
        self.maxConcurrentStreams = maxConcurrentStreams
        self.maxPendingInboundStreams = maxPendingInboundStreams
        self.maxFrameSize = maxFrameSize
        self.maxReadBufferSize = maxReadBufferSize
    }

    /// Default configuration.
    public static let `default` = MplexConfiguration()
}
