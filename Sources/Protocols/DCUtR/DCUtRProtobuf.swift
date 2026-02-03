/// DCUtRProtobuf - Wire format encoding/decoding for DCUtR protocol.
///
/// See: https://github.com/libp2p/specs/blob/master/relay/DCUtR.md

import Foundation
import P2PCore

/// Protobuf encoding/decoding for DCUtR messages.
///
/// Message format:
/// ```protobuf
/// message HolePunch {
///     Type type = 1;
///     repeated bytes ObsAddrs = 2;
/// }
///
/// enum Type {
///     CONNECT = 100;
///     SYNC = 300;
/// }
/// ```
enum DCUtRProtobuf {

    // MARK: - Wire Type Constants

    private static let wireTypeVarint: UInt64 = 0
    private static let wireTypeLengthDelimited: UInt64 = 2

    // MARK: - Field Tags

    /// Field 1: type (varint)
    private static let tagType: UInt8 = 0x08

    /// Field 2: ObsAddrs (length-delimited, repeated)
    private static let tagObsAddrs: UInt8 = 0x12

    // MARK: - Encoding

    /// Encodes a DCUtRMessage to protobuf wire format.
    static func encode(_ message: DCUtRMessage) -> Data {
        var result = Data()

        // Field 1: type (varint)
        result.append(tagType)
        result.append(contentsOf: Varint.encode(message.type.rawValue))

        // Field 2: ObsAddrs (repeated bytes)
        for addr in message.observedAddresses {
            let addrBytes = addr.bytes
            result.append(tagObsAddrs)
            result.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
            result.append(addrBytes)
        }

        return result
    }

    // MARK: - Decoding

    /// Decodes a DCUtRMessage from protobuf wire format.
    static func decode(_ data: Data) throws -> DCUtRMessage {
        var type: DCUtRMessageType = .connect
        var addresses: [Multiaddr] = []

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
                type = DCUtRMessageType(rawValue: value) ?? .connect

            case (2, wireTypeLengthDelimited): // ObsAddrs
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw DCUtRError.encodingError("Address field truncated")
                }

                // Skip invalid multiaddr instead of throwing
                do {
                    let addr = try Multiaddr(bytes: Data(data[offset..<fieldEnd]))
                    addresses.append(addr)
                } catch {
                    // Invalid multiaddr - skip and continue
                }

                offset = fieldEnd

            default:
                // Skip unknown fields
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        return DCUtRMessage(type: type, observedAddresses: addresses)
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
            throw DCUtRError.encodingError("Unknown wire type \(wireType)")
        }

        guard newOffset <= data.endIndex else {
            throw DCUtRError.encodingError("Field extends beyond data")
        }

        return newOffset
    }
}
