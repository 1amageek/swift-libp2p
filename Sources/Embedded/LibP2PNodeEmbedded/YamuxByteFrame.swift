// YamuxByteFrame.swift
// Embedded-clean Yamux frame codec over `[UInt8]`. Reimplements the proven
// 12-byte-header Yamux wire format (the host `YamuxFrame` logic) at a `[UInt8]`
// boundary — NO NIO `ByteBuffer`. This is the adapter wrapping the frame state
// machine's byte boundary the milestone calls for; the off-by-one of the
// length-prefixed framing is round-trip / fuzz tested in the host test target.
//
// Frame format (12-byte header):
// ```
//  0               1               2               3
//  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |   Version (8) |     Type (8)  |          Flags (16)          |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |                        Stream ID (32)                        |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// |                         Length (32)                          |
// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
// ```

/// Yamux protocol version.
public let yamuxByteVersion: UInt8 = 0

/// Yamux header size in bytes.
public let yamuxByteHeaderSize = 12

/// Maximum allowed Data-frame payload size (16 MiB) to bound memory (DoS).
public let yamuxByteMaxFrameSize: UInt32 = 16 * 1024 * 1024

/// Yamux frame types.
public enum YamuxByteFrameType: UInt8, Sendable, Equatable {
    case data = 0
    case windowUpdate = 1
    case ping = 2
    case goAway = 3
}

/// Yamux frame flags (bitset; multiple may be set).
public struct YamuxByteFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Stream open.
    public static let syn = YamuxByteFlags(rawValue: 0x0001)
    /// Stream acknowledge.
    public static let ack = YamuxByteFlags(rawValue: 0x0002)
    /// Half-close (FIN).
    public static let fin = YamuxByteFlags(rawValue: 0x0004)
    /// Reset stream.
    public static let rst = YamuxByteFlags(rawValue: 0x0008)
}

/// GoAway reason codes.
public enum YamuxByteGoAwayReason: UInt32, Sendable, Equatable {
    case normal = 0
    case protocolError = 1
    case internalError = 2
}

/// A decoded/encodable Yamux frame over `[UInt8]`.
public struct YamuxByteFrame: Sendable, Equatable {
    public let type: YamuxByteFrameType
    public let flags: YamuxByteFlags
    public let streamID: UInt32
    /// For Data frames this is the payload length; for windowUpdate the delta; for
    /// ping the opaque value; for goAway the reason code.
    public let length: UInt32
    /// The payload bytes (present only for Data frames).
    public let data: [UInt8]

    public init(
        type: YamuxByteFrameType,
        flags: YamuxByteFlags,
        streamID: UInt32,
        length: UInt32,
        data: [UInt8]
    ) {
        self.type = type
        self.flags = flags
        self.streamID = streamID
        self.length = length
        self.data = data
    }

    // MARK: - Constructors

    /// A Data frame carrying `payload`.
    public static func makeData(streamID: UInt32, flags: YamuxByteFlags, payload: [UInt8]) -> YamuxByteFrame {
        YamuxByteFrame(
            type: .data, flags: flags, streamID: streamID,
            length: UInt32(truncatingIfNeeded: payload.count), data: payload
        )
    }

    /// A window-update frame granting `delta` bytes.
    public static func makeWindowUpdate(streamID: UInt32, delta: UInt32) -> YamuxByteFrame {
        YamuxByteFrame(type: .windowUpdate, flags: [], streamID: streamID, length: delta, data: [])
    }

    /// A ping frame (request or, with `.ack`, response).
    public static func makePing(opaque: UInt32, ack: Bool) -> YamuxByteFrame {
        YamuxByteFrame(type: .ping, flags: ack ? .ack : [], streamID: 0, length: opaque, data: [])
    }

    /// A go-away frame signalling session termination.
    public static func makeGoAway(reason: YamuxByteGoAwayReason) -> YamuxByteFrame {
        YamuxByteFrame(type: .goAway, flags: [], streamID: 0, length: reason.rawValue, data: [])
    }

