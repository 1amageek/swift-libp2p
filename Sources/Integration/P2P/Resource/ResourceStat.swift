/// ResourceStat - Usage counters for a resource scope
///
/// Tracks the current number of connections, streams, and memory
/// usage within a scope (system or per-peer).

/// Usage counters for a resource scope.
///
/// All counters represent current active usage, not cumulative totals.
/// Values are always non-negative.
public struct ResourceStat: Sendable, Equatable {

    /// Number of active inbound connections.
    public var inboundConnections: Int

    /// Number of active outbound connections.
    public var outboundConnections: Int

    /// Number of active inbound streams.
    public var inboundStreams: Int

    /// Number of active outbound streams.
    public var outboundStreams: Int

    /// Current memory usage in bytes.
    public var memory: Int

    /// Total number of active connections (inbound + outbound).
    public var totalConnections: Int {
        inboundConnections + outboundConnections
    }

    /// Total number of active streams (inbound + outbound).
    public var totalStreams: Int {
        inboundStreams + outboundStreams
    }

    /// Whether all counters are zero.
    public var isZero: Bool {
        inboundConnections == 0
            && outboundConnections == 0
            && inboundStreams == 0
            && outboundStreams == 0
            && memory == 0
    }

    public init(
        inboundConnections: Int = 0,
        outboundConnections: Int = 0,
        inboundStreams: Int = 0,
        outboundStreams: Int = 0,
        memory: Int = 0
    ) {
        self.inboundConnections = inboundConnections
        self.outboundConnections = outboundConnections
        self.inboundStreams = inboundStreams
        self.outboundStreams = outboundStreams
        self.memory = memory
    }
}
