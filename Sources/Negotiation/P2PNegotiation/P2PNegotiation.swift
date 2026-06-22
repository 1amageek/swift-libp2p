/// P2PNegotiation - Protocol negotiation for swift-libp2p
///
/// Implements multistream-select for protocol negotiation.
/// https://github.com/multiformats/multistream-select

import Foundation
import P2PCore

/// The result of a protocol negotiation.
public struct NegotiationResult: Sendable {
    /// The agreed-upon protocol.
    public let protocolID: String

    /// Any remaining data after negotiation.
    public let remainderBuffer: ByteBuffer

    public var remainder: Data {
        Data(buffer: remainderBuffer)
    }

    public init(protocolID: String, remainderBuffer: ByteBuffer = ByteBuffer()) {
        self.protocolID = protocolID
        self.remainderBuffer = remainderBuffer
    }

    public init(protocolID: String, remainder: Data) {
        self.init(protocolID: protocolID, remainderBuffer: ByteBuffer(bytes: remainder))
    }
}

/// Multistream-select protocol negotiation.
public enum MultistreamSelect {

    /// The multistream-select protocol ID.
    public static let protocolID = "/multistream/1.0.0"

    /// Maximum message size for multistream-select (64KB).
    /// Protocol IDs are typically short strings, so this is very generous.
    public static let maxMessageSize = 64 * 1024

    /// Bounds applied to the responder-side negotiation phase to prevent a peer
    /// from holding negotiation open indefinitely or amplifying output via
    /// repeated `ls` requests (the negotiation phase runs PRE-authentication).
    public struct HandleLimits: Sendable {
        /// Maximum number of negotiation attempts (protocol/ls/na rounds).
        /// Bounds CPU spent on unsupported-protocol spam.
        public var maxAttempts: Int

        /// Maximum total number of bytes the responder will READ during the
        /// negotiation phase. Bounds memory/time a peer can consume by dribbling
        /// fragments or sending oversized junk before agreement.
        public var maxReceivedBytes: Int

        /// Maximum number of `ls` (list-protocols) responses the responder will
        /// serve. Each `ls` reply serializes the full supported-protocol list, so
        /// without this bound a peer could request `ls` repeatedly to amplify our
        /// outbound bytes pre-authentication.
        public var maxListResponses: Int

        /// Wall-clock deadline for the entire negotiation phase. A peer cannot
        /// hold the negotiation open past this duration.
        public var deadline: Duration

        public init(
            maxAttempts: Int = 1000,
            maxReceivedBytes: Int = 1 << 20,  // 1 MiB
            maxListResponses: Int = 8,
            deadline: Duration = .seconds(60)
        ) {
            self.maxAttempts = maxAttempts
            self.maxReceivedBytes = maxReceivedBytes
            self.maxListResponses = maxListResponses
            self.deadline = deadline
        }

        public static let `default` = HandleLimits()
    }

    /// Negotiates a protocol as the initiator (dialer).
    ///
    /// - Parameters:
    ///   - protocols: The protocols to try, in order of preference
    ///   - read: Function to read data
    ///   - write: Function to write data
    /// - Returns: The negotiation result
    public static func negotiate(
        protocols: [String],
        read: () async throws -> ByteBuffer,
        write: (ByteBuffer) async throws -> Void
    ) async throws -> NegotiationResult {
        var buffer = ByteBuffer()

        // Send multistream header
        try await write(encode(protocolID))

        // Read multistream header response
        let (headerString, headerConsumed) = try await readNextMessage(
            buffer: &buffer,
            read: read
        )
        guard headerString == protocolID else {
            throw NegotiationError.protocolMismatch
        }
        drain(&buffer, consumed: headerConsumed)

        // Try each protocol
        for proto in protocols {
            try await write(encode(proto))
            let (decoded, consumed) = try await readNextMessage(
                buffer: &buffer,
                read: read
            )
            drain(&buffer, consumed: consumed)

            if decoded == proto {
                return NegotiationResult(protocolID: proto, remainderBuffer: buffer)
            } else if decoded == "na" {
                continue
            } else {
                throw NegotiationError.unexpectedResponse(decoded)
            }
        }

        throw NegotiationError.noAgreement
    }

