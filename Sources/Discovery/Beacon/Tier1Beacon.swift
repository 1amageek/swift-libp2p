import Foundation
import Crypto

/// Tier 1 beacon: minimal 10-byte format.
///
/// Layout (10 bytes total):
/// - Tag:     1 byte  (0xD0)
/// - TruncID: 2 bytes (big-endian)
/// - PoW:     3 bytes
/// - Nonce:   4 bytes (big-endian)
public struct Tier1Beacon: Sendable {
    /// The tag byte identifying this as a Tier 1 beacon (0xD0).
    public let tag: UInt8

    /// Truncated peer identifier (first 2 bytes of EphID).
    public let truncID: UInt16

    /// 3-byte proof of work.
    public let pow: (UInt8, UInt8, UInt8)

    /// 4-byte nonce for freshness and PoW input.
    public let nonce: UInt32

    /// Total encoded size in bytes.
    public static let encodedSize: Int = 10

    public init(truncID: UInt16, pow: (UInt8, UInt8, UInt8), nonce: UInt32) {
        self.tag = BeaconTier.tier1.tagByte
        self.truncID = truncID
        self.pow = pow
        self.nonce = nonce
    }

    /// Encodes the beacon into a 10-byte `Data`.
    public func encode() -> Data {
        var data = Data(capacity: Self.encodedSize)
        data.append(tag)
        withUnsafeBytes(of: truncID.bigEndian) { data.append(contentsOf: $0) }
        data.append(pow.0)
        data.append(pow.1)
        data.append(pow.2)
        withUnsafeBytes(of: nonce.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Decodes a Tier 1 beacon from raw data.
    ///
    /// - Parameter data: Exactly 10 bytes of beacon payload.
    /// - Returns: A decoded `Tier1Beacon`, or `nil` if the data is invalid.
    public static func decode(from data: Data) -> Tier1Beacon? {
        guard data.count >= encodedSize else { return nil }
        guard BeaconTier(tagByte: data[data.startIndex]) == .tier1 else { return nil }

        let truncID = data.loadBigEndianUInt16(at: data.startIndex + 1)
        let powBytes = (
            data[data.startIndex + 3],
            data[data.startIndex + 4],
            data[data.startIndex + 5]
        )
        let nonce = data.loadBigEndianUInt32(at: data.startIndex + 6)

        return Tier1Beacon(truncID: truncID, pow: powBytes, nonce: nonce)
    }

    /// Validates the proof-of-work for this beacon.
    ///
    /// - Parameter difficulty: Number of leading zero bits required (default 16).
    /// - Returns: `true` if the PoW is valid.
    public func isValid(difficulty: Int = MicroPoW.defaultDifficulty) -> Bool {
        MicroPoW.verify(truncID: truncID, nonce: nonce, pow: pow, difficulty: difficulty)
    }
}
