import Foundation
import Synchronization

/// BLE-specific discovery scheduler combining per-channel Trickle timers
/// with Spear PPR (Probabilistic Proportional Randomization) backoff.
///
/// BLE advertising uses three fixed channels (37, 38, 39). Each channel
/// maintains its own Trickle timer for independent interval control.
/// The Spear PPR backoff adds a random delay (0..<50ms) to reduce
/// collision probability on shared advertising channels.
public final class BLEDiscoveryScheduler: Sendable {

    /// The three BLE advertising channel indices.
    public static let advertisingChannels: [UInt8] = [37, 38, 39]

    /// Maximum Spear PPR backoff in nanoseconds (50ms).
    private static let maxBackoffNanoseconds: UInt64 = 50_000_000

    private let state: Mutex<SchedulerState>

    struct SchedulerState: Sendable {
        var channelTimers: [UInt8: TrickleTimer]
    }

    /// Creates a BLE discovery scheduler with per-channel Trickle timers.
    ///
    /// - Parameters:
    ///   - imin: Minimum Trickle interval for each channel.
    ///   - imax: Maximum Trickle interval for each channel.
    ///   - k: Redundancy constant for each channel's Trickle timer.
    public init(imin: Duration = .milliseconds(100), imax: Duration = .seconds(60), k: Int = 1) {
        var timers: [UInt8: TrickleTimer] = [:]
        for channel in Self.advertisingChannels {
            timers[channel] = TrickleTimer(imin: imin, imax: imax, k: k)
        }
        self.state = Mutex(SchedulerState(channelTimers: timers))
    }

    /// Result of a transmission decision for a BLE channel.
    public struct TransmitDecision: Sendable {
        /// Whether the caller should transmit on this channel.
        public let transmit: Bool
        /// Random backoff duration to wait before transmitting (Spear PPR).
        public let backoff: Duration
    }

    /// Determines whether to transmit on the specified BLE advertising channel.
    ///
    /// Evaluates the Trickle timer for the channel and generates a random
    /// Spear PPR backoff delay to reduce collision probability.
    ///
    /// - Parameter channel: The BLE advertising channel index (37, 38, or 39).
    /// - Returns: A `TransmitDecision` with the transmit flag and backoff duration.
    public func shouldTransmit(on channel: UInt8) -> TransmitDecision {
        let timer = state.withLock { s in
            s.channelTimers[channel]
        }
        guard let timer else {
            return TransmitDecision(transmit: false, backoff: .zero)
        }
        let transmit = timer.endOfInterval()
        let randomNanos = UInt64.random(in: 0..<Self.maxBackoffNanoseconds)
        let backoff = Duration.nanoseconds(randomNanos)
        return TransmitDecision(transmit: transmit, backoff: backoff)
    }

    /// Records a consistent observation on the specified channel.
    ///
    /// - Parameter channel: The BLE advertising channel index.
    public func recordConsistent(on channel: UInt8) {
        let timer = state.withLock { s in
            s.channelTimers[channel]
        }
        timer?.recordConsistent()
    }

    /// Records an inconsistent observation on the specified channel,
    /// resetting its Trickle interval to `imin`.
    ///
    /// - Parameter channel: The BLE advertising channel index.
    public func recordInconsistent(on channel: UInt8) {
        let timer = state.withLock { s in
            s.channelTimers[channel]
        }
        timer?.recordInconsistent()
    }

    /// Returns the current Trickle interval for the specified channel.
    ///
    /// - Parameter channel: The BLE advertising channel index.
    /// - Returns: The current interval, or `nil` if the channel is not registered.
    public func currentInterval(for channel: UInt8) -> Duration? {
        let timer = state.withLock { s in
            s.channelTimers[channel]
        }
        return timer?.currentInterval
    }
}
