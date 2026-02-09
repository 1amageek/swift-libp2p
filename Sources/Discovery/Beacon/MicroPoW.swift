import Foundation
import Crypto

/// SHA-256 client puzzle with configurable bit difficulty.
///
/// The puzzle requires finding a 3-byte proof such that
/// `SHA256(truncID || nonce || pow)` has at least `difficulty` leading zero bits.
public struct MicroPoW: Sendable {
    /// Default difficulty: 16 leading zero bits.
    public static let defaultDifficulty: Int = 16

    /// Solves the PoW puzzle by brute-force searching for a valid 3-byte proof.
    ///
    /// - Parameters:
    ///   - truncID: The 2-byte truncated peer ID.
    ///   - nonce: The 4-byte nonce.
    ///   - difficulty: Number of leading zero bits required (default 16).
    /// - Returns: A 3-byte proof of work tuple.
    public static func solve(
        truncID: UInt16,
        nonce: UInt32,
        difficulty: Int = defaultDifficulty
    ) -> (UInt8, UInt8, UInt8) {
        let prefix = buildPrefix(truncID: truncID, nonce: nonce)
        // Brute force over 3-byte space (2^24 = 16M possibilities)
        for i: UInt32 in 0..<(1 << 24) {
            let b0 = UInt8((i >> 16) & 0xFF)
            let b1 = UInt8((i >> 8) & 0xFF)
            let b2 = UInt8(i & 0xFF)
            var input = prefix
            input.append(b0)
            input.append(b1)
            input.append(b2)
            let hash = SHA256.hash(data: input)
            if hasLeadingZeroBits(hash: hash, count: difficulty) {
                return (b0, b1, b2)
            }
        }
        // Fallback (should not happen for difficulty <= 24)
        return (0, 0, 0)
    }

    /// Verifies a proof-of-work solution.
    ///
    /// - Parameters:
    ///   - truncID: The 2-byte truncated peer ID.
    ///   - nonce: The 4-byte nonce.
    ///   - pow: The 3-byte proof of work.
    ///   - difficulty: Number of leading zero bits required (default 16).
    /// - Returns: `true` if the proof is valid.
    public static func verify(
        truncID: UInt16,
        nonce: UInt32,
        pow: (UInt8, UInt8, UInt8),
        difficulty: Int = defaultDifficulty
    ) -> Bool {
        var input = buildPrefix(truncID: truncID, nonce: nonce)
        input.append(pow.0)
        input.append(pow.1)
        input.append(pow.2)
        let hash = SHA256.hash(data: input)
        return hasLeadingZeroBits(hash: hash, count: difficulty)
    }

    // MARK: - Internal Helpers

    /// Builds the prefix bytes: truncID (big-endian) + nonce (big-endian).
    private static func buildPrefix(truncID: UInt16, nonce: UInt32) -> Data {
        var data = Data(capacity: 6)
        withUnsafeBytes(of: truncID.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: nonce.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Checks whether the hash has at least `count` leading zero bits.
    private static func hasLeadingZeroBits(
        hash: SHA256.Digest,
        count: Int
    ) -> Bool {
        let bytes = Array(hash)
        var zeroBits = 0
        for byte in bytes {
            if byte == 0 {
                zeroBits += 8
                if zeroBits >= count { return true }
            } else {
                zeroBits += byte.leadingZeroBitCount
                return zeroBits >= count
            }
        }
        return zeroBits >= count
    }
}
