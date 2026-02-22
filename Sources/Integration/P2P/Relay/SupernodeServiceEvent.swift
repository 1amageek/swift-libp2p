/// SupernodeServiceEvent - Events emitted by SupernodeService.

/// Events emitted by `SupernodeService`.
public enum SupernodeServiceEvent: Sendable {
    /// The relay server was activated (node is eligible to serve as relay).
    case relayActivated

    /// The relay server was deactivated (node is no longer eligible).
    case relayDeactivated(reason: String)

    /// Eligibility was evaluated.
    case eligibilityEvaluated(isEligible: Bool, reason: String)
}
