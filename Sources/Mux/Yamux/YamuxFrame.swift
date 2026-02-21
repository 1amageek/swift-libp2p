/// YamuxFrame - Yamux frame encoding/decoding
///
/// Frame format (12-byte header):
/// ```
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Version (8) |     Type (8)  |          Flags (16)          |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                        Stream ID (32)                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                         Length (32)                          |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
import Foundation
import NIOCore

/// Yamux protocol version.
let yamuxVersion: UInt8 = 0

/// Header size in bytes.
let yamuxHeaderSize = 12

/// Default window size (256KB).
let yamuxDefaultWindowSize: UInt32 = 256 * 1024

/// Maximum allowed frame data size (16MB) to prevent memory exhaustion attacks.
/// This is much larger than typical use (window is 256KB) but prevents DoS.
let yamuxMaxFrameSize: UInt32 = 16 * 1024 * 1024

/// Maximum send window size (16MB) to prevent overflow from malicious WindowUpdate deltas.
let yamuxMaxWindowSize: UInt32 = 16 * 1024 * 1024

/// Frame types.
enum YamuxFrameType: UInt8, Sendable {
    case data = 0
    case windowUpdate = 1
    case ping = 2
    case goAway = 3
}

/// Frame flags.
struct YamuxFlags: OptionSet, Sendable {
    let rawValue: UInt16

    static let syn = YamuxFlags(rawValue: 0x0001)  // Stream open
    static let ack = YamuxFlags(rawValue: 0x0002)  // Stream acknowledge
    static let fin = YamuxFlags(rawValue: 0x0004)  // Half-close
    static let rst = YamuxFlags(rawValue: 0x0008)  // Reset stream
}

/// GoAway reason codes.
enum YamuxGoAwayReason: UInt32, Sendable {
    case normal = 0
    case protocolError = 1
    case internalError = 2
}

/// A Yamux frame.
struct YamuxFrame: Sendable {
    let type: YamuxFrameType
    let flags: YamuxFlags
    let streamID: UInt32
    let length: UInt32
    let data: ByteBuffer?

    /// Creates a data frame.
    static func data(streamID: UInt32, flags: YamuxFlags = [], data: ByteBuffer) -> YamuxFrame {
        YamuxFrame(type: .data, flags: flags, streamID: streamID, length: UInt32(data.readableBytes), data: data)
    }

    /// Creates a window update frame.
    static func windowUpdate(streamID: UInt32, delta: UInt32) -> YamuxFrame {
        YamuxFrame(type: .windowUpdate, flags: [], streamID: streamID, length: delta, data: nil)
    }

    /// Creates a ping frame.
    static func ping(opaque: UInt32, ack: Bool = false) -> YamuxFrame {
        YamuxFrame(type: .ping, flags: ack ? .ack : [], streamID: 0, length: opaque, data: nil)
    }

    /// Creates a goaway frame.
    static func goAway(reason: YamuxGoAwayReason) -> YamuxFrame {
        YamuxFrame(type: .goAway, flags: [], streamID: 0, length: reason.rawValue, data: nil)
    }

    /// Encodes the frame to a ByteBuffer.
    func encode() -> ByteBuffer {
        let payloadSize = type == .data ? Int(length) : 0
        var buf = ByteBuffer()
        buf.reserveCapacity(yamuxHeaderSize + payloadSize)

        // Write 12-byte header (writeInteger defaults to big-endian)
        buf.writeInteger(yamuxVersion)
        buf.writeInteger(type.rawValue)
        buf.writeInteger(flags.rawValue)
        buf.writeInteger(streamID)
        buf.writeInteger(length)

        // Payload (if present)
        if var payload = data {
            buf.writeBuffer(&payload)
        }

        return buf
    }

    /// Decodes a frame from a ByteBuffer.
    ///
    /// On success, advances the buffer's reader index past the consumed bytes.
    /// On partial data (returns nil), the reader index is not modified.
    ///
    /// - Returns: The decoded frame, or nil if more data is needed
    /// - Throws: `YamuxError` if the frame is malformed
    static func decode(from buffer: inout ByteBuffer) throws -> YamuxFrame? {
        guard buffer.readableBytes >= yamuxHeaderSize else {
            return nil
        }

        // Save reader index to restore on partial read
        let savedReaderIndex = buffer.readerIndex

        // Parse header using readInteger (big-endian)
        guard let version: UInt8 = buffer.readInteger(),
              let typeRaw: UInt8 = buffer.readInteger(),
              let flagsRaw: UInt16 = buffer.readInteger(),
              let streamID: UInt32 = buffer.readInteger(),
              let length: UInt32 = buffer.readInteger() else {
            buffer.moveReaderIndex(to: savedReaderIndex)
            return nil
        }

        guard version == yamuxVersion else {
            throw YamuxError.invalidVersion(version)
        }

        guard let type = YamuxFrameType(rawValue: typeRaw) else {
            throw YamuxError.invalidFrameType(typeRaw)
        }

        let flags = YamuxFlags(rawValue: flagsRaw)

        // Only Data frames have actual payload data.
        let payloadLength = type == .data ? Int(length) : 0

        // Validate frame size to prevent memory exhaustion attacks
        if type == .data && length > yamuxMaxFrameSize {
            throw YamuxError.frameTooLarge(size: length, max: yamuxMaxFrameSize)
        }

        guard buffer.readableBytes >= payloadLength else {
            // Not enough data for payload - restore reader index
            buffer.moveReaderIndex(to: savedReaderIndex)
            return nil
        }

        // Read payload as a zero-copy slice (shares underlying storage)
        let frameData: ByteBuffer?
        if type == .data && length > 0 {
            frameData = buffer.readSlice(length: Int(length))
        } else {
            frameData = nil
        }

        return YamuxFrame(
            type: type,
            flags: flags,
            streamID: streamID,
            length: length,
            data: frameData
        )
    }
}

