/// BackoffStrategy - Reconnection delay calculation
///
/// Provides configurable backoff strategies for connection retry logic.

import Foundation

/// A strategy for calculating retry delays.
///
/// Used by `ReconnectionPolicy` to determine how long to wait between
/// reconnection attempts.
///
/// ## Example
/// ```swift
/// let backoff = BackoffStrategy.default
/// let delay0 = backoff.delay(for: 0)  // ~100ms
/// let delay1 = backoff.delay(for: 1)  // ~200ms
/// let delay2 = backoff.delay(for: 2)  // ~400ms
/// ```
///
/// - Note: Duration calculations involve Double conversion, which may
///   introduce minor precision loss. This is acceptable for retry timing
///   purposes where millisecond precision is sufficient.
public struct BackoffStrategy: Sendable {

    /// The kind of backoff calculation.
    public enum Kind: Sendable {
        /// Exponential backoff: base * multiplier^attempt
        ///
        /// - Parameters:
        ///   - base: Initial delay
        ///   - multiplier: Growth factor per attempt
        ///   - max: Maximum delay cap
        case exponential(base: Duration, multiplier: Double, max: Duration)

        /// Constant delay between attempts.
        case constant(Duration)

        /// Linear backoff: base + (increment * attempt)
        ///
        /// - Parameters:
        ///   - base: Initial delay
        ///   - increment: Additional delay per attempt
        ///   - max: Maximum delay cap
        case linear(base: Duration, increment: Duration, max: Duration)
    }

    /// The backoff calculation kind.
    public let kind: Kind

    /// Jitter factor (0.0 to 1.0).
    ///
    /// Adds random variation to prevent thundering herd problems.
    /// A value of 0.1 means ±10% variation.
    public let jitter: Double

    /// Default backoff strategy.
    ///
    /// Exponential backoff starting at 100ms, doubling each attempt,
    /// capped at 5 minutes, with 10% jitter.
    public static let `default` = BackoffStrategy(
        kind: .exponential(
            base: .milliseconds(100),
            multiplier: 2.0,
            max: .minutes(5)
        ),
        jitter: 0.1
    )

    /// Aggressive backoff strategy.
    ///
    /// Shorter delays for more frequent retry attempts.
    /// Exponential backoff starting at 50ms, growing by 1.5x,
    /// capped at 30 seconds, with 20% jitter.
    public static let aggressive = BackoffStrategy(
        kind: .exponential(
            base: .milliseconds(50),
            multiplier: 1.5,
            max: .seconds(30)
        ),
        jitter: 0.2
    )

    /// No delay between retries.
    ///
    /// Useful for testing. Not recommended for production.
    public static let none = BackoffStrategy(
        kind: .constant(.zero),
        jitter: 0
    )

    /// Creates a new backoff strategy.
    ///
    /// - Parameters:
    ///   - kind: The backoff calculation kind
    ///   - jitter: Jitter factor (0.0 to 1.0)
    public init(kind: Kind, jitter: Double = 0.1) {
        precondition(jitter >= 0 && jitter <= 1, "jitter must be in range 0.0...1.0")
        self.kind = kind
        self.jitter = jitter
    }

    /// Calculates the delay for a given attempt number.
    ///
    /// - Parameter attempt: The attempt number (0-based)
    /// - Returns: The duration to wait before the next attempt
    public func delay(for attempt: Int) -> Duration {
        let baseDelay: Duration

        switch kind {
        case .exponential(let base, let multiplier, let max):
            let factor = pow(multiplier, Double(attempt))
            let calculated = base.scaled(by: factor)
            baseDelay = Swift.min(calculated, max)

        case .constant(let duration):
            baseDelay = duration

        case .linear(let base, let increment, let max):
            let calculated = base + increment.scaled(by: Double(attempt))
            baseDelay = Swift.min(calculated, max)
        }

        // Apply jitter
        guard jitter > 0, baseDelay > .zero else { return baseDelay }

        let seconds = baseDelay.asSeconds
        let jitterRange = seconds * jitter
        let randomJitter = Double.random(in: -jitterRange...jitterRange)
        let result = seconds + randomJitter

        // Ensure non-negative
        return .seconds(Swift.max(0, result))
    }
}

// MARK: - Duration Extensions

extension Duration {
    /// Converts to seconds as a Double.
    ///
    /// - Note: Minor precision loss may occur for very precise durations.
    var asSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Scales the duration by a factor.
    ///
    /// - Parameter factor: The scaling factor
    /// - Returns: A new duration scaled by the factor
    func scaled(by factor: Double) -> Duration {
        .seconds(asSeconds * factor)
    }

    /// Creates a duration for the given number of minutes.
    ///
    /// - Parameter minutes: Number of minutes
    /// - Returns: A duration representing the given minutes
    static func minutes(_ minutes: Int) -> Duration {
        .seconds(minutes * 60)
    }
}
