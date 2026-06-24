/// AutoNATv2Messages - Message types for AutoNAT v2 protocol.
///
/// AutoNAT v2 uses nonce-based verification to prove reachability.
/// The client sends a DialRequest with an address and nonce, and the server
/// dials back to that address and sends the nonce to prove it connected.

import Foundation
import NIOCore
import P2PCore

// MARK: - Message Types

/// Messages for the AutoNAT v2 protocol.
public enum AutoNATv2Message: Sendable, Equatable {

    /// Client -> Server: "Please check if this address is reachable"
    case dialRequest(DialRequest)

    /// Server -> Client (via original stream): Response indicating dial-back result
    case dialResponse(DialResponse)

    /// Server -> Client (via dial-back connection): Nonce verification
    case dialBack(DialBack)

    /// A dial request from the client to the server.
    public struct DialRequest: Sendable, Equatable {
        /// The address to check reachability for.
        public let address: Multiaddr

        /// A random nonce for verification.
        public let nonce: UInt64

        /// Creates a dial request.
        public init(address: Multiaddr, nonce: UInt64) {
            self.address = address
            self.nonce = nonce
        }
    }

    /// A dial response from the server.
    public struct DialResponse: Sendable, Equatable {
        /// The status of the dial attempt.
        public let status: DialStatus

        /// The address that was checked (echoed back).
        public let address: Multiaddr?

        /// Creates a dial response.
        public init(status: DialStatus, address: Multiaddr? = nil) {
            self.status = status
            self.address = address
        }
    }

    /// A dial-back message sent via the dial-back connection.
    public struct DialBack: Sendable, Equatable {
        /// The nonce from the original request.
        public let nonce: UInt64

        /// Creates a dial-back message.
        public init(nonce: UInt64) {
            self.nonce = nonce
        }
    }

    /// Status codes for dial responses.
    public enum DialStatus: UInt32, Sendable, Equatable {
        /// Dial succeeded and nonce was verified.
        case ok = 0

        /// Dial-back failed (could not connect to address).
        case dialError = 100

        /// Dial-back connection was established but nonce exchange failed.
        case dialBackError = 101

        /// Bad request from client.
        case badRequest = 200

        /// Internal server error.
        case internalError = 300

        /// Creates a status from a raw value, defaulting to internalError for unknown values.
        public init(rawValue: UInt32) {
            switch rawValue {
            case 0: self = .ok
            case 100: self = .dialError
            case 101: self = .dialBackError
            case 200: self = .badRequest
            case 300: self = .internalError
            default: self = .internalError
            }
        }
    }
}

// MARK: - Encoding

/// Wire format encoding/decoding for AutoNAT v2 messages.
///
/// The wire framing lives in the Embedded-clean ``AutoNATv2Fields`` codec
/// (`LibP2PCore`); this adapter bridges the domain `Multiaddr` values to/from the
/// codec's raw `[UInt8]` fields, restores the historical `Data`/`ByteBuffer`
/// API, and resolves the typed `AutoNATv2Message` enum.
public enum AutoNATv2Codec {

    // MARK: - Encoding

    /// Encodes a message to wire format.
    public static func encode(_ message: AutoNATv2Message) -> Data {
        Data(buildFields(message).encode())
    }

    public static func encode(_ message: AutoNATv2Message, into buffer: inout ByteBuffer) {
        buffer.writeBytes(buildFields(message).encode())
    }

    private static func buildFields(_ message: AutoNATv2Message) -> AutoNATv2Fields {
        switch message {
        case .dialRequest(let req):
            return AutoNATv2Fields(
                kind: .dialRequest,
                dialRequest: AutoNATv2DialRequestFields(address: [UInt8](req.address.bytes), nonce: req.nonce)
            )
        case .dialResponse(let resp):
            return AutoNATv2Fields(
                kind: .dialResponse,
                dialResponse: AutoNATv2DialResponseFields(
                    statusRawValue: resp.status.rawValue,
                    address: resp.address.map { [UInt8]($0.bytes) }
                )
            )
        case .dialBack(let back):
            return AutoNATv2Fields(
                kind: .dialBack,
                dialBack: AutoNATv2DialBackFields(nonce: back.nonce)
            )
        }
    }

    // MARK: - Decoding

    /// Decodes a message from wire format.
    public static func decode(_ data: Data) throws -> AutoNATv2Message {
        let fields: AutoNATv2Fields
        do {
            fields = try AutoNATv2Fields.decode(from: [UInt8](data))
        } catch {
            try rethrow(error)
        }

        switch fields.kind {
        case .dialRequest:
            guard let req = fields.dialRequest else {
                throw AutoNATv2Error.protocolViolation("Missing dialRequest in DIAL_REQUEST message")
            }
            return .dialRequest(AutoNATv2Message.DialRequest(
                address: try Multiaddr(bytes: Data(req.address)),
                nonce: req.nonce
            ))

        case .dialResponse:
            guard let resp = fields.dialResponse else {
                throw AutoNATv2Error.protocolViolation("Missing dialResponse in DIAL_RESPONSE message")
            }
            return .dialResponse(AutoNATv2Message.DialResponse(
                status: AutoNATv2Message.DialStatus(rawValue: resp.statusRawValue),
                address: try resp.address.map { try Multiaddr(bytes: Data($0)) }
            ))

        case .dialBack:
            guard let back = fields.dialBack else {
                throw AutoNATv2Error.protocolViolation("Missing dialBack in DIAL_BACK message")
            }
            return .dialBack(AutoNATv2Message.DialBack(nonce: back.nonce))
        }
    }

    public static func decode(_ buffer: ByteBuffer) throws -> AutoNATv2Message {
        try decode(Data(buffer: buffer))
    }

    /// Maps the cored codec's typed error to the adapter's error contract.
    private static func rethrow(_ error: AutoNATv2CodecError) throws -> Never {
        switch error {
        case .truncated:
            throw AutoNATv2Error.protocolViolation("Field truncated")
        case .unknownWireType(let wireType):
            throw AutoNATv2Error.protocolViolation("Unknown wire type \(wireType)")
        case .unknownMessageType(let value):
            throw AutoNATv2Error.protocolViolation("Unknown message type: \(value)")
        case .missingAddress:
            throw AutoNATv2Error.protocolViolation("Missing address in DialRequest")
        }
    }
}
