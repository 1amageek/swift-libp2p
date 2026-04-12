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

    /// Development-oriented defaults with looser limits and no auto-reconnect.
    public static let development = PoolConfiguration(
        limits: .development,
        reconnectionPolicy: .disabled,
        idleTimeout: .seconds(300)
    )

    /// Production-oriented defaults.
    public static let production = PoolConfiguration(
        limits: .default,
        reconnectionPolicy: .default,
        idleTimeout: .seconds(60)
    )
}

extension PoolConfiguration: Equatable {
    public static func == (lhs: PoolConfiguration, rhs: PoolConfiguration) -> Bool {
        lhs.limits == rhs.limits &&
        lhs.reconnectionPolicy == rhs.reconnectionPolicy &&
        lhs.idleTimeout == rhs.idleTimeout
    }
}