/// Maximum read buffer size (32MB - allows 2x max frame size for reassembly)
let yamuxMaxReadBufferSize = 32 * 1024 * 1024

/// Yamux-specific errors.
enum YamuxError: Error, Sendable {
    case invalidVersion(UInt8)
    case invalidFrameType(UInt8)
    case streamClosed
    case connectionClosed
    case windowExceeded
    case protocolError(String)
    case frameTooLarge(size: UInt32, max: UInt32)
    case maxStreamsExceeded(current: Int, max: Int)
    case streamIDReused(UInt32)
    case keepAliveTimeout
    /// Read buffer exceeded maximum size (DoS protection)
    case readBufferOverflow
    /// Stream ID space exhausted (connection too long-lived)
    case streamIDExhausted
}

// MARK: - Configuration

/// Configuration for Yamux connections.
public struct YamuxConfiguration: Sendable {
    /// Maximum number of concurrent streams per connection.
    ///
    /// When this limit is reached, new inbound streams are rejected with RST.
    /// Default: 1000
    public var maxConcurrentStreams: Int

    /// Maximum number of pending inbound streams in the delivery buffer.
    ///
    /// When this limit is reached, new inbound streams are rejected with RST
    /// instead of being silently dropped. This provides proper backpressure
    /// to the remote peer.
    /// Default: 100
    public var maxPendingInboundStreams: Int

    /// Initial window size for new streams in bytes.
    ///
    /// Default: 256KB (262144 bytes)
    public var initialWindowSize: UInt32

    /// Whether to enable keep-alive pings.
    ///
    /// When enabled, the connection periodically sends Ping frames to detect
    /// dead connections and maintain NAT bindings.
    /// Default: true
    public var enableKeepAlive: Bool

    /// Interval between keep-alive pings.
    ///
    /// A Ping frame is sent after this duration of idle time.
    /// Default: 30 seconds
    public var keepAliveInterval: Duration

    /// Timeout for keep-alive ping responses.
    ///
    /// If a Pong response is not received within this duration after sending
    /// a Ping, the connection is considered dead and will be closed.
    /// Must be >= keepAliveInterval.
    /// Default: 60 seconds
    public var keepAliveTimeout: Duration

    /// Enable automatic window size tuning based on RTT (B1).
    ///
    /// When enabled, receive windows grow automatically if the sender
    /// is being constrained by the window size.
    /// Default: true
    public var enableWindowAutoTuning: Bool

    /// Maximum receive window per stream when auto-tuning is enabled (B1).
    ///
    /// Limits how large the auto-tuned window can grow.
    /// Default: 16MB (same as yamuxMaxWindowSize)
    public var maxAutoTuneWindow: UInt32

    /// Creates a Yamux configuration.
    ///
    /// - Parameters:
    ///   - maxConcurrentStreams: Maximum concurrent streams (default: 1000)
    ///   - maxPendingInboundStreams: Maximum pending inbound streams (default: 100)
    ///   - initialWindowSize: Initial window size in bytes (default: 256KB)
    ///   - enableKeepAlive: Whether to enable keep-alive pings (default: true)
    ///   - keepAliveInterval: Interval between pings (default: 30 seconds)
    ///   - keepAliveTimeout: Timeout for ping responses (default: 60 seconds)
    ///   - enableWindowAutoTuning: Enable auto window tuning (default: true)
    ///   - maxAutoTuneWindow: Max window when auto-tuning (default: 16MB)
    public init(
        maxConcurrentStreams: Int = 1000,
        maxPendingInboundStreams: Int = 100,
        initialWindowSize: UInt32 = 256 * 1024,
        enableKeepAlive: Bool = true,
        keepAliveInterval: Duration = .seconds(30),
        keepAliveTimeout: Duration = .seconds(60),
        enableWindowAutoTuning: Bool = true,
        maxAutoTuneWindow: UInt32 = 16 * 1024 * 1024
    ) {
        precondition(keepAliveTimeout >= keepAliveInterval,
            "keepAliveTimeout must be >= keepAliveInterval")
        self.maxConcurrentStreams = maxConcurrentStreams
        self.maxPendingInboundStreams = maxPendingInboundStreams
        self.initialWindowSize = initialWindowSize
        self.enableKeepAlive = enableKeepAlive
        self.keepAliveInterval = keepAliveInterval
        self.keepAliveTimeout = keepAliveTimeout
        self.enableWindowAutoTuning = enableWindowAutoTuning
        self.maxAutoTuneWindow = maxAutoTuneWindow
    }

    /// Default configuration.
    public static let `default` = YamuxConfiguration()
}
