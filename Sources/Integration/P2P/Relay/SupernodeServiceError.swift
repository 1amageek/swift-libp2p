/// SupernodeServiceError - Errors from SupernodeService.

/// Errors from `SupernodeService`.
public enum SupernodeServiceError: Error, Sendable {
    /// Node is not eligible to serve as a relay.
    case notEligible(String)

    /// The service has been shut down.
    case serviceShutDown
}