    public static func negotiate(
        protocols: [String],
        read: () async throws -> Data,
        write: (Data) async throws -> Void
    ) async throws -> NegotiationResult {
        try await negotiate(
            protocols: protocols,
            read: { ByteBuffer(bytes: try await read()) },
            write: { try await write(Data(buffer: $0)) }
        )
    }

    /// Negotiates a protocol using V1Lazy (0-RTT optimization).
    ///
    /// V1Lazy sends the multistream header and preferred protocol in a single
    /// message, reducing latency from 2 RTT to 1 RTT when the first protocol
    /// is accepted. If rejected, falls back to standard V1 negotiation.
    ///
    /// Use this when:
    /// - You have a single preferred protocol (e.g., `/yamux/1.0.0`)
    /// - Latency is important
    /// - The responder is likely to support your preferred protocol
    ///
    /// - Parameters:
    ///   - protocols: The protocols to try, in order of preference
    ///   - read: Function to read data
    ///   - write: Function to write data
    /// - Returns: The negotiation result
    public static func negotiateLazy(
        protocols: [String],
        read: () async throws -> ByteBuffer,
        write: (ByteBuffer) async throws -> Void
    ) async throws -> NegotiationResult {
        guard !protocols.isEmpty else {
            throw NegotiationError.noAgreement
        }

        let firstProtocol = protocols[0]

        // V1Lazy: Send header + first protocol in one batch
        var batch = encode(protocolID)
        var firstProtocolMessage = encode(firstProtocol)
        batch.writeBuffer(&firstProtocolMessage)
        try await write(batch)

        // Read response — may contain header + protocol response coalesced or fragmented
        var buffer = ByteBuffer()
        let (headerString, headerConsumed) = try await readNextMessage(
            buffer: &buffer,
            read: read
        )
        guard headerString == protocolID else {
            throw NegotiationError.protocolMismatch
        }
        drain(&buffer, consumed: headerConsumed)

        // Read protocol response (may already be in buffer from coalesced read)
        let (decoded, consumed) = try await readNextMessage(
            buffer: &buffer,
            read: read
        )
        drain(&buffer, consumed: consumed)

        if decoded == firstProtocol {
            // First protocol accepted - 1 RTT success!
            return NegotiationResult(protocolID: firstProtocol, remainderBuffer: buffer)
        } else if decoded == "na" {
            // First protocol rejected - fall back to remaining protocols
            for proto in protocols.dropFirst() {
                try await write(encode(proto))
                let (responseDecoded, responseConsumed) = try await readNextMessage(
                    buffer: &buffer,
                    read: read
                )
                drain(&buffer, consumed: responseConsumed)

                if responseDecoded == proto {
                    return NegotiationResult(protocolID: proto, remainderBuffer: buffer)
                } else if responseDecoded == "na" {
                    continue
                } else {
                    throw NegotiationError.unexpectedResponse(responseDecoded)
                }
            }
            throw NegotiationError.noAgreement
        } else {
            throw NegotiationError.unexpectedResponse(decoded)
        }
    }

    public static func negotiateLazy(
        protocols: [String],
        read: () async throws -> Data,
        write: (Data) async throws -> Void
    ) async throws -> NegotiationResult {
        try await negotiateLazy(
            protocols: protocols,
            read: { ByteBuffer(bytes: try await read()) },
            write: { try await write(Data(buffer: $0)) }
        )
    }

