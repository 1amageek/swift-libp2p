/// MplexFrame - Mplex frame encoding/decoding
///
/// Frame format:
/// ```
/// [header: varint] [length: varint] [data: bytes]
///
/// header = (streamID << 3) | flag
/// ```
import Foundation

/// Mplex protocol identifier.
public let mplexProtocolID = "/mplex/6.7.0"

/// Maximum allowed frame data size (1MB) to prevent memory exhaustion attacks.
let mplexMaxFrameSize: UInt64 = 1024 * 1024

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
        var result = Data()

        // Encode header: (streamID << 3) | flag
        let header = (streamID << 3) | UInt64(flag.rawValue)
        result.append(contentsOf: encodeVarint(header))

        // Encode length
        result.append(contentsOf: encodeVarint(UInt64(data.count)))

        // Append data
        result.append(data)

        return result
    }

    // MARK: - Decoding

    /// Decodes a frame from bytes.
    ///
    /// - Parameter buffer: The buffer to decode from
    /// - Returns: The decoded frame and bytes consumed, or nil if more data is needed
    /// - Throws: `MplexError` if the frame is malformed
    public static func decode(from buffer: Data) throws -> (frame: MplexFrame, bytesConsumed: Int)? {
        var offset = 0

        // Decode header
        guard let (header, headerSize) = decodeVarint(from: buffer, at: offset) else {
            return nil
        }
        offset += headerSize

        // Decode length
        guard let (length, lengthSize) = decodeVarint(from: buffer, at: offset) else {
            return nil
        }
        offset += lengthSize

        // Validate frame size
        if length > mplexMaxFrameSize {
            throw MplexError.frameTooLarge(size: length, max: mplexMaxFrameSize)
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

        // Extract data
        let data = Data(buffer[offset..<offset + Int(length)])
        offset += Int(length)

        let frame = MplexFrame(streamID: streamID, flag: flag, data: data)
        return (frame, offset)
    }
}

// MARK: - Varint Encoding/Decoding

/// Encodes a value as a varint.
func encodeVarint(_ value: UInt64) -> [UInt8] {
    var result: [UInt8] = []
    var v = value
    while v >= 0x80 {
        result.append(UInt8(v & 0x7F) | 0x80)
        v >>= 7
    }
    result.append(UInt8(v))
    return result
}

/// Decodes a varint from data.
///
/// - Parameters:
///   - data: The data to decode from
///   - offset: The offset to start decoding at
/// - Returns: The decoded value and number of bytes consumed, or nil if incomplete
func decodeVarint(from data: Data, at offset: Int) -> (value: UInt64, size: Int)? {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    var index = offset

    while index < data.count {
        let byte = data[index]
        value |= UInt64(byte & 0x7F) << shift
        index += 1

        if byte & 0x80 == 0 {
            return (value, index - offset)
        }
        shift += 7

        // Overflow protection: varint should not exceed 10 bytes for UInt64
        if shift > 63 {
            return nil
        }
    }

    // Incomplete varint
    return nil
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
    /// Maximum concurrent streams exceeded
    case maxStreamsExceeded(current: Int, max: Int)
    /// Stream ID reused
    case streamIDReused(UInt64)
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
