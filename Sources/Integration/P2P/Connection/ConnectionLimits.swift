/// ConnectionLimits - Connection pool limits configuration
///
/// Defines watermarks and limits for connection pool management.

import Foundation

/// Configuration for connection pool limits.
///
/// Uses a high/low watermark system for connection trimming:
/// - When connection count exceeds `highWatermark`, trimming begins
/// - Trimming continues until count drops to `lowWatermark`
///
/// ## Example
/// ```swift
/// let limits = ConnectionLimits(
///     highWatermark: 100,
///     lowWatermark: 80,
///     maxConnectionsPerPeer: 2
/// )
/// ```
public struct ConnectionLimits: Sendable {

    /// High watermark - trimming starts when exceeded.
    public var highWatermark: Int

    /// Low watermark - trimming target.
    public var lowWatermark: Int

    /// Maximum connections allowed per peer.
    public var maxConnectionsPerPeer: Int

    /// Maximum inbound connections allowed.
    ///
    /// When set, new inbound connections are rejected if limit is reached.
    public var maxInbound: Int?

    /// Maximum outbound connections allowed.
    ///
    /// When set, new outbound connections fail if limit is reached.
    public var maxOutbound: Int?

    /// Grace period for new connections.
    ///
    /// Connections within this period are protected from trimming,
    /// allowing them time to establish and become useful.
    public var gracePeriod: Duration

    /// Default limits suitable for production use.
    ///
    /// - highWatermark: 100
    /// - lowWatermark: 80
    /// - maxConnectionsPerPeer: 2
    /// - gracePeriod: 30 seconds
    public static let `default` = ConnectionLimits(
        highWatermark: 100,
        lowWatermark: 80,
        maxConnectionsPerPeer: 2,
        maxInbound: nil,
        maxOutbound: nil,
        gracePeriod: .seconds(30)
    )

    /// Relaxed limits for development and testing.
    ///
    /// - highWatermark: 50
    /// - lowWatermark: 40
    /// - maxConnectionsPerPeer: 3
    /// - gracePeriod: 10 seconds
    public static let development = ConnectionLimits(
        highWatermark: 50,
        lowWatermark: 40,
        maxConnectionsPerPeer: 3,
        maxInbound: nil,
        maxOutbound: nil,
        gracePeriod: .seconds(10)
    )

    /// Very strict limits for resource-constrained environments.
    ///
    /// - highWatermark: 20
    /// - lowWatermark: 15
    /// - maxConnectionsPerPeer: 1
    /// - gracePeriod: 5 seconds
    public static let strict = ConnectionLimits(
        highWatermark: 20,
        lowWatermark: 15,
        maxConnectionsPerPeer: 1,
        maxInbound: 10,
        maxOutbound: 10,
        gracePeriod: .seconds(5)
    )

    /// No limits - allows unlimited connections.
    ///
    /// Use with caution. Useful for testing.
    public static let unlimited = ConnectionLimits(
        highWatermark: Int.max,
        lowWatermark: Int.max - 1,
        maxConnectionsPerPeer: Int.max,
        maxInbound: nil,
        maxOutbound: nil,
        gracePeriod: .zero
    )

    /// Creates a new connection limits configuration.
    ///
    /// - Parameters:
    ///   - highWatermark: Trimming trigger threshold
    ///   - lowWatermark: Trimming target (must be <= highWatermark)
    ///   - maxConnectionsPerPeer: Max connections per peer
    ///   - maxInbound: Optional max inbound connections
    ///   - maxOutbound: Optional max outbound connections
    ///   - gracePeriod: Protection period for new connections
    public init(
        highWatermark: Int = 100,
        lowWatermark: Int = 80,
        maxConnectionsPerPeer: Int = 2,
        maxInbound: Int? = nil,
        maxOutbound: Int? = nil,
        gracePeriod: Duration = .seconds(30)
    ) {
        precondition(lowWatermark <= highWatermark,
                     "lowWatermark (\(lowWatermark)) must be <= highWatermark (\(highWatermark))")
        precondition(highWatermark > 0, "highWatermark must be positive")
        precondition(lowWatermark >= 0, "lowWatermark must be non-negative")
        precondition(maxConnectionsPerPeer > 0, "maxConnectionsPerPeer must be positive")

        self.highWatermark = highWatermark
        self.lowWatermark = lowWatermark
        self.maxConnectionsPerPeer = maxConnectionsPerPeer
        self.maxInbound = maxInbound
        self.maxOutbound = maxOutbound
        self.gracePeriod = gracePeriod
    }
}

// MARK: - Equatable

extension ConnectionLimits: Equatable {}
