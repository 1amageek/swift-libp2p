/// ScopeLimits - Per-scope resource limits
///
/// Defines maximum allowed usage for connections, streams, and memory
/// within a single scope. Used for both system-wide and per-peer limits.

/// Maximum allowed resource usage for a scope.
///
/// A `nil` value means no limit for that resource.
public struct ScopeLimits: Sendable, Equatable {

    /// Maximum inbound connections.
    public var maxInboundConnections: Int?

    /// Maximum outbound connections.
    public var maxOutboundConnections: Int?

    /// Maximum total connections (inbound + outbound).
    public var maxTotalConnections: Int?

    /// Maximum inbound streams.
    public var maxInboundStreams: Int?

    /// Maximum outbound streams.
    public var maxOutboundStreams: Int?

    /// Maximum total streams (inbound + outbound).
    public var maxTotalStreams: Int?

    /// Maximum memory in bytes.
    public var maxMemory: Int?

    public init(
        maxInboundConnections: Int? = nil,
        maxOutboundConnections: Int? = nil,
        maxTotalConnections: Int? = nil,
        maxInboundStreams: Int? = nil,
        maxOutboundStreams: Int? = nil,
        maxTotalStreams: Int? = nil,
        maxMemory: Int? = nil
    ) {
        self.maxInboundConnections = maxInboundConnections
        self.maxOutboundConnections = maxOutboundConnections
        self.maxTotalConnections = maxTotalConnections
        self.maxInboundStreams = maxInboundStreams
        self.maxOutboundStreams = maxOutboundStreams
        self.maxTotalStreams = maxTotalStreams
        self.maxMemory = maxMemory
    }

    /// Default system-wide limits.
    public static let defaultSystem = ScopeLimits(
        maxInboundConnections: 128,
        maxOutboundConnections: 128,
        maxTotalConnections: 256,
        maxInboundStreams: 4096,
        maxOutboundStreams: 4096,
        maxTotalStreams: 8192,
        maxMemory: 128 * 1024 * 1024  // 128 MB
    )

    /// Default per-peer limits.
    public static let defaultPeer = ScopeLimits(
        maxInboundConnections: 2,
        maxOutboundConnections: 2,
        maxTotalConnections: 4,
        maxInboundStreams: 256,
        maxOutboundStreams: 256,
        maxTotalStreams: 512,
        maxMemory: 16 * 1024 * 1024  // 16 MB
    )

    /// No limits (unlimited).
    public static let unlimited = ScopeLimits()
}
