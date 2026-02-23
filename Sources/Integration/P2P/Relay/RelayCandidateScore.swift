/// RelayCandidateScore - Scoring result for a relay candidate.

import Foundation
import P2PCore

/// Scoring result for a relay candidate.
public struct RelayCandidateScore: Sendable, Comparable {
    /// The candidate's peer ID.
    public let peer: PeerID

    /// Composite score (0.0 ... 1.0, higher = better).
    public let score: Double

    /// Measured round-trip time (nil if unknown).
    public let rtt: Duration?

    /// Number of recent failures.
    public let recentFailures: Int

    public init(
        peer: PeerID,
        score: Double,
        rtt: Duration?,
        recentFailures: Int
    ) {
        self.peer = peer
        self.score = score
        self.rtt = rtt
        self.recentFailures = recentFailures
    }

    public static func == (lhs: RelayCandidateScore, rhs: RelayCandidateScore) -> Bool {
        lhs.score == rhs.score
    }

    public static func < (lhs: RelayCandidateScore, rhs: RelayCandidateScore) -> Bool {
        lhs.score < rhs.score
    }
}
