/// NATStatus - NAT status type for AutoNAT.

import Foundation
import P2PCore

/// The detected NAT status of a node.
public enum NATStatus: Sendable, Equatable {
    /// NAT status is unknown (not enough probes yet).
    case unknown

    /// Node is publicly reachable at the given address.
    case publicReachable(Multiaddr)

    /// Node is behind NAT (not directly reachable).
    case privateBehindNAT

    /// Whether the node is publicly reachable.
    public var isPublic: Bool {
        if case .publicReachable = self { return true }
        return false
    }

    /// Whether the node is behind NAT.
    public var isPrivate: Bool {
        if case .privateBehindNAT = self { return true }
        return false
    }

    /// The reachable address (if public).
    public var reachableAddress: Multiaddr? {
        if case .publicReachable(let addr) = self { return addr }
        return nil
    }
}

/// Result of a single AutoNAT probe.
public enum ProbeResult: Sendable, Equatable {
    /// Dial succeeded to the given address.
    case reachable(Multiaddr)

    /// Dial failed with the given error.
    case unreachable(AutoNATResponseStatus)

    /// Probe encountered an error.
    case error(String)

    /// Whether the probe indicated reachability.
    public var isReachable: Bool {
        if case .reachable = self { return true }
        return false
    }

    /// The reachable address (if any).
    public var reachableAddress: Multiaddr? {
        if case .reachable(let addr) = self { return addr }
        return nil
    }
}

/// Tracker for NAT status determination with confidence.
public struct NATStatusTracker: Sendable {
    /// Current NAT status.
    public private(set) var status: NATStatus = .unknown

    /// Confidence level (0 to maxConfidence).
    public private(set) var confidence: Int = 0

    /// Maximum confidence level.
    public let maxConfidence: Int

    /// Minimum probes required for determination.
    public let minProbes: Int

    /// History of recent probe results.
    private var recentProbes: [ProbeResult] = []

    /// Maximum probes to keep in history.
    private let maxHistory: Int

    /// Creates a new status tracker.
    public init(minProbes: Int = 3, maxConfidence: Int = 10, maxHistory: Int = 20) {
        self.minProbes = minProbes
        self.maxConfidence = maxConfidence
        self.maxHistory = maxHistory
    }

    /// Records a probe result and updates the status.
    ///
    /// - Parameter result: The probe result.
    /// - Returns: True if the status changed.
    public mutating func recordProbe(_ result: ProbeResult) -> Bool {
        // Add to history
        recentProbes.append(result)
        if recentProbes.count > maxHistory {
            recentProbes.removeFirst()
        }

        // Skip error results for status determination and confidence adjustment
        guard case .error = result else {
            // Continue with non-error result
            return updateStatusFromValidProbes(currentResult: result)
        }

        // For error results, still check if we should update status
        // but don't adjust confidence
        return updateStatusFromValidProbes(currentResult: nil)
    }

    /// Updates status based on valid probes.
    /// - Parameter currentResult: The current non-error result, or nil for error results.
    /// - Returns: True if status changed.
    private mutating func updateStatusFromValidProbes(currentResult: ProbeResult?) -> Bool {
        // Filter to valid (non-error) probes
        let validProbes = recentProbes.filter { probe in
            if case .error = probe { return false }
            return true
        }

        guard validProbes.count >= minProbes else {
            return false
        }

        // Count reachable vs unreachable
        let reachableProbes = validProbes.filter { $0.isReachable }
        let unreachableProbes = validProbes.filter { !$0.isReachable }

        let oldStatus = status

        // Determine status based on majority
        if reachableProbes.count > unreachableProbes.count {
            // Majority say reachable
            if let lastReachable = reachableProbes.last?.reachableAddress {
                status = .publicReachable(lastReachable)
            }
            // Only adjust confidence for non-error results
            if let result = currentResult {
                if case .reachable = result {
                    confidence = min(confidence + 1, maxConfidence)
                } else {
                    confidence = max(confidence - 1, 0)
                }
            }
        } else if unreachableProbes.count > reachableProbes.count {
            // Majority say unreachable
            status = .privateBehindNAT
            // Only adjust confidence for non-error results
            if let result = currentResult {
                if case .unreachable = result {
                    confidence = min(confidence + 1, maxConfidence)
                } else {
                    confidence = max(confidence - 1, 0)
                }
            }
        } else {
            // Tie - keep current status but reduce confidence (only for non-error)
            if currentResult != nil {
                confidence = max(confidence - 1, 0)
            }
        }

        return status != oldStatus
    }

    /// Resets the tracker.
    public mutating func reset() {
        status = .unknown
        confidence = 0
        recentProbes = []
    }
}
