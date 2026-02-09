import Foundation
import Synchronization

/// Exponential Moving Average (EMA) filter for RSSI values.
///
/// Smooths noisy RSSI readings on a per-address basis using the formula:
///   smoothed = alpha * rawRSSI + (1 - alpha) * previousSmoothed
public final class RSSISmoother: Sendable {

    private let state: Mutex<[OpaqueAddress: Double]>
    private let alpha: Double

    /// Creates a new RSSI smoother.
    ///
    /// - Parameter alpha: The smoothing factor (0.0-1.0). Higher values give more weight
    ///   to recent readings. Default is 0.3.
    public init(alpha: Double = 0.3) {
        self.alpha = alpha
        self.state = Mutex([:])
    }

    /// Applies EMA smoothing to a raw RSSI value from a specific address.
    ///
    /// - Parameters:
    ///   - rawRSSI: The raw RSSI reading in dBm.
    ///   - address: The source address for per-address tracking.
    /// - Returns: The smoothed RSSI value.
    public func smooth(rawRSSI: Double, from address: OpaqueAddress) -> Double {
        state.withLock { state in
            if let previous = state[address] {
                let smoothed = alpha * rawRSSI + (1.0 - alpha) * previous
                state[address] = smoothed
                return smoothed
            } else {
                state[address] = rawRSSI
                return rawRSSI
            }
        }
    }

    /// Resets all smoothing state.
    public func reset() {
        state.withLock { state in
            state.removeAll()
        }
    }
}
