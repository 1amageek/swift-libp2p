import P2PAutoNAT
import P2PCore
import P2PDCUtR

/// Hole punching mechanism based on DCUtR.
public struct HolePunchMechanism: TraversalMechanism, Sendable {
    public let id: String
    public let pathKind: TraversalPathKind
    public let dcutr: DCUtRService
    public let autoNAT: AutoNATService?
    public let requireLimitedConnection: Bool

    public init(
        dcutr: DCUtRService,
        autoNAT: AutoNATService? = nil,
        requireLimitedConnection: Bool = true,
        id: String = "hole-punch"
    ) {
        self.id = id
        self.pathKind = .holePunch
        self.dcutr = dcutr
        self.autoNAT = autoNAT
        self.requireLimitedConnection = requireLimitedConnection
    }

    public func prepare(context: TraversalContext) async {
        dcutr.setDialer { address in
            _ = try await context.dialAddress(address)
        }
        dcutr.setLocalAddressProvider(context.getLocalAddresses)
    }

    public func collectCandidates(context: TraversalContext) async -> [TraversalCandidate] {
        guard context.opener != nil else { return [] }
        if requireLimitedConnection && !context.isLimitedConnection(context.targetPeer) {
            return []
        }
        if let autoNAT {
            if case .publicReachable = autoNAT.status {
                return []
            }
        }

        return [
            TraversalCandidate(
                mechanismID: id,
                peer: context.targetPeer,
                address: nil,
                pathKind: .holePunch,
                score: 0.5
            )
        ]
    }

    public func attempt(
        candidate _: TraversalCandidate,
        context: TraversalContext
    ) async throws -> TraversalAttemptResult {
        guard let opener = context.opener else {
            throw TraversalError.missingContext("StreamOpener required for hole punch")
        }

        try await dcutr.upgradeToDirectConnection(
            with: context.targetPeer,
            using: opener,
            dialer: { address in
                _ = try await context.dialAddress(address)
            }
        )

        return TraversalAttemptResult(
            connectedPeer: context.targetPeer,
            selectedAddress: nil,
            mechanismID: id
        )
    }

    public func shutdown() async {
        await dcutr.shutdown()
    }
}
