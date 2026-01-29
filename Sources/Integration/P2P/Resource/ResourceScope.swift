/// ResourceScope - Read-only view of a resource scope's usage and limits

/// A read-only view of resource usage and limits for a scope.
///
/// Scopes are hierarchical: System scope encompasses all peers,
/// and each peer has its own scope.
public protocol ResourceScope: Sendable {

    /// The name of this scope (e.g., "system", "peer:<id>").
    var name: String { get }

    /// Current resource usage for this scope.
    var stat: ResourceStat { get }

    /// Resource limits for this scope.
    var limits: ScopeLimits { get }
}
