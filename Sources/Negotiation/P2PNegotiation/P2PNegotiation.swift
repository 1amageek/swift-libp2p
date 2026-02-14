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
    public let remainder: Data

    public init(protocolID: String, remainder: Data = Data()) {
        self.protocolID = protocolID
        self.remainder = remainder
    }
}

/// Multistream-select protocol negotiation.
public enum MultistreamSelect {

    /// The multistream-select protocol ID.
    public static let protocolID = "/multistream/1.0.0"

    /// Maximum message size for multistream-select (64KB).
    /// Protocol IDs are typically short strings, so this is very generous.
    public static let maxMessageSize = 64 * 1024

    /// Negotiates a protocol as the initiator (dialer).
    ///
    /// - Parameters:
    ///   - protocols: The protocols to try, in order of preference
    ///   - read: Function to read data
    ///   - write: Function to write data
    /// - Returns: The negotiation result
    public static func negotiate(
        protocols: [String],
        read: () async throws -> Data,
        write: (Data) async throws -> Void
    ) async throws -> NegotiationResult {
        var buffer = Data()

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
        buffer = Data(buffer.dropFirst(headerConsumed))

        // Try each protocol
        for proto in protocols {
            try await write(encode(proto))
            let (decoded, consumed) = try await readNextMessage(
                buffer: &buffer,
                read: read
            )
            buffer = Data(buffer.dropFirst(consumed))

            if decoded == proto {
                return NegotiationResult(protocolID: proto, remainder: buffer)
            } else if decoded == "na" {
                continue
            } else {
                throw NegotiationError.unexpectedResponse(decoded)
            }
        }

        throw NegotiationError.noAgreement
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
        read: () async throws -> Data,
        write: (Data) async throws -> Void
    ) async throws -> NegotiationResult {
        guard !protocols.isEmpty else {
            throw NegotiationError.noAgreement
        }

        let firstProtocol = protocols[0]

        // V1Lazy: Send header + first protocol in one batch
        var batch = encode(protocolID)
        batch.append(encode(firstProtocol))
        try await write(batch)

        // Read response — may contain header + protocol response coalesced or fragmented
        var buffer = Data()
        let (headerString, headerConsumed) = try await readNextMessage(
            buffer: &buffer,
            read: read
        )
        guard headerString == protocolID else {
            throw NegotiationError.protocolMismatch
        }
        buffer = Data(buffer.dropFirst(headerConsumed))

        // Read protocol response (may already be in buffer from coalesced read)
        let (decoded, consumed) = try await readNextMessage(
            buffer: &buffer,
            read: read
        )
        buffer = Data(buffer.dropFirst(consumed))

        if decoded == firstProtocol {
            // First protocol accepted - 1 RTT success!
            return NegotiationResult(protocolID: firstProtocol, remainder: buffer)
        } else if decoded == "na" {
            // First protocol rejected - fall back to remaining protocols
            for proto in protocols.dropFirst() {
                try await write(encode(proto))
                let (responseDecoded, responseConsumed) = try await readNextMessage(
                    buffer: &buffer,
                    read: read
                )
                buffer = Data(buffer.dropFirst(responseConsumed))

                if responseDecoded == proto {
                    return NegotiationResult(protocolID: proto, remainder: buffer)
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

    /// Handles protocol negotiation as the responder (listener).
    ///
    /// This method loops until a protocol is agreed upon or the connection
    /// closes. Timeouts should be handled at the transport level, following
    /// the multistream-select specification and rust-libp2p/go-libp2p behavior.
    ///
    /// - Parameters:
    ///   - supported: The protocols we support
    ///   - read: Function to read data
    ///   - write: Function to write data
    /// - Returns: The negotiation result
    public static func handle(
        supported: [String],
        read: () async throws -> Data,
        write: (Data) async throws -> Void
    ) async throws -> NegotiationResult {
        let supportedSet = Set(supported)

        // Read and respond to multistream header
        // Buffer handles coalesced TCP reads (e.g., V1Lazy sends header + protocol in one write)
        var buffer = Data()
        let (headerString, headerConsumed) = try await readNextMessage(
            buffer: &buffer,
            read: read
        )
        guard headerString == protocolID else {
            throw NegotiationError.protocolMismatch
        }
        buffer = Data(buffer.dropFirst(headerConsumed))
        try await write(encode(protocolID))

        // Handle protocol requests until agreement or connection close
        // Timeouts are handled at the transport level per libp2p spec
        // Iteration limit prevents DoS via unlimited unsupported protocol requests
        let maxNegotiationAttempts = 1000
        var attempts = 0
        while true {
            attempts += 1
            if attempts > maxNegotiationAttempts {
                throw NegotiationError.tooManyAttempts
            }

            let (requested, consumed) = try await readNextMessage(
                buffer: &buffer,
                read: read
            )
            buffer = Data(buffer.dropFirst(consumed))

            if supportedSet.contains(requested) {
                try await write(encode(requested))
                return NegotiationResult(protocolID: requested, remainder: buffer)
            } else if requested == "ls" {
                // ls response must be newline-delimited protocol IDs inside a single
                // multistream length prefix (no nested per-protocol varints).
                // Keep the historical trailing blank line for compatibility.
                let body = supported.map { "\($0)\n" }.joined() + "\n"
                let payload = Data(body.utf8)
                var response = Varint.encode(UInt64(payload.count))
                response.append(payload)
                try await write(response)
            } else {
                try await write(encode("na"))
            }
        }
    }

    // MARK: - Internal Decoding

    private enum DecodeAttempt {
        case message(String, consumed: Int)
        case needMoreData
    }

    private static func decodeAttempt(_ data: Data) throws -> DecodeAttempt {
        let (length, lengthBytes) = try Varint.decode(data)

        // Validate message size to prevent memory exhaustion attacks
        guard length <= UInt64(Int.max) else {
            throw NegotiationError.messageTooLarge(size: Int.max, max: maxMessageSize)
        }
        let messageLength = Int(length)
        if messageLength > maxMessageSize {
            throw NegotiationError.messageTooLarge(size: messageLength, max: maxMessageSize)
        }

        let totalConsumed = lengthBytes + messageLength
        guard data.count >= totalConsumed else {
            return .needMoreData
        }
        let content = data.dropFirst(lengthBytes).prefix(messageLength)

        // Use strict UTF-8 decoding to reject invalid sequences
        guard var string = String(data: Data(content), encoding: .utf8) else {
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
        buffer: inout Data,
        read: () async throws -> Data
    ) async throws -> (String, Int) {
        while true {
            do {
                let attempt = try decodeAttempt(buffer)
                switch attempt {
                case .message(let string, let consumed):
                    return (string, consumed)
                case .needMoreData:
                    let chunk = try await read()
                    guard !chunk.isEmpty else {
                        throw NegotiationError.invalidMessage
                    }
                    buffer.append(chunk)
                }
            } catch VarintError.insufficientData {
                let chunk = try await read()
                guard !chunk.isEmpty else {
                    throw NegotiationError.invalidMessage
                }
                buffer.append(chunk)
            }
        }
    }

    // MARK: - Encoding

    /// Encodes a protocol string for multistream-select.
    public static func encode(_ string: String) -> Data {
        let bytes = Data((string + "\n").utf8)
        return Varint.encode(UInt64(bytes.count)) + bytes
    }

    /// Decodes a protocol string from multistream-select format.
    ///
    /// - Parameter data: The length-prefixed data to decode
    /// - Returns: The decoded protocol string and number of bytes consumed
    /// - Throws: `NegotiationError` or `VarintError` if decoding fails
    public static func decode(_ data: Data) throws -> (String, Int) {
        let attempt = try decodeAttempt(data)
        guard case .message(let string, let consumed) = attempt else {
            throw NegotiationError.invalidMessage
        }
        return (string, consumed)
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
}
