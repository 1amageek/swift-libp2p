import Foundation
import Synchronization

/// Three-stage beacon filter providing PoW verification, rate limiting,
/// and Sybil attack detection.
///
/// **Stage 1: Proof-of-Work verification** -- Rejects beacons with invalid PoW,
/// filtering out computationally lazy spammers.
///
/// **Stage 2: Rate limiting** -- Deduplicates beacons by (truncID, mediumID) pair,
/// enforcing a minimum interval between accepted beacons from the same source.
///
/// **Stage 3: Sybil detection** -- Tracks how many distinct truncIDs appear from
/// the same physical fingerprint within a sliding window. If a single physical
/// source claims too many identities, it is flagged as a Sybil attacker and
/// its beacons are rejected.
public final class BeaconFilter: Sendable {

    private let state: Mutex<FilterState>
    private let sybilThreshold: Int
    private let sybilWindow: Duration

    struct FilterState: Sendable {
        var recentBeacons: [BeaconKey: ContinuousClock.Instant]
        var fingerprintClusters: [PhysicalFingerprint: FingerprintEntry]
    }

    struct BeaconKey: Hashable, Sendable {
        let truncID: UInt16
        let mediumID: String
    }

    struct FingerprintEntry: Sendable {
        /// Per-truncID last-seen timestamps for individual pruning.
        var truncIDs: [UInt16: ContinuousClock.Instant]
    }

    /// Creates a new beacon filter.
    ///
    /// - Parameters:
    ///   - sybilThreshold: Maximum number of distinct truncIDs allowed from a single
    ///     physical fingerprint before beacons are rejected. Default is 5.
    ///   - sybilWindow: Duration of the sliding window for Sybil detection.
    ///     Fingerprint entries older than this are pruned. Default is 30 minutes.
    public init(sybilThreshold: Int = 5, sybilWindow: Duration = .seconds(1800)) {
        self.sybilThreshold = sybilThreshold
        self.sybilWindow = sybilWindow
        self.state = Mutex(FilterState(
            recentBeacons: [:],
            fingerprintClusters: [:]
        ))
    }

    /// Evaluates whether a beacon should be accepted through the three-stage filter.
    ///
    /// - Parameters:
    ///   - discovery: The raw discovery event from the transport medium.
    ///   - beacon: The decoded beacon data.
    ///   - minInterval: Minimum interval between accepted beacons from the same
    ///     (truncID, mediumID) pair for rate limiting.
    /// - Returns: `true` if the beacon passes all three stages.
    public func accept(
        _ discovery: RawDiscovery,
        beacon: DecodedBeacon,
        minInterval: Duration
    ) -> Bool {
        // Stage 1: PoW verification
        guard beacon.powValid else {
            return false
        }

        // Stage 2: Rate limiting by (truncID, mediumID)
        guard let truncID = beacon.truncID else {
            // Tier 3 beacons without truncID bypass rate limiting by truncID
            return acceptSybilCheck(discovery: discovery, truncID: nil)
        }

        let key = BeaconKey(truncID: truncID, mediumID: discovery.mediumID)
        let now = discovery.timestamp

        let rateLimitPassed = state.withLock { s -> Bool in
            if let lastSeen = s.recentBeacons[key] {
                let elapsed = now - lastSeen
                if elapsed < minInterval {
                    return false
                }
            }
            s.recentBeacons[key] = now
            return true
        }

        guard rateLimitPassed else {
            return false
        }

        // Stage 3: Sybil detection
        return acceptSybilCheck(discovery: discovery, truncID: truncID)
    }

    /// Performs the Sybil detection check (Stage 3).
    ///
    /// - Parameters:
    ///   - discovery: The raw discovery event.
    ///   - truncID: The truncated ID, if available.
    /// - Returns: `true` if the beacon passes the Sybil check.
    private func acceptSybilCheck(discovery: RawDiscovery, truncID: UInt16?) -> Bool {
        guard let fingerprint = discovery.physicalFingerprint,
              let truncID else {
            // No fingerprint or no truncID means we cannot perform Sybil detection;
            // allow the beacon through.
            return true
        }

        let now = discovery.timestamp

        return state.withLock { s -> Bool in
            if var entry = s.fingerprintClusters[fingerprint] {
                // Prune individual truncIDs whose last activity is outside the window
                entry.truncIDs = entry.truncIDs.filter { _, lastSeen in
                    now - lastSeen <= sybilWindow
                }

                // Update/insert the current truncID
                entry.truncIDs[truncID] = now
                s.fingerprintClusters[fingerprint] = entry

                if entry.truncIDs.count > sybilThreshold {
                    return false
                }
                return true
            } else {
                // First sighting of this fingerprint
                s.fingerprintClusters[fingerprint] = FingerprintEntry(
                    truncIDs: [truncID: now]
                )
                return true
            }
        }
    }

    /// Removes expired fingerprint entries outside the Sybil detection window.
    ///
    /// Call this periodically to prevent unbounded memory growth in the
    /// fingerprint cluster map and the recent beacons map.
    public func pruneExpired() {
        let now = ContinuousClock.now
        state.withLock { s in
            // Prune individual truncIDs within each fingerprint cluster
            for (fingerprint, var entry) in s.fingerprintClusters {
                entry.truncIDs = entry.truncIDs.filter { _, lastSeen in
                    now - lastSeen <= sybilWindow
                }
                if entry.truncIDs.isEmpty {
                    s.fingerprintClusters.removeValue(forKey: fingerprint)
                } else {
                    s.fingerprintClusters[fingerprint] = entry
                }
            }
            // Prune recent beacons older than the sybil window (generous upper bound)
            s.recentBeacons = s.recentBeacons.filter { _, timestamp in
                now - timestamp <= sybilWindow
            }
        }
    }
}
