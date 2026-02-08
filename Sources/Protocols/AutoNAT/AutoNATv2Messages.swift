/// AutoNATv2Messages - Message types for AutoNAT v2 protocol.
///
/// AutoNAT v2 uses nonce-based verification to prove reachability.
/// The client sends a DialRequest with an address and nonce, and the server
/// dials back to that address and sends the nonce to prove it connected.

import Foundation
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
/// Uses a simple tag-length-value format compatible with protobuf wire format.
public enum AutoNATv2Codec {

    // MARK: - Message Type Tags

    /// Message type identifier (varint).
    private enum MessageType: UInt64 {
        case dialRequest = 0
        case dialResponse = 1
        case dialBack = 2
    }

    // MARK: - Wire Type Constants

    private static let wireTypeVarint: UInt64 = 0
    private static let wireTypeFixed64: UInt64 = 1
    private static let wireTypeLengthDelimited: UInt64 = 2

    // MARK: - Field Tags

    /// Top-level message field tags.
    private enum TopTag {
        static let type: UInt8 = 0x08           // field 1, varint
        static let dialRequest: UInt8 = 0x12    // field 2, length-delimited
        static let dialResponse: UInt8 = 0x1A   // field 3, length-delimited
        static let dialBack: UInt8 = 0x22       // field 4, length-delimited
    }

    /// DialRequest field tags.
    private enum DialRequestTag {
        static let address: UInt8 = 0x0A   // field 1, length-delimited
        static let nonce: UInt8 = 0x11     // field 2, fixed64
    }

    /// DialResponse field tags.
    private enum DialResponseTag {
        static let status: UInt8 = 0x08    // field 1, varint
        static let address: UInt8 = 0x12   // field 2, length-delimited
    }

    /// DialBack field tags.
    private enum DialBackTag {
        static let nonce: UInt8 = 0x09     // field 1, fixed64
    }

    // MARK: - Encoding

    /// Encodes a message to wire format.
    public static func encode(_ message: AutoNATv2Message) -> Data {
        var result = Data()

        switch message {
        case .dialRequest(let req):
            // type = 0
            result.append(TopTag.type)
            result.append(contentsOf: Varint.encode(MessageType.dialRequest.rawValue))

            // dialRequest field
            let reqData = encodeDialRequest(req)
            result.append(TopTag.dialRequest)
            result.append(contentsOf: Varint.encode(UInt64(reqData.count)))
            result.append(reqData)

        case .dialResponse(let resp):
            // type = 1
            result.append(TopTag.type)
            result.append(contentsOf: Varint.encode(MessageType.dialResponse.rawValue))

            // dialResponse field
            let respData = encodeDialResponse(resp)
            result.append(TopTag.dialResponse)
            result.append(contentsOf: Varint.encode(UInt64(respData.count)))
            result.append(respData)

        case .dialBack(let back):
            // type = 2
            result.append(TopTag.type)
            result.append(contentsOf: Varint.encode(MessageType.dialBack.rawValue))

            // dialBack field
            let backData = encodeDialBack(back)
            result.append(TopTag.dialBack)
            result.append(contentsOf: Varint.encode(UInt64(backData.count)))
            result.append(backData)
        }

        return result
    }

    private static func encodeDialRequest(_ req: AutoNATv2Message.DialRequest) -> Data {
        var result = Data()

        // Field 1: address (length-delimited bytes)
        let addrBytes = req.address.bytes
        result.append(DialRequestTag.address)
        result.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
        result.append(addrBytes)

        // Field 2: nonce (fixed64 - 8 bytes little-endian)
        result.append(DialRequestTag.nonce)
        result.append(contentsOf: encodeFixed64(req.nonce))

        return result
    }

    private static func encodeDialResponse(_ resp: AutoNATv2Message.DialResponse) -> Data {
        var result = Data()

        // Field 1: status (varint)
        result.append(DialResponseTag.status)
        result.append(contentsOf: Varint.encode(UInt64(resp.status.rawValue)))

        // Field 2: address (optional, length-delimited bytes)
        if let addr = resp.address {
            let addrBytes = addr.bytes
            result.append(DialResponseTag.address)
            result.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
            result.append(addrBytes)
        }

        return result
    }

    private static func encodeDialBack(_ back: AutoNATv2Message.DialBack) -> Data {
        var result = Data()

        // Field 1: nonce (fixed64 - 8 bytes little-endian)
        result.append(DialBackTag.nonce)
        result.append(contentsOf: encodeFixed64(back.nonce))

        return result
    }

    // MARK: - Decoding

