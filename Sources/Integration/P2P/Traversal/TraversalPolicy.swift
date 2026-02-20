/// Policy that controls candidate ordering and fallback behavior.
public protocol TraversalPolicy: Sendable {
    func order(
        candidates: [TraversalCandidate],
        context: TraversalContext
    ) -> [TraversalCandidate]

    func shouldFallback(
        after error: any Error,
        from candidate: TraversalCandidate,
        context: TraversalContext
    ) -> Bool
}
