/// Timeout configuration for traversal operations.
public struct TraversalTimeouts: Sendable {
    /// Per-candidate attempt timeout.
    public var attemptTimeout: Duration

    /// Total timeout for a connect operation.
    public var overallTimeout: Duration

    public init(
        attemptTimeout: Duration = .seconds(10),
        overallTimeout: Duration = .seconds(30)
    ) {
        self.attemptTimeout = attemptTimeout
        self.overallTimeout = overallTimeout
    }
}

/// Configuration for traversal orchestration.
public struct TraversalConfiguration: Sendable {
    public var mechanisms: [any TraversalMechanism]
    public var hintProviders: [any TraversalHintProvider]
    public var policy: any TraversalPolicy
    public var timeouts: TraversalTimeouts
    public var eventBufferSize: Int

    public init(
        mechanisms: [any TraversalMechanism] = [],
        hintProviders: [any TraversalHintProvider] = [],
        policy: any TraversalPolicy = DefaultTraversalPolicy(),
        timeouts: TraversalTimeouts = .init(),
        eventBufferSize: Int = 64
    ) {
        self.mechanisms = mechanisms
        self.hintProviders = hintProviders
        self.policy = policy
        self.timeouts = timeouts
        self.eventBufferSize = eventBufferSize
    }
}
