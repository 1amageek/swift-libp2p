/// ScopeLimits - Per-scope resource limits
///
/// Defines maximum allowed usage for connections, streams, and memory
/// within a single scope. Used for both system-wide and per-peer limits.
///
/// ## Out of scope: file descriptors
///
/// There is intentionally NO file-descriptor (FD) dimension here. FDs are not
/// tracked by this layer: sockets are owned by the transport (SwiftNIO) and
/// streams are multiplexed over a single transport connection, so there is no
/// 1:1 stream-to-FD relationship to account for. Connection limits
/// (`max*Connections`) are the meaningful proxy for socket pressure. If a future
/// transport needs explicit FD accounting it must add a dedicated dimension here
/// and wire reserve/release at the socket layer — it is deliberately omitted
/// rather than silently approximated.

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
    ///
    /// Memory (`maxMemory`) is intentionally `nil`: the runtime does not yet
    /// reserve memory on the buffer paths, so advertising a memory limit would
    /// be false protection. It is only set when a caller wires
    /// `reserveMemory`/`reserveServiceMemory` into their own buffers.
    public static let defaultSystem = ScopeLimits(
        maxInboundConnections: 128,
        maxOutboundConnections: 128,
        maxTotalConnections: 256,
        maxInboundStreams: 4096,
        maxOutboundStreams: 4096,
        maxTotalStreams: 8192,
        maxMemory: nil
    )

    /// Default per-peer limits.
    ///
    /// See `defaultSystem` for why `maxMemory` is `nil`.
    public static let defaultPeer = ScopeLimits(
        maxInboundConnections: 2,
        maxOutboundConnections: 2,
        maxTotalConnections: 4,
        maxInboundStreams: 256,
        maxOutboundStreams: 256,
        maxTotalStreams: 512,
        maxMemory: nil
    )

    /// Default per-protocol limits.
    ///
    /// See `defaultSystem` for why `maxMemory` is `nil`.
    public static let defaultProtocol = ScopeLimits(
        maxInboundStreams: 2048,
        maxOutboundStreams: 2048,
        maxTotalStreams: 4096,
        maxMemory: nil
    )

    /// Default per-service limits.
    ///
    /// See `defaultSystem` for why `maxMemory` is `nil`. With no enforced
    /// dimension this is currently equivalent to `.unlimited`, but it is kept
    /// as a distinct constant so a future memory wiring has a place to land.
    public static let defaultService = ScopeLimits(
        maxMemory: nil
    )

    /// No limits (unlimited).
    public static let unlimited = ScopeLimits()
}
