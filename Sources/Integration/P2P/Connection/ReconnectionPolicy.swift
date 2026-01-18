/// ReconnectionPolicy - Automatic reconnection configuration
///
/// Defines how and when automatic reconnection should occur.

import Foundation

/// Configuration for automatic reconnection behavior.
///
/// ## Example
/// ```swift
/// let policy = ReconnectionPolicy(
///     enabled: true,
///     maxRetries: 10,
///     backoff: .default,
///     resetThreshold: .seconds(30)
/// )
/// ```
public struct ReconnectionPolicy: Sendable {

    /// Whether automatic reconnection is enabled.
    public var enabled: Bool

    /// Maximum number of retry attempts before giving up.
    ///
    /// After this many failed attempts, the connection state
    /// transitions to `.failed`.
    public var maxRetries: Int

    /// Backoff strategy for calculating delays between attempts.
    public var backoff: BackoffStrategy

    /// Duration after which successful connection resets retry count.
    ///
    /// If a connection remains connected for at least this duration,
    /// the retry count resets to 0. This prevents accumulating retries
    /// from transient disconnections.
    public var resetThreshold: Duration

    /// Disabled - no automatic reconnection.
    public static let disabled = ReconnectionPolicy(
        enabled: false,
        maxRetries: 0,
        backoff: .default,
        resetThreshold: .seconds(30)
    )

    /// Default reconnection policy.
    ///
    /// - enabled: true
    /// - maxRetries: 10
    /// - backoff: exponential (100ms base, 2x, 5min max)
    /// - resetThreshold: 30 seconds
    public static let `default` = ReconnectionPolicy(
        enabled: true,
        maxRetries: 10,
        backoff: .default,
        resetThreshold: .seconds(30)
    )

    /// Aggressive reconnection - more frequent retries.
    ///
    /// - enabled: true
    /// - maxRetries: 20
    /// - backoff: aggressive (50ms base, 1.5x, 30s max)
    /// - resetThreshold: 15 seconds
    public static let aggressive = ReconnectionPolicy(
        enabled: true,
        maxRetries: 20,
        backoff: .aggressive,
        resetThreshold: .seconds(15)
    )

    /// Persistent reconnection - keeps trying for a long time.
    ///
    /// - enabled: true
    /// - maxRetries: 100
    /// - backoff: exponential with longer max delay
    /// - resetThreshold: 60 seconds
    public static let persistent = ReconnectionPolicy(
        enabled: true,
        maxRetries: 100,
        backoff: BackoffStrategy(
            kind: .exponential(
                base: .milliseconds(200),
                multiplier: 2.0,
                max: .minutes(10)
            ),
            jitter: 0.15
        ),
        resetThreshold: .seconds(60)
    )

    /// Creates a new reconnection policy.
    ///
    /// - Parameters:
    ///   - enabled: Whether auto-reconnect is enabled
    ///   - maxRetries: Maximum retry attempts
    ///   - backoff: Delay calculation strategy
    ///   - resetThreshold: Duration for retry count reset
    public init(
        enabled: Bool = true,
        maxRetries: Int = 10,
        backoff: BackoffStrategy = .default,
        resetThreshold: Duration = .seconds(30)
    ) {
        precondition(maxRetries >= 0, "maxRetries must be non-negative")
        self.enabled = enabled
        self.maxRetries = maxRetries
        self.backoff = backoff
        self.resetThreshold = resetThreshold
    }

    /// Determines if reconnection should be attempted.
    ///
    /// - Parameters:
    ///   - attempt: Current retry attempt (0-based)
    ///   - reason: The disconnect reason
    /// - Returns: true if reconnection should be attempted
    public func shouldReconnect(attempt: Int, reason: DisconnectReason) -> Bool {
        guard enabled else { return false }
        guard attempt < maxRetries else { return false }

        // Don't reconnect for certain reasons
        switch reason {
        case .localClose:
            // User explicitly closed - don't reconnect
            return false
        case .gated:
            // Gated connections shouldn't reconnect
            return false
        case .connectionLimitExceeded:
            // Limit-based disconnects shouldn't reconnect
            return false
        default:
            return true
        }
    }

    /// Calculates the delay before the next reconnection attempt.
    ///
    /// - Parameter attempt: Current retry attempt (0-based)
    /// - Returns: Duration to wait before reconnecting
    public func delay(for attempt: Int) -> Duration {
        backoff.delay(for: attempt)
    }
}

// MARK: - Equatable

extension ReconnectionPolicy: Equatable {
    public static func == (lhs: ReconnectionPolicy, rhs: ReconnectionPolicy) -> Bool {
        lhs.enabled == rhs.enabled &&
        lhs.maxRetries == rhs.maxRetries &&
        lhs.resetThreshold == rhs.resetThreshold
        // Note: BackoffStrategy is not Equatable, so we skip it
    }
}
