import Foundation
import Synchronization

/// Coordinates scanning and transmission scheduling across all registered media.
///
/// Each transport medium is registered with its own Trickle timer parameters,
/// allowing independent interval control per medium. The coordinator delegates
/// consistency/inconsistency signals to the appropriate per-medium timer and
/// provides unified access to transmission decisions.
public final class ScanCoordinator: Sendable {

    private let state: Mutex<CoordinatorState>

    struct CoordinatorState: Sendable {
        var timers: [String: TrickleTimer]
    }

    /// Creates a new scan coordinator with no registered media.
    public init() {
        self.state = Mutex(CoordinatorState(timers: [:]))
    }

    /// Registers a transport medium with its Trickle timer parameters.
    ///
    /// If a medium with the same ID is already registered, its timer is replaced.
    ///
    /// - Parameters:
    ///   - mediumID: Unique identifier for the medium (e.g., "ble", "wifi-direct").
    ///   - imin: Minimum Trickle interval for this medium.
    ///   - imax: Maximum Trickle interval for this medium.
    ///   - k: Redundancy constant for this medium's Trickle timer.
    public func registerMedium(_ mediumID: String, imin: Duration, imax: Duration, k: Int) {
        let timer = TrickleTimer(imin: imin, imax: imax, k: k)
        state.withLock { s in
            s.timers[mediumID] = timer
        }
    }

    /// Returns the current Trickle interval for the specified medium.
    ///
    /// - Parameter mediumID: The medium identifier.
    /// - Returns: The current interval, or `nil` if the medium is not registered.
    public func currentInterval(for mediumID: String) -> Duration? {
        let timer = state.withLock { s in
            s.timers[mediumID]
        }
        return timer?.currentInterval
    }

    /// Reports a consistent observation on the specified medium.
    ///
    /// - Parameter medium: The medium identifier.
    public func reportConsistent(medium: String) {
        let timer = state.withLock { s in
            s.timers[medium]
        }
        timer?.recordConsistent()
    }

    /// Reports an inconsistent observation on the specified medium,
    /// resetting its Trickle interval to `imin`.
    ///
    /// - Parameter medium: The medium identifier.
    public func reportInconsistent(medium: String) {
        let timer = state.withLock { s in
            s.timers[medium]
        }
        timer?.recordInconsistent()
    }

    /// Determines whether the caller should transmit on the specified medium.
    ///
    /// Evaluates the end-of-interval for the medium's Trickle timer.
    ///
    /// - Parameter medium: The medium identifier.
    /// - Returns: `true` if the caller should transmit, `false` if suppressed
    ///   or the medium is not registered.
    public func shouldTransmit(medium: String) -> Bool {
        let timer = state.withLock { s in
            s.timers[medium]
        }
        guard let timer else {
            return false
        }
        return timer.endOfInterval()
    }

    /// Returns the list of registered medium IDs.
    public var registeredMedia: [String] {
        state.withLock { s in
            Array(s.timers.keys)
        }
    }
}
