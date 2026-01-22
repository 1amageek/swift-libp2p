/// CircuitRelayProtobuf - Wire format encoding/decoding for Circuit Relay v2
///
/// Implements protobuf encoding/decoding for HopMessage and StopMessage.
///
/// See: https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md

import Foundation
import P2PCore

/// Protobuf encoding/decoding for Circuit Relay v2 messages.
enum CircuitRelayProtobuf {

    // MARK: - Wire Type Constants

    private static let wireTypeVarint: UInt64 = 0
    private static let wireTypeLengthDelimited: UInt64 = 2

    // MARK: - HopMessage Field Tags

    /// HopMessage field tags (field number << 3 | wire type)
    private enum HopTag {
        static let type: UInt8 = 0x08        // field 1, varint
        static let peer: UInt8 = 0x12        // field 2, length-delimited
        static let reservation: UInt8 = 0x1A // field 3, length-delimited
        static let limit: UInt8 = 0x22       // field 4, length-delimited
        static let status: UInt8 = 0x28      // field 5, varint
    }

    // MARK: - StopMessage Field Tags

    /// StopMessage field tags
    private enum StopTag {
        static let type: UInt8 = 0x08    // field 1, varint
        static let peer: UInt8 = 0x12    // field 2, length-delimited
        static let limit: UInt8 = 0x1A   // field 3, length-delimited
        static let status: UInt8 = 0x20  // field 4, varint
    }

    // MARK: - Peer Message Field Tags

    /// Peer message field tags
    private enum PeerTag {
        static let id: UInt8 = 0x0A      // field 1, length-delimited
        static let addrs: UInt8 = 0x12   // field 2, length-delimited (repeated)
    }

    // MARK: - Reservation Message Field Tags

    /// Reservation message field tags
    private enum ReservationTag {
        static let expire: UInt8 = 0x08   // field 1, varint
        static let addrs: UInt8 = 0x12    // field 2, length-delimited (repeated)
        static let voucher: UInt8 = 0x1A  // field 3, length-delimited
    }

    // MARK: - Limit Message Field Tags

    /// Limit message field tags
    private enum LimitTag {
        static let duration: UInt8 = 0x08 // field 1, varint
        static let data: UInt8 = 0x10     // field 2, varint
    }

    // MARK: - HopMessage Encoding

    /// Encodes a HopMessage to protobuf wire format.
    static func encode(_ message: HopMessage) -> Data {
        var result = Data()

        // Field 1: type (varint)
        result.append(HopTag.type)
        result.append(contentsOf: Varint.encode(UInt64(message.type.rawValue)))

        // Field 2: peer (optional, embedded message)
        if let peer = message.peer {
            let peerData = encodePeer(peer)
            result.append(HopTag.peer)
            result.append(contentsOf: Varint.encode(UInt64(peerData.count)))
            result.append(peerData)
        }

        // Field 3: reservation (optional, embedded message)
        if let reservation = message.reservation {
            let resData = encodeReservation(reservation)
            result.append(HopTag.reservation)
            result.append(contentsOf: Varint.encode(UInt64(resData.count)))
            result.append(resData)
        }

        // Field 4: limit (optional, embedded message)
        if let limit = message.limit {
            let limitData = encodeLimit(limit)
            if !limitData.isEmpty {
                result.append(HopTag.limit)
                result.append(contentsOf: Varint.encode(UInt64(limitData.count)))
                result.append(limitData)
            }
        }

        // Field 5: status (optional, varint)
        if let status = message.status {
            result.append(HopTag.status)
            result.append(contentsOf: Varint.encode(UInt64(status.rawValue)))
        }

        return result
    }

    /// Decodes a HopMessage from protobuf wire format.
    static func decodeHop(_ data: Data) throws -> HopMessage {
        var type: HopMessageType = .reserve
        var peer: PeerInfo?
        var reservation: ReservationInfo?
        var limit: CircuitLimit?
        var status: HopStatus?

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
                type = HopMessageType(rawValue: UInt8(value)) ?? .reserve

            case (2, wireTypeLengthDelimited): // peer
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CircuitRelayError.encodingError("Peer field truncated")
                }
                peer = try decodePeer(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (3, wireTypeLengthDelimited): // reservation
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CircuitRelayError.encodingError("Reservation field truncated")
                }
                reservation = try decodeReservation(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (4, wireTypeLengthDelimited): // limit
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CircuitRelayError.encodingError("Limit field truncated")
                }
                limit = try decodeLimit(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (5, wireTypeVarint): // status
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                status = HopStatus(rawValue: UInt32(value)) ?? .unknown

            default:
                // Skip unknown fields
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        return HopMessage(type: type, peer: peer, reservation: reservation, limit: limit, status: status)
    }

    // MARK: - StopMessage Encoding

    /// Encodes a StopMessage to protobuf wire format.
    static func encode(_ message: StopMessage) -> Data {
        var result = Data()

        // Field 1: type (varint)
        result.append(StopTag.type)
        result.append(contentsOf: Varint.encode(UInt64(message.type.rawValue)))

        // Field 2: peer (optional, embedded message)
        if let peer = message.peer {
            let peerData = encodePeer(peer)
            result.append(StopTag.peer)
            result.append(contentsOf: Varint.encode(UInt64(peerData.count)))
            result.append(peerData)
        }

        // Field 3: limit (optional, embedded message)
        if let limit = message.limit {
            let limitData = encodeLimit(limit)
            if !limitData.isEmpty {
                result.append(StopTag.limit)
                result.append(contentsOf: Varint.encode(UInt64(limitData.count)))
                result.append(limitData)
            }
        }

        // Field 4: status (optional, varint)
        if let status = message.status {
            result.append(StopTag.status)
            result.append(contentsOf: Varint.encode(UInt64(status.rawValue)))
        }

        return result
    }

