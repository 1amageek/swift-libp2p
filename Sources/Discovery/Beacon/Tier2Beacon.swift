import Foundation
import Crypto

/// Tier 2 beacon: extended 32-byte format with TESLA and capabilities.
///
/// Layout (32 bytes total):
/// - Tag:      1 byte  (0xD1)
/// - TruncID:  2 bytes (big-endian)
/// - PoW:      3 bytes
/// - Nonce:    4 bytes (big-endian)
/// - MAC_t:    4 bytes (HMAC-SHA256 truncated)
/// - Key_p:    8 bytes (previous TESLA key, SHA256 truncated)
/// - CapBloom: 10 bytes (capability bloom filter)
public struct Tier2Beacon: Sendable {
    /// The tag byte identifying this as a Tier 2 beacon (0xD1).
    public let tag: UInt8

    /// Truncated peer identifier (first 2 bytes of EphID).
    public let truncID: UInt16

    /// 3-byte proof of work.
    public let pow: (UInt8, UInt8, UInt8)

    /// 4-byte nonce for freshness and PoW input.
    public let nonce: UInt32

    /// HMAC-SHA256 truncated to 4 bytes for micro-TESLA authentication.
    public let macT: Data

    /// Previous epoch TESLA key truncated to 8 bytes.
    public let keyP: Data

    /// Capability bloom filter (10 bytes).
    public let capBloom: Data

    /// Total encoded size in bytes.
    public static let encodedSize: Int = 32

    public init(
        truncID: UInt16,
        pow: (UInt8, UInt8, UInt8),
        nonce: UInt32,
        macT: Data,
        keyP: Data,
        capBloom: Data
    ) {
        precondition(macT.count == 4, "macT must be 4 bytes")
        precondition(keyP.count == 8, "keyP must be 8 bytes")
        precondition(capBloom.count == 10, "capBloom must be 10 bytes")
        self.tag = BeaconTier.tier2.tagByte
        self.truncID = truncID
        self.pow = pow
        self.nonce = nonce
        self.macT = macT
        self.keyP = keyP
        self.capBloom = capBloom
    }

    /// Encodes the beacon into a 32-byte `Data`.
    public func encode() -> Data {
        var data = Data(capacity: Self.encodedSize)
        data.append(tag)
        withUnsafeBytes(of: truncID.bigEndian) { data.append(contentsOf: $0) }
        data.append(pow.0)
        data.append(pow.1)
        data.append(pow.2)
        withUnsafeBytes(of: nonce.bigEndian) { data.append(contentsOf: $0) }
        data.append(macT)
        data.append(keyP)
        data.append(capBloom)
        return data
    }

    /// Decodes a Tier 2 beacon from raw data.
    ///
    /// - Parameter data: Exactly 32 bytes of beacon payload.
    /// - Returns: A decoded `Tier2Beacon`, or `nil` if the data is invalid.
    public static func decode(from data: Data) -> Tier2Beacon? {
        guard data.count >= encodedSize else { return nil }
        guard BeaconTier(tagByte: data[data.startIndex]) == .tier2 else { return nil }

        let base = data.startIndex
        let truncID = data.loadBigEndianUInt16(at: base + 1)
        let powBytes = (
            data[base + 3],
            data[base + 4],
            data[base + 5]
        )
        let nonce = data.loadBigEndianUInt32(at: base + 6)
        let macT = data.subdata(in: (base + 10)..<(base + 14))
        let keyP = data.subdata(in: (base + 14)..<(base + 22))
        let capBloom = data.subdata(in: (base + 22)..<(base + 32))

        return Tier2Beacon(
            truncID: truncID,
            pow: powBytes,
            nonce: nonce,
            macT: macT,
            keyP: keyP,
            capBloom: capBloom
        )
    }

    /// Validates the proof-of-work for this beacon.
    ///
    /// - Parameter difficulty: Number of leading zero bits required (default 16).
    /// - Returns: `true` if the PoW is valid.
    public func isValid(difficulty: Int = MicroPoW.defaultDifficulty) -> Bool {
        MicroPoW.verify(truncID: truncID, nonce: nonce, pow: pow, difficulty: difficulty)
    }
}
