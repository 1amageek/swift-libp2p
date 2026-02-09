import Foundation
import Crypto
import P2PCore

/// DP-3T style ephemeral identifier generator using HKDF-SHA256.
///
/// Generates rotating ephemeral IDs derived from the key pair's private key.
/// The EphID changes every `rotationInterval` (default 10 minutes).
///
/// Derivation chain:
/// 1. `daySeed = HKDF-SHA256(secret, info: "day" || dayNumber)`
/// 2. `ephID = HKDF-SHA256(daySeed, info: epochIndex)` (4 bytes)
/// 3. `truncID = ephID[0..<2]` as UInt16
/// 4. `nonce = ephID[0..<4]` as UInt32
public final class EphIDGenerator: Sendable {
    private let keyPair: KeyPair

    /// How often the EphID rotates (default 10 minutes).
    public let rotationInterval: Duration

    /// Reference point for epoch calculations.
    /// Using a fixed reference avoids depending on wall-clock time.
    private let referencePoint: ContinuousClock.Instant

    public init(
        keyPair: KeyPair,
        rotationInterval: Duration = .seconds(600),
        referencePoint: ContinuousClock.Instant = .now
    ) {
        self.keyPair = keyPair
        self.rotationInterval = rotationInterval
        self.referencePoint = referencePoint
    }

    /// Generates the 4-byte ephemeral ID for the given instant.
    ///
    /// - Parameter instant: The point in time (defaults to now).
    /// - Returns: 4 bytes of derived ephemeral ID.
    public func ephID(at instant: ContinuousClock.Instant = .now) -> Data {
        let dayNum = dayNumber(at: instant)
        let seed = daySeed(dayNumber: dayNum)
        let epoch = epochIndex(at: instant)

        var epochBytes = Data(capacity: 4)
        withUnsafeBytes(of: UInt32(epoch).bigEndian) { epochBytes.append(contentsOf: $0) }

        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: seed,
            info: epochBytes,
            outputByteCount: 4
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    /// Returns the truncated 2-byte peer ID for the given instant.
    ///
    /// - Parameter instant: The point in time (defaults to now).
    /// - Returns: First 2 bytes of EphID as UInt16.
    public func truncID(at instant: ContinuousClock.Instant = .now) -> UInt16 {
        let id = ephID(at: instant)
        return id.loadBigEndianUInt16(at: id.startIndex)
    }

    /// Returns the 4-byte nonce for the given instant.
    ///
    /// - Parameter instant: The point in time (defaults to now).
    /// - Returns: All 4 bytes of EphID as UInt32.
    public func nonce(at instant: ContinuousClock.Instant = .now) -> UInt32 {
        let id = ephID(at: instant)
        return id.loadBigEndianUInt32(at: id.startIndex)
    }

    // MARK: - Internal

    /// Computes the day number from a continuous clock instant.
    /// Each "day" is 86400 seconds from the reference point.
    func dayNumber(at instant: ContinuousClock.Instant) -> UInt32 {
        let elapsed = instant - referencePoint
        let seconds = elapsed.totalSeconds
        if seconds < 0 { return 0 }
        return UInt32(seconds / 86400)
    }

    /// Derives a per-day seed using HKDF.
    func daySeed(dayNumber: UInt32) -> SymmetricKey {
        var info = Data("day".utf8)
        withUnsafeBytes(of: dayNumber.bigEndian) { info.append(contentsOf: $0) }

        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyPair.privateKey.rawBytes),
            info: info,
            outputByteCount: 32
        )
    }

    /// Computes the epoch index within the current day.
    func epochIndex(at instant: ContinuousClock.Instant) -> Int {
        let elapsed = instant - referencePoint
        let seconds = elapsed.totalSeconds
        if seconds < 0 { return 0 }
        let intervalSeconds = rotationInterval.totalSeconds
        guard intervalSeconds > 0 else { return 0 }
        let totalEpoch = Int(seconds / intervalSeconds)
        let epochsPerDay = Int(86400.0 / intervalSeconds)
        guard epochsPerDay > 0 else { return 0 }
        return totalEpoch % epochsPerDay
    }
}

// MARK: - Duration Extension

extension Duration {
    /// Converts the duration to total seconds as a Double.
    var totalSeconds: Double {
        let (seconds, attoseconds) = self.components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}