    /// Handles protocol negotiation as the responder (listener).
    ///
    /// This method loops until a protocol is agreed upon, the connection closes,
    /// or one of the negotiation-phase bounds in `limits` is exceeded. The bounds
    /// are mandatory here because negotiation runs PRE-authentication: a remote
    /// peer must not be able to hold the negotiation open indefinitely, dribble
    /// fragments forever, or amplify our outbound traffic via repeated `ls`.
    ///
    /// - Parameters:
    ///   - supported: The protocols we support
    ///   - limits: Negotiation-phase resource bounds (attempts, received bytes,
    ///     `ls` responses, wall-clock deadline)
    ///   - read: Function to read data
    ///   - write: Function to write data
    /// - Returns: The negotiation result
    public static func handle(
        supported: [String],
        limits: HandleLimits = .default,
        read: () async throws -> ByteBuffer,
        write: (ByteBuffer) async throws -> Void
    ) async throws -> NegotiationResult {
        let supportedSet = Set(supported)

        // Negotiation-phase wall-clock deadline. Checked after every read so a
        // peer cannot hold negotiation open by dribbling fragments or looping
        // unsupported-protocol requests. The closures are intentionally NOT
        // escaped into a concurrent task (they capture caller-local buffers), so
        // a single read() that blocks forever is bounded by the transport-level
        // read timeout per the libp2p spec; this deadline bounds everything that
        // makes incremental progress.
        let clock = ContinuousClock()
        let deadlineInstant = clock.now.advanced(by: limits.deadline)

        // Wrap read() to enforce both the total received-byte cap (bounds dribble
        // / oversized-junk attacks) and the deadline (bounds slow progress).
        var receivedBytes = 0
        let countedRead: () async throws -> ByteBuffer = {
            let chunk = try await read()
            if clock.now >= deadlineInstant {
                throw NegotiationError.negotiationTimeout
            }
            receivedBytes += chunk.readableBytes
            if receivedBytes > limits.maxReceivedBytes {
                throw NegotiationError.negotiationBudgetExceeded
            }
            return chunk
        }

        // Read and respond to multistream header
        // Buffer handles coalesced TCP reads (e.g., V1Lazy sends header + protocol in one write)
        var buffer = ByteBuffer()
        let (headerString, headerConsumed) = try await readNextMessage(
            buffer: &buffer,
            read: countedRead
        )
        guard headerString == protocolID else {
            throw NegotiationError.protocolMismatch
        }
        drain(&buffer, consumed: headerConsumed)
        try await write(encode(protocolID))

        // Handle protocol requests until agreement or connection close.
        // Iteration limit prevents DoS via unlimited unsupported protocol requests;
        // the ls-response limit prevents pre-auth output amplification.
        var attempts = 0
        var listResponses = 0
        while true {
            try Task.checkCancellation()  // honor external cancellation

            attempts += 1
            if attempts > limits.maxAttempts {
                throw NegotiationError.tooManyAttempts
            }

            let (requested, consumed) = try await readNextMessage(
                buffer: &buffer,
                read: countedRead
            )
            drain(&buffer, consumed: consumed)

            if supportedSet.contains(requested) {
                try await write(encode(requested))
                return NegotiationResult(protocolID: requested, remainderBuffer: buffer)
            } else if requested == "ls" {
                // Each ls reply serializes the full supported-protocol list, so
                // cap the number served to prevent pre-auth amplification.
                listResponses += 1
                if listResponses > limits.maxListResponses {
                    throw NegotiationError.negotiationBudgetExceeded
                }
                // ls response must be newline-delimited protocol IDs inside a single
                // multistream length prefix (no nested per-protocol varints).
                // Keep the historical trailing blank line for compatibility.
                let body = supported.map { "\($0)\n" }.joined() + "\n"
                var response = ByteBuffer()
                response.writeBytes(Varint.encode(UInt64(body.utf8.count)))
                response.writeString(body)
                try await write(response)
            } else {
                try await write(encode("na"))
            }
        }
    }

    public static func handle(
        supported: [String],
        limits: HandleLimits = .default,
        read: () async throws -> Data,
        write: (Data) async throws -> Void
    ) async throws -> NegotiationResult {
        try await handle(
            supported: supported,
            limits: limits,
            read: { ByteBuffer(bytes: try await read()) },
            write: { try await write(Data(buffer: $0)) }
        )
    }

