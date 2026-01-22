/// AutoNATProtobuf - Wire format encoding/decoding for AutoNAT v1
///
/// Implements protobuf encoding/decoding for AutoNAT messages.
///
/// See: https://github.com/libp2p/specs/blob/master/autonat/README.md

import Foundation
import P2PCore

/// Protobuf encoding/decoding for AutoNAT messages.
enum AutoNATProtobuf {

    // MARK: - Wire Type Constants

    private static let wireTypeVarint: UInt64 = 0
    private static let wireTypeLengthDelimited: UInt64 = 2

    // MARK: - Message Field Tags

    /// Message field tags (field number << 3 | wire type)
    private enum MessageTag {
        static let type: UInt8 = 0x08        // field 1, varint
        static let dial: UInt8 = 0x12        // field 2, length-delimited
        static let dialResponse: UInt8 = 0x1A // field 3, length-delimited
    }

    // MARK: - Dial Field Tags

    /// Dial message field tags
    private enum DialTag {
        static let peer: UInt8 = 0x0A        // field 1, length-delimited
    }

    // MARK: - PeerInfo Field Tags

    /// PeerInfo message field tags
    private enum PeerInfoTag {
        static let id: UInt8 = 0x0A          // field 1, length-delimited
        static let addrs: UInt8 = 0x12       // field 2, length-delimited (repeated)
    }

    // MARK: - DialResponse Field Tags

    /// DialResponse message field tags
    private enum DialResponseTag {
        static let status: UInt8 = 0x08      // field 1, varint
        static let statusText: UInt8 = 0x12  // field 2, length-delimited
        static let addr: UInt8 = 0x1A        // field 3, length-delimited
    }

    // MARK: - Message Encoding

    /// Encodes an AutoNATMessage to protobuf wire format.
    static func encode(_ message: AutoNATMessage) -> Data {
        var result = Data()

        // Field 1: type (varint)
        result.append(MessageTag.type)
        result.append(contentsOf: Varint.encode(UInt64(message.type.rawValue)))

        // Field 2: dial (optional, embedded message)
        if let dial = message.dial {
            let dialData = encodeDial(dial)
            result.append(MessageTag.dial)
            result.append(contentsOf: Varint.encode(UInt64(dialData.count)))
            result.append(dialData)
        }

        // Field 3: dialResponse (optional, embedded message)
        if let dialResponse = message.dialResponse {
            let responseData = encodeDialResponse(dialResponse)
            result.append(MessageTag.dialResponse)
            result.append(contentsOf: Varint.encode(UInt64(responseData.count)))
            result.append(responseData)
        }

        return result
    }

    /// Decodes an AutoNATMessage from protobuf wire format.
    static func decode(_ data: Data) throws -> AutoNATMessage {
        var type: AutoNATMessageType = .dial
        var dial: AutoNATDial?
        var dialResponse: AutoNATDialResponse?

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
                type = AutoNATMessageType(rawValue: UInt32(value)) ?? .dial

            case (2, wireTypeLengthDelimited): // dial
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATError.protocolViolation("Dial field truncated")
                }
                dial = try decodeDial(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (3, wireTypeLengthDelimited): // dialResponse
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATError.protocolViolation("DialResponse field truncated")
                }
                dialResponse = try decodeDialResponse(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            default:
                // Skip unknown fields
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        // Construct the message based on type
        switch type {
        case .dial:
            guard let dial = dial else {
                throw AutoNATError.protocolViolation("Missing dial in DIAL message")
            }
            return .dial(peer: dial.peer)

        case .dialResponse:
            guard let response = dialResponse else {
                throw AutoNATError.protocolViolation("Missing dialResponse in DIAL_RESPONSE message")
            }
            return .dialResponse(response)
        }
    }

    // MARK: - Dial Encoding

    private static func encodeDial(_ dial: AutoNATDial) -> Data {
        var result = Data()

        // Field 1: peer (embedded message)
        let peerData = encodePeerInfo(dial.peer)
        result.append(DialTag.peer)
        result.append(contentsOf: Varint.encode(UInt64(peerData.count)))
        result.append(peerData)

        return result
    }

    private static func decodeDial(_ data: Data) throws -> AutoNATDial {
        var peer: AutoNATPeerInfo?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeLengthDelimited): // peer
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATError.protocolViolation("PeerInfo field truncated")
                }
                peer = try decodePeerInfo(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            default:
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        guard let peerInfo = peer else {
            throw AutoNATError.protocolViolation("Missing peer in Dial")
        }

        return AutoNATDial(peer: peerInfo)
    }

    // MARK: - PeerInfo Encoding

    private static func encodePeerInfo(_ peer: AutoNATPeerInfo) -> Data {
        var result = Data()

        // Field 1: id (optional bytes)
        if let id = peer.id {
            let idBytes = id.bytes
            result.append(PeerInfoTag.id)
            result.append(contentsOf: Varint.encode(UInt64(idBytes.count)))
            result.append(idBytes)
        }

        // Field 2: addrs (repeated bytes)
        for addr in peer.addresses {
            let addrBytes = addr.bytes
            result.append(PeerInfoTag.addrs)
            result.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
            result.append(addrBytes)
        }

        return result
    }

    private static func decodePeerInfo(_ data: Data) throws -> AutoNATPeerInfo {
        var id: PeerID?
        var addresses: [Multiaddr] = []

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(wireType: wireType, data: data, offset: offset)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            guard fieldEnd <= data.endIndex else {
                throw AutoNATError.protocolViolation("Field truncated")
            }

            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1: // id
                id = try PeerID(bytes: fieldData)
            case 2: // addrs
                let addr = try Multiaddr(bytes: fieldData)
                addresses.append(addr)
            default:
                break
            }
        }

        return AutoNATPeerInfo(id: id, addresses: addresses)
    }

    // MARK: - DialResponse Encoding

    private static func encodeDialResponse(_ response: AutoNATDialResponse) -> Data {
        var result = Data()

        // Field 1: status (varint)
        result.append(DialResponseTag.status)
        result.append(contentsOf: Varint.encode(UInt64(response.status.rawValue)))

        // Field 2: statusText (optional string)
        if let statusText = response.statusText {
            let textData = Data(statusText.utf8)
            result.append(DialResponseTag.statusText)
            result.append(contentsOf: Varint.encode(UInt64(textData.count)))
            result.append(textData)
        }

        // Field 3: addr (optional bytes)
        if let addr = response.address {
            let addrBytes = addr.bytes
            result.append(DialResponseTag.addr)
            result.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
            result.append(addrBytes)
        }

        return result
    }

    private static func decodeDialResponse(_ data: Data) throws -> AutoNATDialResponse {
        var status: AutoNATResponseStatus = .ok
        var statusText: String?
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
                status = AutoNATResponseStatus(rawValue: UInt32(value))

            case (2, wireTypeLengthDelimited): // statusText
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATError.protocolViolation("StatusText field truncated")
                }
                statusText = String(data: Data(data[offset..<fieldEnd]), encoding: .utf8)
                offset = fieldEnd

            case (3, wireTypeLengthDelimited): // addr
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw AutoNATError.protocolViolation("Addr field truncated")
                }
                address = try Multiaddr(bytes: Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            default:
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        return AutoNATDialResponse(status: status, statusText: statusText, address: address)
    }

    // MARK: - Helpers

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
            throw AutoNATError.protocolViolation("Unknown wire type \(wireType)")
        }

        guard newOffset <= data.endIndex else {
            throw AutoNATError.protocolViolation("Field extends beyond data")
        }

        return newOffset
    }
}
