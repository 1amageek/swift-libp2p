import P2PCore

/// Default policy ordering candidates by path preference then score.
public struct DefaultTraversalPolicy: TraversalPolicy, Sendable {
    public init() {}

    public func order(
        candidates: [TraversalCandidate],
        context _: TraversalContext
    ) -> [TraversalCandidate] {
        candidates.sorted { lhs, rhs in
            let leftPriority = priority(of: lhs.pathKind)
            let rightPriority = priority(of: rhs.pathKind)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            switch (lhs.address, rhs.address) {
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.mechanismID < rhs.mechanismID
            }
        }
    }

    public func shouldFallback(
        after error: any Error,
        from _: TraversalCandidate,
        context _: TraversalContext
    ) -> Bool {
        if let nodeError = error as? NodeError,
           case .connectionLimitReached = nodeError {
            return false
        }
        return true
    }

    private func priority(of kind: TraversalPathKind) -> Int {
        switch kind {
        case .local: return 0
        case .ip: return 1
        case .holePunch: return 2
        case .relay: return 3
        case .unknown: return 4
        }
    }
}
