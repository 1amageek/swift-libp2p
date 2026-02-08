/// BlackHoleDetector - Detects UDP/IPv6 connectivity black holes
///
/// Tracks connection success/failure rates using a rolling window.
/// When the success rate drops below a threshold, the path type
/// is considered a "black hole" and should be avoided.

import P2PCore
import Synchronization

/// Types of network paths that can be black holes.
public enum NetworkPathType: Sendable, Hashable {
    case udp
    case ipv6
}

public final class BlackHoleDetector: Sendable {

    /// Success rate below this is considered a black hole.
    public let threshold: Double

    /// Size of the rolling window.
    public let windowSize: Int

    private let state: Mutex<DetectorState>

    private struct DetectorState: Sendable {
        var results: [NetworkPathType: RollingWindow] = [:]
    }

    struct RollingWindow: Sendable {
        var entries: [Bool] = []  // true = success, false = failure
        let maxSize: Int

        mutating func record(_ success: Bool) {
            entries.append(success)
            if entries.count > maxSize {
                entries.removeFirst()
            }
        }

        var successRate: Double {
            guard !entries.isEmpty else { return 1.0 }
            let successes = entries.filter { $0 }.count
            return Double(successes) / Double(entries.count)
        }

        var hasEnoughData: Bool {
            entries.count >= maxSize / 2  // Need at least half the window
        }
    }

    public init(threshold: Double = 0.05, windowSize: Int = 100) {
        self.threshold = threshold
        self.windowSize = windowSize
        self.state = Mutex(DetectorState())
    }

    /// Records a connection result for a path type.
    public func recordResult(pathType: NetworkPathType, success: Bool) {
        state.withLock { s in
            if s.results[pathType] == nil {
                s.results[pathType] = RollingWindow(maxSize: windowSize)
            }
            s.results[pathType]?.record(success)
        }
    }

    /// Checks if a path type is a black hole.
    public func isBlackHole(_ pathType: NetworkPathType) -> Bool {
        state.withLock { s in
            guard let window = s.results[pathType] else { return false }
            guard window.hasEnoughData else { return false }
            return window.successRate < threshold
        }
    }

    /// Filters out addresses that use black-holed path types.
    public func filterAddresses(_ addresses: [Multiaddr]) -> [Multiaddr] {
        addresses.filter { addr in
            // Check if UDP
            if isUDP(addr) && isBlackHole(.udp) { return false }
            // Check if IPv6
            if isIPv6(addr) && isBlackHole(.ipv6) { return false }
            return true
        }
    }

    /// Returns the success rate for a path type.
    public func successRate(for pathType: NetworkPathType) -> Double? {
        state.withLock { s in
            s.results[pathType]?.successRate
        }
    }

    /// Resets all tracked data.
    public func reset() {
        state.withLock { $0.results.removeAll() }
    }

    // MARK: - Private helpers

    private func isUDP(_ addr: Multiaddr) -> Bool {
        addr.protocols.contains { proto in
            switch proto {
            case .udp: return true
            case .quic, .quicV1: return true  // QUIC uses UDP
            default: return false
            }
        }
    }

    private func isIPv6(_ addr: Multiaddr) -> Bool {
        addr.protocols.contains { proto in
            if case .ip6 = proto { return true }
            return false
        }
    }
}
