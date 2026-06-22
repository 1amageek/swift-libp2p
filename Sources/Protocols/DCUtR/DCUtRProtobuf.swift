/// DCUtRProtobuf - Wire format encoding/decoding for DCUtR protocol.
///
/// See: https://github.com/libp2p/specs/blob/master/relay/DCUtR.md

import Foundation
import NIOCore
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

    static func encode(_ message: DCUtRMessage, into buffer: inout ByteBuffer) {
        buffer.writeBytes(encode(message))
    }

    // MARK: - Decoding

    /// Maximum number of observed addresses accepted per message (DoS bound).
    static let maxObservedAddresses = 64

    /// Decodes a DCUtRMessage from protobuf wire format.
    static func decode(_ data: Data) throws -> DCUtRMessage {
        // Rebase to a zero-based buffer so slicing on a non-zero-based slice is safe.
        let data = data.startIndex == 0 ? data : Data(data)

        var typeValue: UInt64?
        var addresses: [Multiaddr] = []

        var offset = 0

        while offset < data.count {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeVarint): // type
                let (value, valueBytes) = try Varint.decode(from: data, at: offset)
                offset += valueBytes
                typeValue = value

            case (2, wireTypeLengthDelimited): // ObsAddrs
                let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let length = try Varint.toInt(lengthValue)
                let fieldEnd = offset + length
                guard fieldEnd <= data.count else {
                    throw DCUtRError.encodingError("Address field truncated")
                }

                // Bound the number of addresses to prevent decode amplification.
                guard addresses.count < maxObservedAddresses else {
                    throw DCUtRError.encodingError(
                        "Too many observed addresses (max \(maxObservedAddresses))"
                    )
                }

                // Surface invalid multiaddrs rather than silently dropping them:
                // a malformed address indicates a malformed/hostile message.
                let addrData = data[offset ..< fieldEnd]
                do {
                    let addr = try Multiaddr(bytes: Data(addrData))
                    addresses.append(addr)
                } catch {
                    throw DCUtRError.invalidAddress("Invalid observed multiaddr: \(error)")
                }

                offset = fieldEnd

            default:
                // Skip unknown fields
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        // The type field is required and must be a known value. Defaulting an
        // unknown/absent type silently would let a peer steer protocol behavior.
        guard let typeValue else {
            throw DCUtRError.protocolViolation("HolePunch message missing type field")
        }
        guard let type = DCUtRMessageType(rawValue: typeValue) else {
            throw DCUtRError.unknownMessageType(typeValue)
        }

        return DCUtRMessage(type: type, observedAddresses: addresses)
    }

    static func decode(_ buffer: ByteBuffer) throws -> DCUtRMessage {
        try decode(Data(buffer: buffer))
    }

    // MARK: - Helpers

    private static func skipField(wireType: UInt64, data: Data, offset: Int) throws -> Int {
        var newOffset = offset

        switch wireType {
        case 0: // Varint
            let (_, varBytes) = try Varint.decode(from: data, at: newOffset)
            newOffset += varBytes
        case 1: // 64-bit
            newOffset += 8
        case 2: // Length-delimited
            let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: newOffset)
            newOffset += lengthBytes
            let length = try Varint.toInt(lengthValue)
            // Validate the declared length fits before advancing past it.
            guard length <= data.count - newOffset else {
                throw DCUtRError.encodingError("Field extends beyond data")
            }
            newOffset += length
        case 5: // 32-bit
            newOffset += 4
        default:
            throw DCUtRError.encodingError("Unknown wire type \(wireType)")
        }

        guard newOffset <= data.count else {
            throw DCUtRError.encodingError("Field extends beyond data")
        }

        return newOffset
    }
}
