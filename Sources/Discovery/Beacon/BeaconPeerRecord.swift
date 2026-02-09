import Foundation
import P2PCore

/// A signed record containing beacon peer addresses and metadata.
///
/// Implements the `SignedRecord` protocol for use with `Envelope`.
/// This is the beacon-specific replacement for the old `SignedPeerRecord` type,
/// integrating with P2PCore's envelope-based signing infrastructure.
public struct BeaconPeerRecord: SignedRecord, Sendable, Equatable {

    /// Domain string for signature verification (domain separation).
    public static let domain: String = "p2p-beacon-peer-record"

    /// Multicodec identifier for this record type.
    public static let codec: Data = Data([0x03, 0xB0])

    /// The peer this record describes.
    public let peerID: PeerID

    /// Monotonically increasing sequence number.
    public let seq: UInt64

    /// Reachable addresses in opaque format.
    public let opaqueAddresses: [OpaqueAddress]

    public init(peerID: PeerID, seq: UInt64, opaqueAddresses: [OpaqueAddress]) {
        self.peerID = peerID
        self.seq = seq
        self.opaqueAddresses = opaqueAddresses
    }

    // MARK: - SignedRecord

    /// Serializes the record to bytes.
    ///
    /// Format:
    /// - PeerIDLen:       2 bytes (big-endian)
    /// - PeerID:          variable (multihash bytes)
    /// - Seq:             8 bytes (big-endian)
    /// - AddressCount:    2 bytes (big-endian)
    /// - For each address:
    ///   - MediumIDLen:   2 bytes (big-endian)
    ///   - MediumID:      variable (UTF-8)
    ///   - RawLen:        2 bytes (big-endian)
    ///   - Raw:           variable
    public func marshal() throws -> Data {
        let peerIDBytes = peerID.bytes
        var data = Data()
        // PeerID length + bytes
        withUnsafeBytes(of: UInt16(peerIDBytes.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(peerIDBytes)
        // Sequence number
        withUnsafeBytes(of: seq.bigEndian) { data.append(contentsOf: $0) }
        // Address count
        withUnsafeBytes(of: UInt16(opaqueAddresses.count).bigEndian) { data.append(contentsOf: $0) }
        // Addresses
        for addr in opaqueAddresses {
            let mediumData = Data(addr.mediumID.utf8)
            withUnsafeBytes(of: UInt16(mediumData.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(mediumData)
            withUnsafeBytes(of: UInt16(addr.raw.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(addr.raw)
        }
        return data
    }

    /// Deserializes a record from bytes.
    public static func unmarshal(_ data: Data) throws -> BeaconPeerRecord {
        var offset = data.startIndex

        // PeerID length: 2 bytes
        guard offset + 2 <= data.endIndex else {
            throw BeaconPeerRecordError.invalidFormat
        }
        let peerIDLen = Int(data.loadBigEndianUInt16(at: offset))
        offset += 2

        // PeerID bytes
        guard offset + peerIDLen <= data.endIndex else {
            throw BeaconPeerRecordError.invalidFormat
        }
        let peerIDBytes = Data(data[offset..<(offset + peerIDLen)])
        let peerID = try PeerID(bytes: peerIDBytes)
        offset += peerIDLen

        // Sequence number: 8 bytes
        guard offset + 8 <= data.endIndex else {
            throw BeaconPeerRecordError.invalidFormat
        }
        let seq = data.loadBigEndianUInt64(at: offset)
        offset += 8

        // Address count: 2 bytes
        guard offset + 2 <= data.endIndex else {
            throw BeaconPeerRecordError.invalidFormat
        }
        let addressCount = Int(data.loadBigEndianUInt16(at: offset))
        offset += 2

        var addresses: [OpaqueAddress] = []
        addresses.reserveCapacity(addressCount)

        for _ in 0..<addressCount {
            // Medium ID length: 2 bytes
            guard offset + 2 <= data.endIndex else {
                throw BeaconPeerRecordError.invalidFormat
            }
            let mediumIDLen = Int(data.loadBigEndianUInt16(at: offset))
            offset += 2

            // Medium ID
            guard offset + mediumIDLen <= data.endIndex else {
                throw BeaconPeerRecordError.invalidFormat
            }
            let mediumIDData = data[offset..<(offset + mediumIDLen)]
            guard let mediumID = String(data: Data(mediumIDData), encoding: .utf8) else {
                throw BeaconPeerRecordError.invalidFormat
            }
            offset += mediumIDLen

            // Raw length: 2 bytes
            guard offset + 2 <= data.endIndex else {
                throw BeaconPeerRecordError.invalidFormat
            }
            let rawLen = Int(data.loadBigEndianUInt16(at: offset))
            offset += 2

            // Raw data
            guard offset + rawLen <= data.endIndex else {
                throw BeaconPeerRecordError.invalidFormat
            }
            let raw = Data(data[offset..<(offset + rawLen)])
            offset += rawLen

            addresses.append(OpaqueAddress(mediumID: mediumID, raw: raw))
        }

        return BeaconPeerRecord(peerID: peerID, seq: seq, opaqueAddresses: addresses)
    }
}

/// Errors that can occur when working with beacon peer records.
public enum BeaconPeerRecordError: Error, Sendable {
    case invalidFormat
}
