import P2PCore

/// Non-IP local direct dialing mechanism.
public struct LocalDirectMechanism: TraversalMechanism, Sendable {
    public let id: String
    public let pathKind: TraversalPathKind

    public init(id: String = "local-direct") {
        self.id = id
        self.pathKind = .local
    }

    public func collectCandidates(context: TraversalContext) async -> [TraversalCandidate] {
        context.knownAddresses.compactMap { address in
            guard context.dialCapability.canDial(address, via: .local) else {
                return nil
            }
            return TraversalCandidate(
                mechanismID: id,
                peer: context.targetPeer,
                address: address,
                pathKind: .local,
                score: 1.0
            )
        }
    }

    public func attempt(
        candidate: TraversalCandidate,
        context: TraversalContext
    ) async throws -> TraversalAttemptResult {
        guard let address = candidate.address else {
            throw TraversalError.noCandidate
        }
        let peer = try await context.dialAddress(address)
        return TraversalAttemptResult(
            connectedPeer: peer,
            selectedAddress: address,
            mechanismID: id
        )
    }
}
