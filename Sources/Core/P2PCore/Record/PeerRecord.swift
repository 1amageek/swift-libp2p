import Foundation
import NIOCore

/// A record containing a peer's addresses.
///
/// Peer records are signed and distributed to advertise a peer's
/// listen addresses to other peers in the network.
public struct PeerRecord: SignedRecord, Sendable, Equatable {
    /// The domain for peer records.
    public static let domain = "libp2p-peer-record"

    /// The multicodec for peer records (0x0301).
    public static let codec = Data([0x03, 0x01])

    /// The peer ID this record is for.
    public let peerID: PeerID

    /// The sequence number (for ordering updates).
    public let seq: UInt64

    /// The listen addresses for this peer.
    public let addresses: [AddressInfo]

    /// Creates a new peer record.
    public init(peerID: PeerID, seq: UInt64, addresses: [AddressInfo]) {
        self.peerID = peerID
        self.seq = seq
        self.addresses = addresses
    }

    /// Creates a peer record for the local peer.
    public static func make(
        keyPair: KeyPair,
        seq: UInt64,
        addresses: [Multiaddr]
    ) -> PeerRecord {
        PeerRecord(
            peerID: keyPair.peerID,
            seq: seq,
            addresses: addresses.map { AddressInfo(multiaddr: $0) }
        )
    }

    // MARK: - SignedRecord

    public func marshal() throws -> Data {
        let peerIDBytes = peerID.bytes
        var buffer = ByteBufferAllocator().buffer(capacity: estimatedEncodedSize(peerIDBytes: peerIDBytes))

        // Field 1: peer_id (bytes)
        buffer.writeInteger(Self.tagPeerID)
        Varint.encode(UInt64(peerIDBytes.count), into: &buffer)
        buffer.writeBytes(peerIDBytes)

        // Field 2: seq (varint)
        buffer.writeInteger(Self.tagSequence)
        Varint.encode(seq, into: &buffer)

        // Field 3: addresses (repeated message)
        for addr in addresses {
            let addrBytes = try addr.marshal()
            buffer.writeInteger(Self.tagAddresses)
            Varint.encode(UInt64(addrBytes.count), into: &buffer)
            buffer.writeBytes(addrBytes)
        }

        return Data(buffer: buffer)
    }

    /// Maximum allowed length for individual fields to prevent DoS attacks.
    fileprivate static let maxFieldLength: UInt64 = 64 * 1024  // 64KB
    /// Maximum number of addresses to prevent DoS attacks.
    fileprivate static let maxAddressCount: UInt64 = 1000

    fileprivate static let wireTypeVarint: UInt64 = 0
    fileprivate static let wireTypeLengthDelimited: UInt64 = 2
    fileprivate static let tagPeerID: UInt8 = 0x0A
    fileprivate static let tagSequence: UInt8 = 0x10
    fileprivate static let tagAddresses: UInt8 = 0x1A