    /// Decodes a message from wire format.
    public static func decode(_ data: Data) throws -> AutoNATv2Message {
        var messageType: MessageType = .dialRequest
        var dialRequest: AutoNATv2Message.DialRequest?
        var dialResponse: AutoNATv2Message.DialResponse?
        var dialBack: AutoNATv2Message.DialBack?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeVarint): // type
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                guard let mt = MessageType(rawValue: value) else {
                    throw AutoNATv2Error.protocolViolation("Unknown message type: \(value)")
                }
                messageType = mt

            case (2, wireTypeLengthDelimited): // dialRequest
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATv2Error.protocolViolation("DialRequest field truncated")
                }
                dialRequest = try decodeDialRequest(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (3, wireTypeLengthDelimited): // dialResponse
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATv2Error.protocolViolation("DialResponse field truncated")
                }
                dialResponse = try decodeDialResponse(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (4, wireTypeLengthDelimited): // dialBack
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATv2Error.protocolViolation("DialBack field truncated")
                }
                dialBack = try decodeDialBack(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            default:
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        switch messageType {
        case .dialRequest:
            guard let req = dialRequest else {
                throw AutoNATv2Error.protocolViolation("Missing dialRequest in DIAL_REQUEST message")
            }
            return .dialRequest(req)

        case .dialResponse:
            guard let resp = dialResponse else {
                throw AutoNATv2Error.protocolViolation("Missing dialResponse in DIAL_RESPONSE message")
            }
            return .dialResponse(resp)

        case .dialBack:
            guard let back = dialBack else {
                throw AutoNATv2Error.protocolViolation("Missing dialBack in DIAL_BACK message")
            }
            return .dialBack(back)
        }
    }

    // MARK: - Sub-message Decoding

    private static func decodeDialRequest(_ data: Data) throws -> AutoNATv2Message.DialRequest {
        var address: Multiaddr?
        var nonce: UInt64 = 0

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeLengthDelimited): // address
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATv2Error.protocolViolation("Address field truncated")
                }
                address = try Multiaddr(bytes: Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (2, wireTypeFixed64): // nonce (fixed64)
                guard offset + 8 <= data.endIndex else {
                    throw AutoNATv2Error.protocolViolation("Nonce field truncated in DialRequest")
                }
                nonce = decodeFixed64(Data(data[offset..<(offset + 8)]))
                offset += 8

            default:
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        guard let addr = address else {
            throw AutoNATv2Error.protocolViolation("Missing address in DialRequest")
        }

        return AutoNATv2Message.DialRequest(address: addr, nonce: nonce)
    }

    private static func decodeDialResponse(_ data: Data) throws -> AutoNATv2Message.DialResponse {
        var status: AutoNATv2Message.DialStatus = .ok
        var address: Multiaddr?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeVarint): // status
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                status = AutoNATv2Message.DialStatus(rawValue: UInt32(value))

            case (2, wireTypeLengthDelimited): // address
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATv2Error.protocolViolation("Address field truncated in DialResponse")
                }
                address = try Multiaddr(bytes: Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            default:
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        return AutoNATv2Message.DialResponse(status: status, address: address)
    }

    private static func decodeDialBack(_ data: Data) throws -> AutoNATv2Message.DialBack {
        var nonce: UInt64 = 0

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeFixed64): // nonce (fixed64)
                guard offset + 8 <= data.endIndex else {
                    throw AutoNATv2Error.protocolViolation("Nonce field truncated in DialBack")
                }
                nonce = decodeFixed64(Data(data[offset..<(offset + 8)]))
                offset += 8

            default:
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        return AutoNATv2Message.DialBack(nonce: nonce)
    }

    // MARK: - Helpers

    /// Encodes a UInt64 as 8 bytes in little-endian order (protobuf fixed64).
    private static func encodeFixed64(_ value: UInt64) -> [UInt8] {
        var le = value.littleEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }

    /// Decodes a UInt64 from 8 bytes in little-endian order (protobuf fixed64).
    private static func decodeFixed64(_ data: Data) -> UInt64 {
        var value: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest)
        }
        return UInt64(littleEndian: value)
    }

    private static func skipField(wireType: UInt64, data: Data, offset: Int) throws -> Int {
        var newOffset = offset

        switch wireType {
        case 0: // Varint
            let (_, varBytes) = try Varint.decode(Data(data[newOffset...]))
            newOffset += varBytes
        case 1: // 64-bit
            newOffset += 8
        case 2: // Length-delimited
            let (length, lengthBytes) = try Varint.decode(Data(data[newOffset...]))
            newOffset += lengthBytes + Int(length)
        case 5: // 32-bit
            newOffset += 4
        default:
            throw AutoNATv2Error.protocolViolation("Unknown wire type \(wireType)")
        }

        guard newOffset <= data.endIndex else {
            throw AutoNATv2Error.protocolViolation("Field extends beyond data")
        }

        return newOffset
    }
}
