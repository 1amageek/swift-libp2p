/// PeerScorer - Peer score tracking for GossipSub protocol.
///
/// Tracks penalties for various peer behaviors and provides score-based
/// peer selection for mesh management.

import Foundation
import Synchronization
import P2PCore

/// Configuration for PeerScorer.
public struct PeerScorerConfig: Sendable {
    /// Penalty for sending invalid messages.
    public var invalidMessagePenalty: Double

    /// Penalty for sending duplicate messages (minor).
    public var duplicateMessagePenalty: Double

    /// Penalty for GRAFT during backoff period.
    public var graftBackoffPenalty: Double

    /// Penalty for broken promise (IHAVE but no message on IWANT).
    public var brokenPromisePenalty: Double

    /// Penalty for excessive IWANT requests.
    public var excessiveIWantPenalty: Double

    /// Penalty for topic mismatch (message sent to wrong topic).
    public var topicMismatchPenalty: Double

    /// Decay factor applied periodically to scores.
    /// Scores are multiplied by this factor each decay interval.
    /// Example: 0.9 means 10% decay per interval.
    public var decayFactor: Double

    /// Interval between score decays.
    public var decayInterval: Duration

    /// Threshold below which a peer is considered graylisted.
    /// Graylisted peers are excluded from mesh selection.
    public var graylistThreshold: Double

    /// Creates a new configuration with default values.
    public init(
        invalidMessagePenalty: Double = -100.0,
        duplicateMessagePenalty: Double = -1.0,
        graftBackoffPenalty: Double = -10.0,
        brokenPromisePenalty: Double = -50.0,
        excessiveIWantPenalty: Double = -10.0,
        topicMismatchPenalty: Double = -50.0,
        decayFactor: Double = 0.9,
        decayInterval: Duration = .seconds(60),
        graylistThreshold: Double = -1000.0
    ) {
        self.invalidMessagePenalty = invalidMessagePenalty
        self.duplicateMessagePenalty = duplicateMessagePenalty
        self.graftBackoffPenalty = graftBackoffPenalty
        self.brokenPromisePenalty = brokenPromisePenalty
        self.excessiveIWantPenalty = excessiveIWantPenalty
        self.topicMismatchPenalty = topicMismatchPenalty
        self.decayFactor = decayFactor
        self.decayInterval = decayInterval
        self.graylistThreshold = graylistThreshold
    }

    /// Default configuration.
    public static let `default` = PeerScorerConfig()
}

/// Tracks peer scores for GossipSub mesh management.
///
/// Scores are affected by:
/// - Invalid messages: Large penalty
/// - Duplicate messages: Small penalty
/// - Protocol violations (GRAFT during backoff): Medium penalty
/// - Broken promises (IHAVE without message): Medium penalty
///
/// Scores decay over time, allowing peers to recover from penalties.
/// Peers below the graylist threshold are excluded from mesh selection.
public final class PeerScorer: Sendable {

    // MARK: - Properties

    /// Configuration.
    public let config: PeerScorerConfig

    /// Per-peer score state.
    private let scores: Mutex<[PeerID: PeerScore]>

    private struct PeerScore: Sendable {
        var score: Double = 0.0
        var lastDecay: ContinuousClock.Instant = .now
    }

    // MARK: - Initialization

    /// Creates a new peer scorer.
    ///
    /// - Parameter config: Scoring configuration.
    public init(config: PeerScorerConfig = .default) {
        self.config = config
        self.scores = Mutex([:])
    }

    // MARK: - Penalty Recording

