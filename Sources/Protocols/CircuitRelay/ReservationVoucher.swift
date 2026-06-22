/// ReservationVoucher - Signed proof that a relay granted a reservation.
///
/// A reservation voucher is a `SignedRecord` issued by the relay and sealed in
/// an `Envelope` signed with the relay's key. It binds:
/// - the relay's PeerID,
/// - the reserving peer's PeerID,
/// - the reservation expiration time.
///
/// Clients verify the voucher (signature + relay/peer binding) before trusting a
/// reservation, preventing a malicious intermediary from forging reservations on
/// behalf of a relay.

import Foundation
import NIOCore
import P2PCore

/// A reservation voucher record.
public struct ReservationVoucher: SignedRecord, Sendable, Equatable {
    /// Domain separation string for reservation vouchers.
    public static let domain = "libp2p-relay-rsvp"

    /// The multicodec for reservation vouchers (0x0302).
    public static let codec = Data([0x03, 0x02])

    /// The relay that issued (and signed) this voucher.
    public let relay: PeerID

    /// The peer that holds the reservation.
    public let peer: PeerID

    /// The reservation expiration as a UNIX timestamp (seconds).
    public let expiration: UInt64

    /// Creates a new reservation voucher.
    public init(relay: PeerID, peer: PeerID, expiration: UInt64) {
        self.relay = relay
        self.peer = peer
        self.expiration = expiration
    }

    // MARK: - Wire Format

    private static let wireTypeVarint: UInt64 = 0
    private static let wireTypeLengthDelimited: UInt64 = 2
    private static let tagRelay: UInt8 = 0x0A      // field 1, length-delimited
    private static let tagPeer: UInt8 = 0x12       // field 2, length-delimited
    private static let tagExpiration: UInt8 = 0x18 // field 3, varint

    /// Maximum allowed length for individual length-delimited fields (DoS bound).
    private static let maxFieldLength: UInt64 = 4096

    public func marshal() throws -> Data {
        let relayBytes = relay.bytes
        let peerBytes = peer.bytes

        var buffer = ByteBufferAllocator().buffer(
            capacity: 2 + relayBytes.count + peerBytes.count + 12
        )

        // Field 1: relay (bytes)
        buffer.writeInteger(Self.tagRelay)
        Varint.encode(UInt64(relayBytes.count), into: &buffer)
        buffer.writeBytes(relayBytes)

        // Field 2: peer (bytes)
        buffer.writeInteger(Self.tagPeer)
        Varint.encode(UInt64(peerBytes.count), into: &buffer)
        buffer.writeBytes(peerBytes)

        // Field 3: expiration (varint)
        buffer.writeInteger(Self.tagExpiration)
        Varint.encode(expiration, into: &buffer)

        return Data(buffer: buffer)
    }

    public static func unmarshal(_ input: Data) throws -> ReservationVoucher {
        // Rebase to a zero-based buffer (Envelope.payload is a non-zero-based slice).
        let data = input.startIndex == 0 ? input : Data(input)

        var relay: PeerID?
        var peer: PeerID?
        var expiration: UInt64 = 0
        var offset = 0

        while offset < data.count {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeLengthDelimited):
                let fieldData = try decodeLengthDelimitedField(data, offset: &offset)
                relay = try PeerID(bytes: fieldData)

            case (2, wireTypeLengthDelimited):
                let fieldData = try decodeLengthDelimitedField(data, offset: &offset)
                peer = try PeerID(bytes: fieldData)

            case (3, wireTypeVarint):
                let (value, bytesRead) = try Varint.decode(from: data, at: offset)
                expiration = value
                offset += bytesRead

            default:
                offset = try skipField(data, wireType: wireType, offset: offset)
            }
        }

        guard let relay, let peer else {
            throw CircuitRelayError.encodingError("Voucher missing relay or peer field")
        }
        return ReservationVoucher(relay: relay, peer: peer, expiration: expiration)
    }

    private static func decodeLengthDelimitedField(_ data: Data, offset: inout Int) throws -> Data {
        let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
        guard lengthValue <= maxFieldLength else {
            throw CircuitRelayError.encodingError("Voucher field too large")
        }
        offset += lengthBytes

        let fieldLength = try Varint.toInt(lengthValue)
        let end = offset + fieldLength
        guard end <= data.count else {
            throw CircuitRelayError.encodingError("Voucher field truncated")
        }
        let fieldData = Data(data[offset..<end])
        offset = end
        return fieldData
    }

    private static func skipField(_ data: Data, wireType: UInt64, offset: Int) throws -> Int {
        switch wireType {
        case wireTypeVarint:
            let (_, bytesRead) = try Varint.decode(from: data, at: offset)
            return offset + bytesRead
        case 1:
            let end = offset + 8
            guard end <= data.count else { throw CircuitRelayError.encodingError("Voucher truncated") }
            return end
        case wireTypeLengthDelimited:
            var cursor = offset
            _ = try decodeLengthDelimitedField(data, offset: &cursor)
            return cursor
        case 5:
            let end = offset + 4
            guard end <= data.count else { throw CircuitRelayError.encodingError("Voucher truncated") }
            return end
        default:
            throw CircuitRelayError.encodingError("Unsupported wire type \(wireType) in voucher")
        }
    }
}
