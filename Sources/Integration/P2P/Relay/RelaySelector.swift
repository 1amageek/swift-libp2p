/// RelaySelector - Protocol and default implementation for relay candidate selection.
///
/// Scores and ranks relay candidates based on RTT and failure history.

import Foundation
import P2PCore

// MARK: - Candidate Info

/// Metadata about a relay candidate, provided as input to the selector.
public struct RelayCandidateInfo: Sendable {
    /// The candidate's peer ID.
    public let peer: PeerID

    /// Known addresses for the candidate.
    public let addresses: [Multiaddr]

    /// Measured round-trip time (nil if unknown).
    public let rtt: Duration?

    /// Number of recent failures when reserving on this candidate.
    public let recentFailures: Int

    /// Whether the candidate supports relay protocol.
    public let supportsRelay: Bool

    public init(
        peer: PeerID,
        addresses: [Multiaddr],
        rtt: Duration?,
        recentFailures: Int,
        supportsRelay: Bool
    ) {
        self.peer = peer
        self.addresses = addresses
        self.rtt = rtt
        self.recentFailures = recentFailures
        self.supportsRelay = supportsRelay
    }
}

// MARK: - Candidate Score

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

    public static func < (lhs: RelayCandidateScore, rhs: RelayCandidateScore) -> Bool {
        lhs.score < rhs.score
    }
}

// MARK: - RelaySelector Protocol

/// Protocol for relay candidate selection strategies.
///
/// Conformers score and rank candidates. The default implementation
/// (`DefaultRelaySelector`) uses a weighted combination of RTT and failure
/// counts. Custom selectors can override this for geo-aware, load-aware,
/// or other selection strategies.
public protocol RelaySelector: Sendable {
    /// Scores and ranks candidates, best first.
    ///
    /// Candidates that don't support relay are filtered out.
    ///
    /// - Parameter candidates: Available relay candidates with metadata.
    /// - Returns: Scored candidates sorted by descending score (best first).
    func select(from candidates: [RelayCandidateInfo]) -> [RelayCandidateScore]
}

// MARK: - DefaultRelaySelector

/// Default relay selector that scores candidates based on RTT and failure history.
public final class DefaultRelaySelector: RelaySelector, Sendable {
    /// The scoring configuration.
    public let configuration: RelaySelectorConfiguration

    /// Creates a new default relay selector.
    ///
    /// - Parameter configuration: Scoring parameters.
    public init(configuration: RelaySelectorConfiguration = .init()) {
        self.configuration = configuration
    }

    public func select(from candidates: [RelayCandidateInfo]) -> [RelayCandidateScore] {
        let rttW = configuration.rttWeight
        let failW = configuration.failureWeight
        var result: [RelayCandidateScore] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates where candidate.supportsRelay {
            let rttScore = normalizeRTT(candidate.rtt)
            let failScore = normalizeFailures(candidate.recentFailures)
            result.append(RelayCandidateScore(
                peer: candidate.peer,
                score: rttW * rttScore + failW * failScore,
                rtt: candidate.rtt,
                recentFailures: candidate.recentFailures
            ))
        }
        result.sort(by: >)
        return result
    }

    // MARK: - Normalization

    /// Normalizes RTT to a 0.0...1.0 score (1.0 = ideal or better, 0.0 = worst or worse).
    ///
    /// Unknown RTT returns a neutral score (0.5).
    func normalizeRTT(_ rtt: Duration?) -> Double {
        guard let rtt else { return 0.5 }

        let rttSeconds = Double(rtt.components.seconds)
            + Double(rtt.components.attoseconds) / 1e18
        let idealSeconds = Double(configuration.idealRTT.components.seconds)
            + Double(configuration.idealRTT.components.attoseconds) / 1e18
        let worstSeconds = Double(configuration.worstRTT.components.seconds)
            + Double(configuration.worstRTT.components.attoseconds) / 1e18

        if rttSeconds <= idealSeconds { return 1.0 }
        if rttSeconds >= worstSeconds { return 0.0 }

        let range = worstSeconds - idealSeconds
        guard range > 0 else { return 1.0 }
        return 1.0 - (rttSeconds - idealSeconds) / range
    }

    /// Normalizes failure count to a 0.0...1.0 score (1.0 = no failures, 0.0 = max failures).
    func normalizeFailures(_ failures: Int) -> Double {
        if failures <= 0 { return 1.0 }
        if failures >= configuration.maxFailuresBeforeZero { return 0.0 }
        return 1.0 - Double(failures) / Double(configuration.maxFailuresBeforeZero)
    }
}