    // MARK: - Internal Decoding

    private enum DecodeAttempt {
        case message(String, consumed: Int)
        case needMoreData
    }

    private static func decodeAttempt(_ data: ByteBuffer) throws -> DecodeAttempt {
        let (length, lengthBytes) = try data.withUnsafeReadableBytes { ptr in
            try Varint.decode(from: UnsafeRawBufferPointer(ptr), at: 0)
        }

        // Validate message size to prevent memory exhaustion attacks
        guard length <= UInt64(Int.max) else {
            throw NegotiationError.messageTooLarge(size: Int.max, max: maxMessageSize)
        }
        let messageLength = Int(length)
        if messageLength > maxMessageSize {
            throw NegotiationError.messageTooLarge(size: messageLength, max: maxMessageSize)
        }

        let totalConsumed = lengthBytes + messageLength
        guard data.readableBytes >= totalConsumed else {
            return .needMoreData
        }
        let contentIndex = data.readerIndex + lengthBytes
        guard
            let bytes = data.getBytes(at: contentIndex, length: messageLength),
            var string = String(bytes: bytes, encoding: .utf8)
        else {
            throw NegotiationError.invalidUtf8
        }

        // Multistream-select spec requires messages to end with newline
        guard string.hasSuffix("\n") else {
            throw NegotiationError.invalidMessage
        }
        string.removeLast()

        return .message(string, consumed: totalConsumed)
    }

    private static func readNextMessage(
        buffer: inout ByteBuffer,
        read: () async throws -> ByteBuffer
    ) async throws -> (String, Int) {
        while true {
            do {
                let attempt = try decodeAttempt(buffer)
                switch attempt {
                case .message(let string, let consumed):
                    return (string, consumed)
                case .needMoreData:
                    var chunk = try await read()
                    guard chunk.readableBytes > 0 else {
                        throw NegotiationError.invalidMessage
                    }
                    buffer.writeBuffer(&chunk)
                }
            } catch VarintError.insufficientData {
                var chunk = try await read()
                guard chunk.readableBytes > 0 else {
                    throw NegotiationError.invalidMessage
                }
                buffer.writeBuffer(&chunk)
            }
        }
    }

    // MARK: - Encoding

    /// Encodes a protocol string for multistream-select.
    public static func encode(_ string: String) -> ByteBuffer {
        let payload = string + "\n"
        var buffer = ByteBuffer()
        buffer.writeBytes(Varint.encode(UInt64(payload.utf8.count)))
        buffer.writeString(payload)
        return buffer
    }

    /// Decodes a protocol string from multistream-select format.
    ///
    /// - Parameter data: The length-prefixed data to decode
    /// - Returns: The decoded protocol string and number of bytes consumed
    /// - Throws: `NegotiationError` or `VarintError` if decoding fails
    public static func decode(_ data: ByteBuffer) throws -> (String, Int) {
        let attempt = try decodeAttempt(data)
        guard case .message(let string, let consumed) = attempt else {
            throw NegotiationError.invalidMessage
        }
        return (string, consumed)
    }

    private static func drain(_ buffer: inout ByteBuffer, consumed: Int) {
        buffer.moveReaderIndex(forwardBy: consumed)
        buffer.discardReadBytes()
    }
}

public enum NegotiationError: Error, Equatable {
    case protocolMismatch
    case noAgreement
    case unexpectedResponse(String)
    case invalidMessage
    case invalidUtf8
    case messageTooLarge(size: Int, max: Int)
    case tooManyAttempts
    /// A negotiation-phase resource budget was exceeded (received-byte cap or
    /// `ls`-response cap). Prevents pre-authentication amplification / hold-open.
    case negotiationBudgetExceeded
    /// The negotiation phase exceeded its wall-clock deadline.
    case negotiationTimeout
}
