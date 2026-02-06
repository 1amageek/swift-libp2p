/// PeerLatencyTracker - Tracks per-peer latency for adaptive query behavior.

import Foundation
import Synchronization
import P2PCore

/// Tracks per-peer latency statistics for Kademlia queries.
///
/// Records round-trip times and success/failure counts per peer,
/// enabling adaptive timeout calculation and dynamic alpha tuning.
public final class PeerLatencyTracker: Sendable {

    private struct PeerStats: Sendable {
        var latencySum: Duration = .zero
        var latencyCount: Int = 0
        var successCount: Int = 0
        var failureCount: Int = 0
        var lastUpdated: ContinuousClock.Instant = .now
    }

    private let stats: Mutex<[PeerID: PeerStats]>

    /// Maximum number of peers to track.
    private let maxPeers: Int

    /// Creates a new peer latency tracker.
    ///
    /// - Parameter maxPeers: Maximum number of peers to track (default: 1000).
    public init(maxPeers: Int = 1000) {
        self.maxPeers = maxPeers
        self.stats = Mutex([:])
    }

    /// Records a successful request with its latency.
    ///
    /// - Parameters:
    ///   - peer: The peer that responded.
    ///   - latency: The round-trip time.
    public func recordSuccess(peer: PeerID, latency: Duration) {
        stats.withLock { stats in
            var entry = stats[peer] ?? PeerStats()
            entry.latencySum += latency
            entry.latencyCount += 1
            entry.successCount += 1
            entry.lastUpdated = .now
            stats[peer] = entry

            // Evict oldest entries if over capacity
            if stats.count > maxPeers {
                evictOldest(&stats)
            }
        }
    }

    /// Records a failed request.
    ///
    /// - Parameter peer: The peer that failed to respond.
    public func recordFailure(peer: PeerID) {
        stats.withLock { stats in
            var entry = stats[peer] ?? PeerStats()
            entry.failureCount += 1
            entry.lastUpdated = .now
            stats[peer] = entry

            if stats.count > maxPeers {
                evictOldest(&stats)
            }
        }
    }

    /// Returns the average latency for a peer.
    ///
    /// - Parameter peer: The peer to query.
    /// - Returns: The average latency, or nil if no data.
    public func averageLatency(for peer: PeerID) -> Duration? {
        stats.withLock { stats in
            guard let entry = stats[peer], entry.latencyCount > 0 else { return nil }
            return entry.latencySum / entry.latencyCount
        }
    }

    /// Calculates a suggested timeout for a peer based on historical latency.
    ///
    /// Returns 3x the average latency, clamped to [1s, defaultTimeout].
    ///
    /// - Parameters:
    ///   - peer: The peer to calculate timeout for.
    ///   - defaultTimeout: The fallback timeout if no data is available.
    /// - Returns: The suggested timeout duration.
    public func suggestedTimeout(for peer: PeerID, default defaultTimeout: Duration) -> Duration {
        stats.withLock { stats in
            guard let entry = stats[peer], entry.latencyCount > 0 else {
                return defaultTimeout
            }
            let avg = entry.latencySum / entry.latencyCount
            let suggested = avg * 3
            let minTimeout = Duration.seconds(1)
            if suggested < minTimeout { return minTimeout }
            if suggested > defaultTimeout { return defaultTimeout }
            return suggested
        }
    }

    /// Returns the success rate for a peer (0.0 to 1.0).
    ///
    /// - Parameter peer: The peer to query.
    /// - Returns: The success rate, or nil if no data.
    public func successRate(for peer: PeerID) -> Double? {
        stats.withLock { stats in
            guard let entry = stats[peer] else { return nil }
            let total = entry.successCount + entry.failureCount
            guard total > 0 else { return nil }
            return Double(entry.successCount) / Double(total)
        }
    }

    /// Returns the overall success rate across all tracked peers.
    ///
    /// - Returns: The overall success rate (0.0 to 1.0), or nil if no data.
    public func overallSuccessRate() -> Double? {
        stats.withLock { stats in
            var totalSuccess = 0
            var totalFailure = 0
            for entry in stats.values {
                totalSuccess += entry.successCount
                totalFailure += entry.failureCount
            }
            let total = totalSuccess + totalFailure
            guard total > 0 else { return nil }
            return Double(totalSuccess) / Double(total)
        }
    }

    /// Returns the overall average latency across all tracked peers.
    ///
    /// - Returns: The overall average latency, or nil if no data.
    public func overallAverageLatency() -> Duration? {
        stats.withLock { stats in
            var totalSum: Duration = .zero
            var totalCount = 0
            for entry in stats.values {
                totalSum += entry.latencySum
                totalCount += entry.latencyCount
            }
            guard totalCount > 0 else { return nil }
            return totalSum / totalCount
        }
    }

    /// Removes entries older than the specified duration.
    ///
    /// - Parameter threshold: Remove entries not updated within this duration.
    public func cleanup(olderThan threshold: Duration) {
        let cutoff = ContinuousClock.now - threshold
        stats.withLock { stats in
            stats = stats.filter { $0.value.lastUpdated >= cutoff }
        }
    }

    /// The number of peers currently being tracked.
    public var trackedPeerCount: Int {
        stats.withLock { $0.count }
    }

    /// Removes all tracked data.
    public func clear() {
        stats.withLock { $0.removeAll() }
    }

    // MARK: - Private

    private func evictOldest(_ stats: inout [PeerID: PeerStats]) {
        guard let oldest = stats.min(by: { $0.value.lastUpdated < $1.value.lastUpdated }) else {
            return
        }
        stats.removeValue(forKey: oldest.key)
    }
}
