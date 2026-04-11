import Foundation

/// Configuration for the connection pool.
public struct PoolConfiguration: Sendable {
    /// Connection limits.
    public var limits: ConnectionLimits

    /// Reconnection policy.
    public var reconnectionPolicy: ReconnectionPolicy

    /// Idle timeout for connections.
    public var idleTimeout: Duration

    /// Optional connection gater.
    public var gater: (any ConnectionGater)?

    public init(
        limits: ConnectionLimits = .default,
        reconnectionPolicy: ReconnectionPolicy = .default,
        idleTimeout: Duration = .seconds(60),
        gater: (any ConnectionGater)? = nil
    ) {
        self.limits = limits
        self.reconnectionPolicy = reconnectionPolicy
        self.idleTimeout = idleTimeout
        self.gater = gater
    }
}