    // MARK: - Encoding

    /// Encodes the frame (12-byte header + optional payload) to `[UInt8]`.
    public func encode() -> [UInt8] {
        let payloadSize = type == .data ? data.count : 0
        var out = [UInt8]()
        out.reserveCapacity(yamuxByteHeaderSize + payloadSize)
        out.append(yamuxByteVersion)
        out.append(type.rawValue)
        out.append(UInt8(truncatingIfNeeded: flags.rawValue >> 8))
        out.append(UInt8(truncatingIfNeeded: flags.rawValue))
        out.append(UInt8(truncatingIfNeeded: streamID >> 24))
        out.append(UInt8(truncatingIfNeeded: streamID >> 16))
        out.append(UInt8(truncatingIfNeeded: streamID >> 8))
        out.append(UInt8(truncatingIfNeeded: streamID))
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        if type == .data && !data.isEmpty {
            out.append(contentsOf: data)
        }
        return out
    }

    // MARK: - Decoding

    /// The outcome of decoding from a buffer.
    public enum DecodeOutcome: Sendable, Equatable {
        /// A complete frame was decoded; `consumed` bytes were used from the front.
        case frame(YamuxByteFrame, consumed: Int)
        /// The buffer does not yet hold a full frame; read more bytes.
        case needMoreData
    }

    /// Decodes one frame from `bytes` starting at `offset`.
    ///
    /// Bounds-checked: a Data-frame length over ``yamuxByteMaxFrameSize`` is
    /// rejected before any slicing; a short buffer returns `.needMoreData`.
    ///
    /// - Throws: ``EmbeddedNodeError/yamuxProtocolError`` on a bad version/type,
    ///   ``EmbeddedNodeError/yamuxFrameTooLarge`` on an oversize Data frame.
    public static func decode(
        from bytes: [UInt8], at offset: Int = 0
    ) throws(EmbeddedNodeError) -> DecodeOutcome {
        guard offset >= 0, offset <= bytes.count else {
            throw .yamuxProtocolError
        }
        guard bytes.count - offset >= yamuxByteHeaderSize else {
            return .needMoreData
        }

        let version = bytes[offset]
        let typeRaw = bytes[offset + 1]
        let flagsRaw = (UInt16(bytes[offset + 2]) << 8) | UInt16(bytes[offset + 3])
        let streamID =
            (UInt32(bytes[offset + 4]) << 24) |
            (UInt32(bytes[offset + 5]) << 16) |
            (UInt32(bytes[offset + 6]) << 8) |
            UInt32(bytes[offset + 7])
        let length =
            (UInt32(bytes[offset + 8]) << 24) |
            (UInt32(bytes[offset + 9]) << 16) |
            (UInt32(bytes[offset + 10]) << 8) |
            UInt32(bytes[offset + 11])

        guard version == yamuxByteVersion else {
            throw .yamuxProtocolError
        }
        guard let type = YamuxByteFrameType(rawValue: typeRaw) else {
            throw .yamuxProtocolError
        }
        let flags = YamuxByteFlags(rawValue: flagsRaw)

        // Only Data frames carry payload.
        if type == .data {
            guard length <= yamuxByteMaxFrameSize else {
                throw .yamuxFrameTooLarge
            }
        }
        let payloadLength = type == .data ? Int(length) : 0

        let total = yamuxByteHeaderSize + payloadLength
        guard bytes.count - offset >= total else {
            return .needMoreData
        }

        let payload: [UInt8]
        if payloadLength > 0 {
            let start = offset + yamuxByteHeaderSize
            payload = Array(bytes[start..<(start + payloadLength)])
        } else {
            payload = []
        }

        let frame = YamuxByteFrame(
            type: type, flags: flags, streamID: streamID, length: length, data: payload
        )
        return .frame(frame, consumed: total)
    }
}
