import Foundation
import Crypto
import P2PCore

/// Tier 3 beacon: variable-length format with full identity and signed envelope.
///
/// Wire format (variable length):
/// - Tag:          1 byte  (0xD2)
/// - PeerIDLen:    2 bytes (big-endian, length of PeerID multihash bytes)
/// - PeerID:       variable (multihash bytes)
/// - Nonce:        4 bytes (big-endian)
/// - EnvelopeLen:  2 bytes (big-endian, length of marshaled Envelope)
/// - Envelope:     variable (Envelope.marshal() output)
///
/// PeerID is variable-length (P2PCore.PeerID uses multihash encoding).
/// The record is wrapped in an Envelope (P2PCore.Envelope) instead of custom serialization.
public struct Tier3Beacon: Sendable {
    /// The tag byte identifying this as a Tier 3 beacon (0xD2).
    public let tag: UInt8

    /// Full peer identity (variable-length multihash bytes).
    public let peerIDBytes: Data

    /// 4-byte nonce for freshness.
    public let nonce: UInt32

    /// The signed envelope containing a BeaconPeerRecord.
    public let envelope: Envelope

    /// Minimum header size before variable fields: tag(1) + peerIDLen(2) + nonce(4) + envelopeLen(2) = 9
    public static let minHeaderSize: Int = 9

    public init(peerIDBytes: Data, nonce: UInt32, envelope: Envelope) {
        self.tag = BeaconTier.tier3.tagByte
        self.peerIDBytes = peerIDBytes
        self.nonce = nonce
        self.envelope = envelope
    }

    /// Convenience initializer from a PeerID.
    public init(peerID: PeerID, nonce: UInt32, envelope: Envelope) {
        self.init(peerIDBytes: peerID.bytes, nonce: nonce, envelope: envelope)
    }

    /// Encodes the beacon into `Data`.
    public func encode() throws -> Data {
        let envelopeData = try envelope.marshal()
        let capacity = Self.minHeaderSize + peerIDBytes.count + envelopeData.count
        var data = Data(capacity: capacity)

        // Tag
        data.append(tag)
        // PeerID length + bytes
        withUnsafeBytes(of: UInt16(peerIDBytes.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(peerIDBytes)
        // Nonce
        withUnsafeBytes(of: nonce.bigEndian) { data.append(contentsOf: $0) }
        // Envelope length + bytes
        withUnsafeBytes(of: UInt16(envelopeData.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(envelopeData)

        return data
    }

    /// Decodes a Tier 3 beacon from raw data.
    ///
    /// - Parameter data: Variable-length beacon payload.
    /// - Returns: A decoded `Tier3Beacon`, or `nil` if the data is invalid.
    public static func decode(from data: Data) -> Tier3Beacon? {
        // Minimum: tag(1) + peerIDLen(2) = 3 bytes to start
        guard data.count >= 3 else { return nil }
        guard BeaconTier(tagByte: data[data.startIndex]) == .tier3 else { return nil }

        let base = data.startIndex
        var offset = base + 1

        // PeerID length: 2 bytes
        guard offset + 2 <= data.endIndex else { return nil }
        let peerIDLen = Int(data.loadBigEndianUInt16(at: offset))
        offset += 2

        // PeerID bytes
        guard offset + peerIDLen <= data.endIndex else { return nil }
        let peerIDBytes = data.subdata(in: offset..<(offset + peerIDLen))
        offset += peerIDLen

        // Nonce: 4 bytes
        guard offset + 4 <= data.endIndex else { return nil }
        let nonce = data.loadBigEndianUInt32(at: offset)
        offset += 4

        // Envelope length: 2 bytes
        guard offset + 2 <= data.endIndex else { return nil }
        let envelopeLen = Int(data.loadBigEndianUInt16(at: offset))
        offset += 2

        // Envelope bytes
        guard offset + envelopeLen <= data.endIndex else { return nil }
        let envelopeData = data.subdata(in: offset..<(offset + envelopeLen))

        do {
            let envelope = try Envelope.unmarshal(envelopeData)
            return Tier3Beacon(peerIDBytes: peerIDBytes, nonce: nonce, envelope: envelope)
        } catch {
            return nil
        }
    }
}