    public static func unmarshal(_ data: Data) throws -> PeerRecord {
        var peerID: PeerID?
        var seq: UInt64 = 0
        var addresses: [AddressInfo] = []
        var offset = 0

        while offset < data.count {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, wireTypeLengthDelimited):
                let fieldData = try decodeLengthDelimitedField(data, offset: &offset)
                peerID = try PeerID(bytes: fieldData)

            case (2, wireTypeVarint):
                let (value, bytesRead) = try Varint.decode(from: data, at: offset)
                seq = value
                offset += bytesRead

            case (3, wireTypeLengthDelimited):
                guard addresses.count < Int(maxAddressCount) else {
                    throw PeerRecordError.tooManyAddresses(UInt64(addresses.count + 1))
                }
                let fieldData = try decodeLengthDelimitedField(data, offset: &offset)
                let addr = try AddressInfo.unmarshal(fieldData)
                addresses.append(addr)

            default:
                offset = try skipField(data, wireType: wireType, offset: offset)
            }
        }

        guard let peerID else {
            throw PeerRecordError.invalidFormat
        }

        return PeerRecord(peerID: peerID, seq: seq, addresses: addresses)
    }

    private func estimatedEncodedSize(peerIDBytes: Data) -> Int {
        var size = 1 + Varint.encode(UInt64(peerIDBytes.count)).count + peerIDBytes.count
        size += 1 + Varint.encode(seq).count
        for address in addresses {
            let addressBytes = address.multiaddr.bytes
            let nestedLength = 1 + Varint.encode(UInt64(addressBytes.count)).count + addressBytes.count
            size += 1 + Varint.encode(UInt64(nestedLength)).count + nestedLength
        }
        return size
    }

    fileprivate static func decodeLengthDelimitedField(_ data: Data, offset: inout Int) throws -> Data {
        let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
        guard lengthValue <= maxFieldLength else {
            throw PeerRecordError.fieldTooLarge(lengthValue)
        }
        offset += lengthBytes

        let fieldLength = try Varint.toInt(lengthValue)
        let end = offset + fieldLength
        guard end <= data.count else {
            throw PeerRecordError.invalidFormat
        }

        let fieldData = Data(data[offset..<end])
        offset = end
        return fieldData
    }

    fileprivate static func skipField(_ data: Data, wireType: UInt64, offset: Int) throws -> Int {
        switch wireType {
        case wireTypeVarint:
            let (_, bytesRead) = try Varint.decode(from: data, at: offset)
            return offset + bytesRead

        case 1:
            let end = offset + 8
            guard end <= data.count else {
                throw PeerRecordError.invalidFormat
            }
            return end

        case wireTypeLengthDelimited:
            var cursor = offset
            _ = try decodeLengthDelimitedField(data, offset: &cursor)
            return cursor

        case 5:
            let end = offset + 4
            guard end <= data.count else {
                throw PeerRecordError.invalidFormat
            }
            return end

        default:
            throw PeerRecordError.unsupportedWireType(wireType)
        }
    }
}

/// Address information within a peer record.
public struct AddressInfo: Sendable, Equatable {
    /// The multiaddr.
    public let multiaddr: Multiaddr

    /// Creates address info from a multiaddr.
    public init(multiaddr: Multiaddr) {
        self.multiaddr = multiaddr
    }

    /// Serializes to bytes.
    public func marshal() throws -> Data {
        let bytes = multiaddr.bytes
        var buffer = ByteBufferAllocator().buffer(capacity: 1 + Varint.encode(UInt64(bytes.count)).count + bytes.count)
        buffer.writeInteger(UInt8(0x0A))
        Varint.encode(UInt64(bytes.count), into: &buffer)
        buffer.writeBytes(bytes)
        return Data(buffer: buffer)
    }

    /// Deserializes from bytes.
    public static func unmarshal(_ data: Data) throws -> AddressInfo {
        var offset = 0
        var multiaddr: Multiaddr?

        while offset < data.count {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, 2):
                let (lengthValue, lengthBytes) = try Varint.decode(from: data, at: offset)
                guard lengthValue <= PeerRecord.maxFieldLength else {
                    throw PeerRecordError.fieldTooLarge(lengthValue)
                }
                offset += lengthBytes
                let fieldLength = try Varint.toInt(lengthValue)
                let end = offset + fieldLength
                guard end <= data.count else {
                    throw PeerRecordError.invalidFormat
                }
                multiaddr = try Multiaddr(bytes: Data(data[offset..<end]))
                offset = end

            default:
                offset = try PeerRecord.skipField(data, wireType: wireType, offset: offset)
            }
        }

        guard let multiaddr else {
            throw PeerRecordError.invalidFormat
        }

        return AddressInfo(multiaddr: multiaddr)
    }
}

/// Errors for peer record operations.
public enum PeerRecordError: Error, Sendable {
    case invalidFormat
    case fieldTooLarge(UInt64)
    case tooManyAddresses(UInt64)
    case unsupportedWireType(UInt64)
}
