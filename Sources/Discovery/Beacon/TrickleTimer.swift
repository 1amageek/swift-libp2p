import Foundation
import Synchronization

/// RFC 6206 Trickle algorithm for unified scan/transmit interval control.
///
/// The Trickle algorithm dynamically adjusts the transmission interval based on
/// network consistency. When the network is stable (consistent observations),
/// the interval doubles up to `imax`. When inconsistency is detected (e.g., new
/// peer appears), the interval resets to `imin` for rapid convergence.
///
/// The redundancy constant `k` suppresses transmissions when enough consistent
/// observations have been made within the current interval, reducing unnecessary
/// beacon traffic in dense networks.
public final class TrickleTimer: Sendable {

    private let state: Mutex<TrickleState>

    struct TrickleState: Sendable {
        let imin: Duration
        let imax: Duration
        let k: Int
        var currentInterval: Duration
        var consistentCount: Int
        var intervalStart: ContinuousClock.Instant
    }

    /// Creates a new TrickleTimer.
    ///
    /// - Parameters:
    ///   - imin: Minimum interval duration. The interval resets to this value on inconsistency.
    ///   - imax: Maximum interval duration. The interval will not grow beyond this value.
    ///   - k: Redundancy constant. Transmission is suppressed when the consistent count
    ///         reaches this value. Use `Int.max` to never suppress.
    public init(imin: Duration, imax: Duration, k: Int) {
        let now = ContinuousClock.now
        self.state = Mutex(TrickleState(
            imin: imin,
            imax: imax,
            k: k,
            currentInterval: imin,
            consistentCount: 0,
            intervalStart: now
        ))
    }

    /// Records a consistent observation within the current interval.
    ///
    /// Each call increments the counter used to decide whether transmission
    /// should be suppressed at end-of-interval.
    public func recordConsistent() {
        state.withLock { s in
            s.consistentCount += 1
        }
    }

    /// Records an inconsistent observation, resetting the interval to `imin`.
    ///
    /// Called when a new or changed peer is detected, triggering rapid
    /// re-advertisement to converge quickly.
    public func recordInconsistent() {
        state.withLock { s in
            s.currentInterval = s.imin
            s.consistentCount = 0
            s.intervalStart = ContinuousClock.now
        }
    }

    /// Evaluates the end of the current interval.
    ///
    /// Returns `true` if the node should transmit (i.e., consistent count < k),
    /// then doubles the interval (capped at `imax`) and resets the counter for
    /// the next interval.
    ///
    /// - Returns: `true` if the caller should transmit, `false` if suppressed.
    public func endOfInterval() -> Bool {
        state.withLock { s in
            let shouldTransmit = s.consistentCount < s.k
            // Double the interval, capping at imax
            let doubled = s.currentInterval * 2
            s.currentInterval = doubled <= s.imax ? doubled : s.imax
            s.consistentCount = 0
            s.intervalStart = ContinuousClock.now
            return shouldTransmit
        }
    }

    /// The current interval duration.
    public var currentInterval: Duration {
        state.withLock { $0.currentInterval }
    }

    /// The number of consistent observations recorded in the current interval.
    public var consistentCount: Int {
        state.withLock { $0.consistentCount }
    }
}