    /// Records an invalid message penalty for a peer.
    ///
    /// - Parameter peer: The peer that sent the invalid message.
    public func recordInvalidMessage(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.invalidMessagePenalty)
    }

    /// Records a duplicate message penalty for a peer.
    ///
    /// - Parameter peer: The peer that sent the duplicate.
    public func recordDuplicateMessage(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.duplicateMessagePenalty)
    }

    /// Records a GRAFT-during-backoff penalty for a peer.
    ///
    /// - Parameter peer: The peer that violated backoff.
    public func recordGraftDuringBackoff(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.graftBackoffPenalty)
    }

    /// Records a broken promise penalty (IHAVE without delivering message).
    ///
    /// - Parameter peer: The peer that broke the promise.
    public func recordBrokenPromise(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.brokenPromisePenalty)
    }

    /// Records an excessive IWANT penalty.
    ///
    /// - Parameter peer: The peer sending too many IWANTs.
    public func recordExcessiveIWant(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.excessiveIWantPenalty)
    }

    /// Records a topic mismatch penalty.
    ///
    /// - Parameter peer: The peer that sent a message to the wrong topic.
    public func recordTopicMismatch(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.topicMismatchPenalty)
    }

    /// Applies a custom penalty amount.
    ///
    /// - Parameters:
    ///   - peer: The peer to penalize.
    ///   - amount: The penalty amount (negative for penalties).
    public func applyPenalty(to peer: PeerID, amount: Double) {
        scores.withLock { scores in
            var peerScore = scores[peer] ?? PeerScore()
            peerScore.score += amount
            scores[peer] = peerScore
        }
    }

    // MARK: - Score Query

    /// Returns the current score for a peer.
    ///
    /// Applies decay if enough time has passed since the last decay.
    ///
    /// - Parameter peer: The peer ID.
    /// - Returns: The peer's current score (0 if no score recorded).
    public func score(for peer: PeerID) -> Double {
        scores.withLock { scores in
            applyDecayIfNeeded(for: peer, in: &scores)
            return scores[peer]?.score ?? 0.0
        }
    }

    /// Returns whether a peer is graylisted (score below threshold).
    ///
    /// Graylisted peers should be excluded from mesh selection.
    ///
    /// - Parameter peer: The peer ID.
    /// - Returns: `true` if the peer is graylisted.
    public func isGraylisted(_ peer: PeerID) -> Bool {
        score(for: peer) < config.graylistThreshold
    }

    /// Returns all peers with their current scores.
    ///
    /// - Returns: Dictionary of peer IDs to scores.
    public func allScores() -> [PeerID: Double] {
        scores.withLock { scores in
            var result: [PeerID: Double] = [:]
            for peer in scores.keys {
                applyDecayIfNeeded(for: peer, in: &scores)
                result[peer] = scores[peer]?.score ?? 0.0
            }
            return result
        }
    }

    // MARK: - Peer Selection

    /// Sorts peers by score (highest first).
    ///
    /// - Parameter peers: The peers to sort.
    /// - Returns: Peers sorted by descending score.
    public func sortByScore(_ peers: [PeerID]) -> [PeerID] {
        let peerScores = peers.map { (peer: $0, score: score(for: $0)) }
        return peerScores.sorted { $0.score > $1.score }.map(\.peer)
    }

    /// Filters out graylisted peers from a list.
    ///
    /// - Parameter peers: The peers to filter.
    /// - Returns: Non-graylisted peers.
    public func filterGraylisted(_ peers: [PeerID]) -> [PeerID] {
        peers.filter { !isGraylisted($0) }
    }

    /// Selects the best peers from a list, excluding graylisted peers.
    ///
    /// - Parameters:
    ///   - peers: The candidate peers.
    ///   - count: Maximum number of peers to select.
    /// - Returns: Up to `count` non-graylisted peers, sorted by score.
    public func selectBestPeers(from peers: [PeerID], count: Int) -> [PeerID] {
        let filtered = filterGraylisted(peers)
        let sorted = sortByScore(filtered)
        return Array(sorted.prefix(count))
    }

    // MARK: - Decay

    /// Applies decay to all peer scores.
    ///
    /// Called periodically (e.g., by heartbeat) to allow peers to recover.
    public func applyDecayToAll() {
        scores.withLock { scores in
            for peer in scores.keys {
                applyDecayIfNeeded(for: peer, in: &scores)
            }
        }
    }

    /// Applies decay to a specific peer's score if enough time has passed.
    private func applyDecayIfNeeded(for peer: PeerID, in scores: inout [PeerID: PeerScore]) {
        guard var peerScore = scores[peer] else { return }

        let now = ContinuousClock.now
        let elapsed = now - peerScore.lastDecay

        // Only apply decay if interval has passed
        if elapsed >= config.decayInterval {
            let decayPeriods = Int(elapsed / config.decayInterval)
            peerScore.score *= pow(config.decayFactor, Double(decayPeriods))
            peerScore.lastDecay = now

            // Remove scores that have decayed to near-zero to prevent memory leak
            if abs(peerScore.score) < 0.001 {
                scores.removeValue(forKey: peer)
            } else {
                scores[peer] = peerScore
            }
        }
    }

    // MARK: - Cleanup

    /// Removes score entry for a peer (e.g., when peer disconnects).
    ///
    /// - Parameter peer: The peer to remove.
    public func removePeer(_ peer: PeerID) {
        _ = scores.withLock { scores in
            scores.removeValue(forKey: peer)
        }
    }

    /// Clears all scores.
    public func clear() {
        scores.withLock { scores in
            scores.removeAll()
        }
    }
}