    /// Decodes a StopMessage from protobuf wire format.
    static func decodeStop(_ data: Data) throws -> StopMessage {
        var type: StopMessageType = .connect
        var peer: PeerInfo?
        var limit: CircuitLimit?
        var status: StopStatus?

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
                type = StopMessageType(rawValue: UInt8(value)) ?? .connect

            case (2, wireTypeLengthDelimited): // peer
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CircuitRelayError.encodingError("Peer field truncated")
                }
                peer = try decodePeer(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (3, wireTypeLengthDelimited): // limit
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CircuitRelayError.encodingError("Limit field truncated")
                }
                limit = try decodeLimit(Data(data[offset..<fieldEnd]))
                offset = fieldEnd

            case (4, wireTypeVarint): // status
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                status = StopStatus(rawValue: UInt32(value)) ?? .unknown

            default:
                // Skip unknown fields
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        return StopMessage(type: type, peer: peer, limit: limit, status: status)
    }

    // MARK: - Peer Encoding

    private static func encodePeer(_ peer: PeerInfo) -> Data {
        var result = Data()

        // Field 1: id (bytes)
        let idBytes = peer.id.bytes
        result.append(PeerTag.id)
        result.append(contentsOf: Varint.encode(UInt64(idBytes.count)))
        result.append(idBytes)

        // Field 2: addrs (repeated bytes)
        for addr in peer.addresses {
            let addrBytes = addr.bytes
            result.append(PeerTag.addrs)
            result.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
            result.append(addrBytes)
        }

        return result
    }

    private static func decodePeer(_ data: Data) throws -> PeerInfo {
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
                throw CircuitRelayError.encodingError("Field truncated")
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

        guard let peerId = id else {
            throw CircuitRelayError.encodingError("Missing peer ID")
        }

        return PeerInfo(id: peerId, addresses: addresses)
    }

    // MARK: - Reservation Encoding

    private static func encodeReservation(_ reservation: ReservationInfo) -> Data {
        var result = Data()

        // Field 1: expire (uint64)
        result.append(ReservationTag.expire)
        result.append(contentsOf: Varint.encode(reservation.expiration))

        // Field 2: addrs (repeated bytes)
        for addr in reservation.addresses {
            let addrBytes = addr.bytes
            result.append(ReservationTag.addrs)
            result.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
            result.append(addrBytes)
        }

        // Field 3: voucher (optional bytes)
        if let voucher = reservation.voucher {
            result.append(ReservationTag.voucher)
            result.append(contentsOf: Varint.encode(UInt64(voucher.count)))
            result.append(voucher)
        }

        return result
    }

    private static func decodeReservation(_ data: Data) throws -> ReservationInfo {
        var expiration: UInt64 = 0
        var addresses: [Multiaddr] = []
        var voucher: Data?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeVarint): // expire
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                expiration = value

            case (2, wireTypeLengthDelimited): // addrs
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CircuitRelayError.encodingError("Address field truncated")
                }
                let addr = try Multiaddr(bytes: Data(data[offset..<fieldEnd]))
                addresses.append(addr)
                offset = fieldEnd

            case (3, wireTypeLengthDelimited): // voucher
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw CircuitRelayError.encodingError("Voucher field truncated")
                }
                voucher = Data(data[offset..<fieldEnd])
                offset = fieldEnd

            default:
                offset = try skipField(wireType: wireType, data: data, offset: offset)
            }
        }

        return ReservationInfo(expiration: expiration, addresses: addresses, voucher: voucher)
    }

    // MARK: - Limit Encoding

    private static func encodeLimit(_ limit: CircuitLimit) -> Data {
        var result = Data()

        // Field 1: duration (optional uint32, in seconds)
        if let duration = limit.duration {
            let seconds = UInt32(duration.components.seconds)
            result.append(LimitTag.duration)
            result.append(contentsOf: Varint.encode(UInt64(seconds)))
        }

        // Field 2: data (optional uint64)
        if let data = limit.data {
            result.append(LimitTag.data)
            result.append(contentsOf: Varint.encode(data))
        }

        return result
    }

    private static func decodeLimit(_ data: Data) throws -> CircuitLimit {
        var duration: Duration?
        var dataLimit: UInt64?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeVarint else {
                offset = try skipField(wireType: wireType, data: data, offset: offset)
                continue
            }

            let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
            offset += valueBytes

            switch fieldNumber {
            case 1: // duration
                duration = .seconds(Int64(value))
            case 2: // data
                dataLimit = value
            default:
                break
            }
        }

        return CircuitLimit(duration: duration, data: dataLimit)
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
            throw CircuitRelayError.encodingError("Unknown wire type \(wireType)")
        }

        guard newOffset <= data.endIndex else {
            throw CircuitRelayError.encodingError("Field extends beyond data")
        }

        return newOffset
    }
}
