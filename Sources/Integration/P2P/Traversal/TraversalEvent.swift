import P2PCore

/// Events emitted by traversal orchestration.
public enum TraversalEvent: Sendable {
    case started(peer: PeerID, candidates: Int)
    case candidateCollected(TraversalCandidate)
    case attemptStarted(TraversalCandidate)
    case attemptFailed(TraversalCandidate, reason: String)
    case completed(TraversalAttemptResult)
    case timedOut(TraversalCandidate)
}
