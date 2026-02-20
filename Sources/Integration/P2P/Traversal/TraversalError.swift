/// Errors produced by traversal orchestration.
public enum TraversalError: Error, Sendable {
    case noCandidate
    case mechanismUnavailable(String)
    case timeout(String)
    case missingContext(String)
    case allAttemptsFailed([TraversalAttemptFailure])
}

/// A single failed traversal attempt.
public struct TraversalAttemptFailure: Error, Sendable {
    public let mechanismID: String
    public let reason: String

    public init(mechanismID: String, reason: String) {
        self.mechanismID = mechanismID
        self.reason = reason
    }
}
