import P2PCore

/// A strategy that attempts to establish connectivity using a specific path type.
public protocol TraversalMechanism: Sendable {
    /// Stable mechanism identifier.
    var id: String { get }

    /// Path category used for policy ordering.
    var pathKind: TraversalPathKind { get }

    /// Called when the traversal coordinator starts.
    func prepare(context: TraversalContext) async

    /// Produces candidates for the target peer.
    func collectCandidates(context: TraversalContext) async -> [TraversalCandidate]

    /// Attempts connectivity using the given candidate.
    func attempt(
        candidate: TraversalCandidate,
        context: TraversalContext
    ) async throws -> TraversalAttemptResult

    /// Releases resources held by this mechanism.
    func shutdown()
}

public extension TraversalMechanism {
    func prepare(context: TraversalContext) async {}

    func shutdown() {}
}
