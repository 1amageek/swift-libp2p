import Foundation
import Crypto
import Synchronization

/// Delayed key disclosure broadcast authentication (micro-TESLA).
///
/// Generates a one-way hash chain `K[0], K[1], ..., K[n]` where
/// `K[i-1] = SHA256(K[i])`. Keys are disclosed in reverse order:
/// epoch 0 uses `K[n]`, epoch 1 uses `K[n-1]`, etc.
///
/// Each epoch:
/// - The current key computes `HMAC-SHA256(K[current], data)` truncated to 4 bytes (MAC).
/// - The previous epoch's actual key is disclosed as `K[previous][0..<8]` (8 bytes).
/// - Receivers verify the chain by checking `SHA256(disclosed)[0..<8] == commitment`.
public final class MicroTESLA: Sendable {
    private let state: Mutex<TESLAState>

    struct TESLAState: Sendable {
        let chainLength: Int
        let keys: [Data]       // K[0]...K[n], where K[i-1] = SHA256(K[i])
        var currentEpoch: Int  // starts at 0, increments each advance
    }

    /// Creates a new micro-TESLA instance with a hash chain derived from the seed.
    ///
    /// - Parameters:
    ///   - seed: Random seed to generate the chain tail `K[n]`.
    ///   - chainLength: Number of keys in the chain (default 1000).
    public init(seed: Data, chainLength: Int = 1000) {
        precondition(chainLength > 0, "chainLength must be positive")

        // Generate chain: K[n] = SHA256(seed), then K[i-1] = SHA256(K[i])
        var current = Data(SHA256.hash(data: seed))
        var chain = [Data](repeating: Data(), count: chainLength)
        chain[chainLength - 1] = current
        for i in stride(from: chainLength - 2, through: 0, by: -1) {
            current = Data(SHA256.hash(data: current))
            chain[i] = current
        }

        self.state = Mutex(TESLAState(
            chainLength: chainLength,
            keys: chain,
            currentEpoch: 0
        ))
    }

    /// Computes the HMAC-SHA256 of `data` using the current epoch's key, truncated to 4 bytes.
    ///
    /// - Parameter data: The data to authenticate.
    /// - Returns: 4-byte truncated HMAC.
    public func macForCurrentEpoch(data: Data) -> Data {
        state.withLock { s in
            let keyIndex = s.chainLength - 1 - s.currentEpoch
            guard keyIndex >= 0, keyIndex < s.keys.count else {
                return Data(repeating: 0, count: 4)
            }
            let key = SymmetricKey(data: s.keys[keyIndex])
            let mac = HMAC<SHA256>.authenticationCode(for: data, using: key)
            return Data(mac.prefix(4))
        }
    }

    /// Returns the previous epoch's key disclosure: first 8 bytes of `K[previous]`.
    ///
    /// - Returns: 8-byte truncated actual key from the previous epoch, or zeros if at epoch 0.
    public func previousKey() -> Data {
        state.withLock { s in
            guard s.currentEpoch > 0 else {
                return Data(repeating: 0, count: 8)
            }
            let previousKeyIndex = s.chainLength - 1 - (s.currentEpoch - 1)
            guard previousKeyIndex >= 0, previousKeyIndex < s.keys.count else {
                return Data(repeating: 0, count: 8)
            }
            return Data(s.keys[previousKeyIndex].prefix(8))
        }
    }

    /// Advances to the next epoch. Returns `false` if the chain is exhausted.
    @discardableResult
    public func advanceEpoch() -> Bool {
        state.withLock { s in
            guard s.currentEpoch < s.chainLength - 1 else { return false }
            s.currentEpoch += 1
            return true
        }
    }

    /// The current epoch index.
    public var currentEpoch: Int {
        state.withLock { $0.currentEpoch }
    }

    /// Verifies that `previousDisclosed` is the preimage of `currentKey` in the hash chain.
    ///
    /// Checks: `SHA256(previousDisclosed)[0..<8] == currentKey[0..<8]`
    ///
    /// - Parameters:
    ///   - currentKey: The 8-byte truncated key from the current epoch.
    ///   - previousDisclosed: The full key disclosed from the previous epoch.
    /// - Returns: `true` if the chain link is valid.
    public static func verifyChain(currentKey: Data, previousDisclosed: Data) -> Bool {
        let hash = SHA256.hash(data: previousDisclosed)
        let truncated = Data(hash.prefix(currentKey.count))
        return truncated == currentKey
    }
}
