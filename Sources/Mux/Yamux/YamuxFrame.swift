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
    let data: Data?

    /// Creates a data frame.
    static func data(streamID: UInt32, flags: YamuxFlags = [], data: Data) -> YamuxFrame {
        YamuxFrame(type: .data, flags: flags, streamID: streamID, length: UInt32(data.count), data: data)
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

    /// Encodes the frame to bytes.
    func encode() -> Data {
        var result = Data(capacity: yamuxHeaderSize + Int(length))

        // Build 12-byte header in one batch
        let header: [UInt8] = [
            yamuxVersion,
            type.rawValue,
            UInt8(flags.rawValue >> 8),
            UInt8(flags.rawValue & 0xFF),
            UInt8((streamID >> 24) & 0xFF),
            UInt8((streamID >> 16) & 0xFF),
            UInt8((streamID >> 8) & 0xFF),
            UInt8(streamID & 0xFF),
            UInt8((length >> 24) & 0xFF),
            UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF),
            UInt8(length & 0xFF),
        ]
        result.append(contentsOf: header)

        // Data (if present)
        if let data = data {
            result.append(data)
        }

        return result
    }

    /// Decodes a frame from bytes.
    ///
    /// - Returns: The frame and number of bytes consumed, or nil if more data is needed
    /// - Throws: `YamuxError` if the frame is malformed
    static func decode(from data: Data) throws -> (frame: YamuxFrame, bytesRead: Int)? {
        guard data.count >= yamuxHeaderSize else {
            return nil
        }

        // Parse header using pointer access to avoid repeated bounds checks
        let (version, typeRaw, flags, streamID, length): (UInt8, UInt8, YamuxFlags, UInt32, UInt32) =
            data.withUnsafeBytes { ptr in
                let b = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let v = b[0]
                let t = b[1]
                let f = YamuxFlags(rawValue: (UInt16(b[2]) << 8) | UInt16(b[3]))
                let s = (UInt32(b[4]) << 24) | (UInt32(b[5]) << 16) | (UInt32(b[6]) << 8) | UInt32(b[7])
                let l = (UInt32(b[8]) << 24) | (UInt32(b[9]) << 16) | (UInt32(b[10]) << 8) | UInt32(b[11])
                return (v, t, f, s, l)
            }

        guard version == yamuxVersion else {
            throw YamuxError.invalidVersion(version)
        }

        guard let type = YamuxFrameType(rawValue: typeRaw) else {
            throw YamuxError.invalidFrameType(typeRaw)
        }

        // Only Data frames have actual payload data.
        // For WindowUpdate, Ping, and GoAway, the length field stores
        // a semantic value (delta, opaque value, or error code), not data length.
        let payloadLength = type == .data ? Int(length) : 0

        // Validate frame size to prevent memory exhaustion attacks
        if type == .data && length > yamuxMaxFrameSize {
            throw YamuxError.frameTooLarge(size: length, max: yamuxMaxFrameSize)
        }
        let totalSize = yamuxHeaderSize + payloadLength
        guard data.count >= totalSize else {
            return nil
        }

        var frameData: Data?
        if type == .data && length > 0 {
            let dataStart = data.startIndex + yamuxHeaderSize
            frameData = Data(data[dataStart..<(dataStart + Int(length))])
        }

        let frame = YamuxFrame(
            type: type,
            flags: flags,
            streamID: streamID,
            length: length,
            data: frameData
        )

        return (frame, totalSize)
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

    /// Creates a Yamux configuration.
    ///
    /// - Parameters:
    ///   - maxConcurrentStreams: Maximum concurrent streams (default: 1000)
    ///   - maxPendingInboundStreams: Maximum pending inbound streams (default: 100)
    ///   - initialWindowSize: Initial window size in bytes (default: 256KB)
    ///   - enableKeepAlive: Whether to enable keep-alive pings (default: true)
    ///   - keepAliveInterval: Interval between pings (default: 30 seconds)
    ///   - keepAliveTimeout: Timeout for ping responses (default: 60 seconds)
    public init(
        maxConcurrentStreams: Int = 1000,
        maxPendingInboundStreams: Int = 100,
        initialWindowSize: UInt32 = 256 * 1024,
        enableKeepAlive: Bool = true,
        keepAliveInterval: Duration = .seconds(30),
        keepAliveTimeout: Duration = .seconds(60)
    ) {
        precondition(keepAliveTimeout >= keepAliveInterval,
            "keepAliveTimeout must be >= keepAliveInterval")
        self.maxConcurrentStreams = maxConcurrentStreams
        self.maxPendingInboundStreams = maxPendingInboundStreams
        self.initialWindowSize = initialWindowSize
        self.enableKeepAlive = enableKeepAlive
        self.keepAliveInterval = keepAliveInterval
        self.keepAliveTimeout = keepAliveTimeout
    }

    /// Default configuration.
    public static let `default` = YamuxConfiguration()
}
