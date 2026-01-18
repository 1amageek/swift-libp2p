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
        let response = try await read()
        guard try decode(response) == protocolID else {
            throw NegotiationError.protocolMismatch
        }

        // Try each protocol
        for proto in protocols {
            try await write(encode(proto))
            let protoResponse = try await read()
            let decoded = try decode(protoResponse)

            if decoded == proto {
                return NegotiationResult(protocolID: proto)
            } else if decoded == "na" {
                continue
            } else {
                throw NegotiationError.unexpectedResponse(decoded)
            }
        }

        throw NegotiationError.noAgreement
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
        let header = try await read()
        guard try decode(header) == protocolID else {
            throw NegotiationError.protocolMismatch
        }
        try await write(encode(protocolID))

        // Handle protocol requests until agreement or connection close
        // Timeouts are handled at the transport level per libp2p spec
        while true {
            let request = try await read()
            let requested = try decode(request)

            if supported.contains(requested) {
                try await write(encode(requested))
                return NegotiationResult(protocolID: requested)
            } else if requested == "ls" {
                // List supported protocols
                // Format: <outer-length><proto1>\n<proto2>\n...
                // Note: No individual length prefix per protocol, just newline-separated
                // This matches go-libp2p and rust-libp2p implementations
                var inner = Data()
                for proto in supported {
                    inner.append(Data((proto + "\n").utf8))
                }
                let outer = Varint.encode(UInt64(inner.count)) + inner
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
    /// - Returns: The decoded protocol string
    /// - Throws: `NegotiationError` or `VarintError` if decoding fails
    public static func decode(_ data: Data) throws -> String {
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

        guard data.count >= lengthBytes + messageLength else {
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

        return string
    }
}

public enum NegotiationError: Error, Equatable {
    case protocolMismatch
    case noAgreement
    case unexpectedResponse(String)
    case timeout
    case invalidMessage
    case invalidUtf8
    case messageTooLarge(size: Int, max: Int)
}
