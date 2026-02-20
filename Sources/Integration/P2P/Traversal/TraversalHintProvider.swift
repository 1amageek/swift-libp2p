/// External provider for traversal candidates (e.g. mesh-level coordination).
public protocol TraversalHintProvider: Sendable {
    func hints(context: TraversalContext) async -> [TraversalCandidate]
}
