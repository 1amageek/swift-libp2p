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
        // Send multistream header
        try await write(encode(protocolID))

        // Read multistream header response
        var buffer = try await read()
        let (headerString, headerConsumed) = try decode(buffer)
        guard headerString == protocolID else {
            throw NegotiationError.protocolMismatch
        }
        buffer = Data(buffer.dropFirst(headerConsumed))

        // Try each protocol
        for proto in protocols {
            try await write(encode(proto))
            if buffer.isEmpty {
                buffer = try await read()
            }
            let (decoded, consumed) = try decode(buffer)
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

        // Read response — may contain header + protocol response coalesced
        var buffer = try await read()
        let (headerString, headerConsumed) = try decode(buffer)
        guard headerString == protocolID else {
            throw NegotiationError.protocolMismatch
        }
        buffer = Data(buffer.dropFirst(headerConsumed))

        // Read protocol response (may already be in buffer from coalesced read)
        if buffer.isEmpty {
            buffer = try await read()
        }
        let (decoded, consumed) = try decode(buffer)
        buffer = Data(buffer.dropFirst(consumed))

        if decoded == firstProtocol {
            // First protocol accepted - 1 RTT success!
            return NegotiationResult(protocolID: firstProtocol, remainder: buffer)
        } else if decoded == "na" {
            // First protocol rejected - fall back to remaining protocols
            for proto in protocols.dropFirst() {
                try await write(encode(proto))
                if buffer.isEmpty {
                    buffer = try await read()
                }
                let (responseDecoded, responseConsumed) = try decode(buffer)
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
        // Read and respond to multistream header
        // Buffer handles coalesced TCP reads (e.g., V1Lazy sends header + protocol in one write)
        var buffer = try await read()
        let (headerString, headerConsumed) = try decode(buffer)
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

            if buffer.isEmpty {
                buffer = try await read()
            }
            let (requested, consumed) = try decode(buffer)
            buffer = Data(buffer.dropFirst(consumed))

            if supported.contains(requested) {
                try await write(encode(requested))
                return NegotiationResult(protocolID: requested, remainder: buffer)
            } else if requested == "ls" {
                // List supported protocols per multistream-select spec:
                // Format: <outer-length> <proto1-len>/proto1\n <proto2-len>/proto2\n ... \n
                // Each protocol is an embedded multistream message with its own varint length
                // Estimate: each proto ~40 bytes + varint overhead
                var inner = Data(capacity: supported.count * 48 + 1)
                for proto in supported {
                    let protoMessage = Data((proto + "\n").utf8)
                    inner.append(contentsOf: Varint.encode(UInt64(protoMessage.count)))
                    inner.append(protoMessage)
                }
                // Final terminating newline
                inner.append(UInt8(ascii: "\n"))

                var outer = Varint.encode(UInt64(inner.count))
                outer.append(inner)
                try await write(outer)
            } else {
                try await write(encode("na"))
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
        let (length, lengthBytes) = try Varint.decode(data)

        // Validate message size to prevent memory exhaustion attacks
        // Check against Int.max first to prevent crash, then check maxMessageSize
        guard length <= UInt64(Int.max) else {
            throw NegotiationError.messageTooLarge(size: Int.max, max: maxMessageSize)
        }
        let messageLength = Int(length)
        if messageLength > maxMessageSize {
            throw NegotiationError.messageTooLarge(size: messageLength, max: maxMessageSize)
        }

        let totalConsumed = lengthBytes + messageLength
        guard data.count >= totalConsumed else {
            throw NegotiationError.invalidMessage
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

        return (string, totalConsumed)
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
