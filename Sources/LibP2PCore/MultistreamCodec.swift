/// multistream-select line-protocol codec (Embedded-clean).
/// https://github.com/multiformats/multistream-select
///
/// Embedded-clean: no Foundation, no NIO, no `any`. This is the wire codec for a
/// single multistream-select message — a varint-length-prefixed, `\n`-terminated
/// UTF-8 protocol-id token — plus the `ls` (list-protocols) response body. The
/// async negotiation drivers (`negotiate`/`handle`/`negotiateLazy`, the read loop
/// over `ByteBuffer`, the wall-clock deadline) stay in the `P2PNegotiation`
/// adapter; only the pure byte framing lives here.
///
/// Wire format of one message:
/// ```
/// varint(len) || utf8-token || 0x0A
/// ```
/// where `len` counts the token bytes plus the trailing `\n`. The decoded token
/// has the trailing `\n` stripped. `ls` and `na` are ordinary tokens.

public enum MultistreamCodec {

    /// The multistream-select protocol ID.
    public static let protocolID = "/multistream/1.0.0"

    /// Maximum message size for multistream-select (64 KiB).
    ///
    /// Protocol IDs are short strings, so this is generous. The bound prevents a
    /// peer from forcing an oversized allocation pre-authentication (a 0.2.0
    /// security bound: see `messageTooLarge`).
    public static let maxMessageSize = 64 * 1024

    // MARK: - Decode outcome

    /// The result of attempting to decode one message from a byte buffer.
    public enum DecodeOutcome: Sendable, Equatable {
        /// A complete message was decoded: the token (trailing `\n` stripped) and
        /// the total number of bytes consumed (length prefix + token + `\n`).
        case message(token: String, consumed: Int)
        /// The buffer does not yet hold a complete message; read more bytes.
        case needMoreData
    }

    // MARK: - Encoding

    /// Encodes a token as a multistream-select message: `varint(len) || token || \n`.
    ///
    /// - Parameter token: The protocol-id token (e.g. `/noise`, `ls`, `na`).
    /// - Returns: The framed message bytes.
    public static func encode(_ token: String) -> [UInt8] {
        var payload = [UInt8](token.utf8)
        payload.append(0x0A) // '\n'
        var result = Varint.encodeBytes(UInt64(payload.count))
        result.append(contentsOf: payload)
        return result
    }

    /// Encodes an `ls` response body for the given supported protocols.
    ///
    /// The body is the newline-delimited protocol IDs wrapped in a single
    /// multistream length prefix (no nested per-protocol varints), keeping the
    /// historical trailing blank line for compatibility:
    /// ```
    /// varint(len) || ("<p1>\n<p2>\n...\n")
    /// ```
    ///
    /// - Parameter protocols: The supported protocol IDs, in order.
    /// - Returns: The framed `ls` response bytes.
    public static func encodeListResponse(_ protocols: [String]) -> [UInt8] {
        var body = [UInt8]()
        for proto in protocols {
            body.append(contentsOf: proto.utf8)
            body.append(0x0A) // '\n'
        }
        body.append(0x0A) // trailing blank line
        var result = Varint.encodeBytes(UInt64(body.count))
        result.append(contentsOf: body)
        return result
    }

    // MARK: - Decoding

    /// Attempts to decode one message from `bytes` starting at `offset`.
    ///
    /// Bounds-checked and strict-UTF-8: a token whose bytes are not valid UTF-8
    /// is rejected (`.invalidUtf8`), and a message without a trailing `\n` is
    /// rejected (`.missingNewline`). A declared length exceeding `maxMessageSize`
    /// is rejected (`.messageTooLarge`) before any allocation. When the buffer is
    /// shorter than the declared message, `.needMoreData` is returned rather than
    /// an error so the caller can read more.
    ///
    /// - Parameters:
    ///   - bytes: Source bytes.
    ///   - offset: Byte offset to start decoding from.
    ///   - maxMessageSize: Reject messages whose declared length exceeds this.
    /// - Returns: A `DecodeOutcome` (`.message` or `.needMoreData`).
    /// - Throws: `MultistreamCodecError` on malformed or oversized input.
    public static func decode(
        from bytes: [UInt8],
        at offset: Int = 0,
        maxMessageSize: Int = MultistreamCodec.maxMessageSize
    ) throws(MultistreamCodecError) -> DecodeOutcome {
        guard offset >= 0, offset <= bytes.count else {
            throw .truncated
        }

        let length: UInt64
        let lengthBytes: Int
        do {
            (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
        } catch {
            // `error` is bound as `VarintError` here (typed throws). Use a bare
            // `catch`+`switch` rather than `catch let _ as VarintError`, which
            // crashes SILGen on the current toolchain (see EMBEDDED notes).
            switch error {
            case .insufficientData:
                // Not enough bytes yet for a complete length prefix.
                return .needMoreData
            case .overflow, .valueExceedsIntMax:
                // A malformed/overflowing length-prefix varint (e.g. >10 bytes).
                // Distinct from a well-formed-but-too-large length, so callers
                // can surface it as a varint error rather than a size error.
                throw .invalidLengthPrefix
            }
        }

        // Bound the declared length before allocating / slicing.
        guard length <= UInt64(Int.max) else {
            throw .messageTooLarge(size: Int.max, max: maxMessageSize)
        }
        let messageLength = Int(length)
        guard messageLength <= maxMessageSize else {
            throw .messageTooLarge(size: messageLength, max: maxMessageSize)
        }

        let contentStart = offset + lengthBytes
        let totalConsumed = lengthBytes + messageLength
        guard offset + totalConsumed <= bytes.count else {
            return .needMoreData
        }

        // The message body must end with a newline per the multistream spec.
        let contentEnd = contentStart + messageLength
        guard messageLength >= 1, bytes[contentEnd - 1] == 0x0A else {
            throw .missingNewline
        }

        // Strict UTF-8 validation over the token (newline excluded).
        let tokenBytes = Array(bytes[contentStart..<(contentEnd - 1)])
        guard let token = decodeUTF8Strict(tokenBytes) else {
            throw .invalidUtf8
        }

        return .message(token: token, consumed: totalConsumed)
    }
}

/// Errors from the multistream-select message codec.
public enum MultistreamCodecError: Error, Equatable, Sendable {
    /// The buffer ended before a complete length prefix could be read.
    case truncated
    /// The length-prefix varint is malformed (overflows / exceeds 10 bytes).
    case invalidLengthPrefix
    /// The token bytes are not valid UTF-8.
    case invalidUtf8
    /// The message body does not end with a newline.
    case missingNewline
    /// The declared message length exceeds the allowed maximum.
    case messageTooLarge(size: Int, max: Int)
}
