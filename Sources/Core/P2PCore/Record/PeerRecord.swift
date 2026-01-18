import Foundation

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
        var data = Data()

        // Peer ID (length-prefixed)
        let peerIDBytes = peerID.bytes
        data.append(contentsOf: Varint.encode(UInt64(peerIDBytes.count)))
        data.append(peerIDBytes)

        // Sequence number (varint)
        data.append(contentsOf: Varint.encode(seq))

        // Number of addresses (varint)
        data.append(contentsOf: Varint.encode(UInt64(addresses.count)))

        // Addresses
        for addr in addresses {
            let addrBytes = try addr.marshal()
            data.append(contentsOf: Varint.encode(UInt64(addrBytes.count)))
            data.append(addrBytes)
        }

        return data
    }

    /// Maximum allowed length for individual fields to prevent DoS attacks.
    private static let maxFieldLength: UInt64 = 64 * 1024  // 64KB
    /// Maximum number of addresses to prevent DoS attacks.
    private static let maxAddressCount: UInt64 = 1000

    public static func unmarshal(_ data: Data) throws -> PeerRecord {
        var offset = 0

        // Peer ID
        let (peerIDLength, pidLenBytes) = try Varint.decode(data[offset...])
        guard peerIDLength <= maxFieldLength else {
            throw PeerRecordError.fieldTooLarge(peerIDLength)
        }
        offset += pidLenBytes
        let peerIDLen = Int(peerIDLength)
        let peerIDEnd = offset + peerIDLen
        guard peerIDEnd <= data.count else {
            throw PeerRecordError.invalidFormat
        }
        let peerID = try PeerID(bytes: Data(data[offset..<peerIDEnd]))
        offset = peerIDEnd

        // Sequence number
        let (seq, seqBytes) = try Varint.decode(data[offset...])
        offset += seqBytes

        // Number of addresses
        let (addressCount, acBytes) = try Varint.decode(data[offset...])
        guard addressCount <= maxAddressCount else {
            throw PeerRecordError.tooManyAddresses(addressCount)
        }
        offset += acBytes

        // Addresses
        var addresses: [AddressInfo] = []
        addresses.reserveCapacity(Int(addressCount))
        for _ in 0..<Int(addressCount) {
            let (addrLength, alBytes) = try Varint.decode(data[offset...])
            guard addrLength <= maxFieldLength else {
                throw PeerRecordError.fieldTooLarge(addrLength)
            }
            offset += alBytes
            let addrLen = Int(addrLength)
            let addrEnd = offset + addrLen
            guard addrEnd <= data.count else {
                throw PeerRecordError.invalidFormat
            }
            let addr = try AddressInfo.unmarshal(Data(data[offset..<addrEnd]))
            addresses.append(addr)
            offset = addrEnd
        }

        return PeerRecord(peerID: peerID, seq: seq, addresses: addresses)
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
        multiaddr.bytes
    }

    /// Deserializes from bytes.
    public static func unmarshal(_ data: Data) throws -> AddressInfo {
        let addr = try Multiaddr(bytes: data)
        return AddressInfo(multiaddr: addr)
    }
}

/// Errors for peer record operations.
public enum PeerRecordError: Error, Sendable {
    case invalidFormat
    case fieldTooLarge(UInt64)
    case tooManyAddresses(UInt64)
}
