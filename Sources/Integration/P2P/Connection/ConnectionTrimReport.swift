/// ConnectionTrimReport - Snapshot of trim decision inputs and outputs
///
/// Exposes how connection trimming would behave for the current pool state.

import Foundation
import P2PCore

/// A point-in-time report for connection trimming decisions.
///
/// This report is intended for debugging and monitoring:
/// - Whether trimming is currently required
/// - How many connections need to be trimmed
/// - Which connections are selected and why
public struct ConnectionTrimReport: Sendable {

    /// Why a connection is excluded from trimming candidates.
    public enum ExclusionReason: String, Sendable {
        /// Entry is not in `.connected` state.
        case notConnected

        /// Connection is explicitly protected.
        case protected

        /// Connection is still within grace period.
        case withinGracePeriod

        /// Connected entry has no `connectedAt` timestamp.
        case missingConnectedAt
    }

    /// Per-connection trim evaluation.
    public struct Candidate: Sendable {
        /// Connection identifier.
        public let id: ConnectionID

        /// Remote peer identifier.
        public let peer: PeerID

        /// Direction of the connection.
        public let direction: ConnectionDirection

        /// Current state of the connection entry.
        public let state: ConnectionState

        /// Number of tags on this connection.
        public let tagCount: Int

        /// Whether the connection is currently protected.
        public let isProtected: Bool

        /// Idle duration since last activity.
        public let idleDuration: Duration

        /// Connection age if connected-at timestamp exists.
        public let connectedDuration: Duration?

        /// Candidate rank among trimmable entries (1 = highest trim priority).
        ///
        /// `nil` means the entry is excluded from trimmable candidates.
        public let trimRank: Int?

        /// Exclusion reason when not trimmable.
        ///
        /// `nil` means this entry is trimmable.
        public let exclusionReason: ExclusionReason?

        /// Whether this connection is selected in the current trim plan.
        public let selectedForTrim: Bool
    }

    /// Number of active (`.connected`) connections.
    public let activeConnectionCount: Int

    /// Number of tracked entries across all states.
    public let totalEntryCount: Int

    /// Configured high watermark.
    public let highWatermark: Int

    /// Configured low watermark.
    public let lowWatermark: Int

    /// Number of connections requested to trim toward low watermark.
    ///
    /// Zero when trimming is not required.
    public let targetTrimCount: Int

    /// Number of currently trimmable candidates.
    public let trimmableCount: Int

    /// Number of connections selected in the plan.
    ///
    /// This can be lower than `targetTrimCount` when there are
    /// insufficient trimmable candidates.
    public let selectedCount: Int

    /// Per-entry trim evaluation for monitoring/diagnostics.
    public let candidates: [Candidate]

    /// Whether current state requires trimming.
    public var requiresTrim: Bool {
        targetTrimCount > 0
    }
}
