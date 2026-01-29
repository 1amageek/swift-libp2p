/// ResourceError - Errors from resource limit enforcement

/// Errors thrown when resource limits are exceeded.
public enum ResourceError: Error, Sendable, Equatable {
    /// A resource limit was exceeded.
    ///
    /// - Parameters:
    ///   - scope: The scope that exceeded its limit (e.g., "system", "peer:<id>")
    ///   - resource: The resource type (e.g., "inboundConnections", "memory")
    case limitExceeded(scope: String, resource: String)
}
