/// RelaySelectorConfiguration - Scoring parameters for DefaultRelaySelector.

import Foundation

/// Configuration for `DefaultRelaySelector` scoring.
public struct RelaySelectorConfiguration: Sendable {
    /// Weight for RTT score in the composite (0.0...1.0).
    public let rttWeight: Double

    /// Weight for failure score in the composite (0.0...1.0).
    public let failureWeight: Double

    /// RTT at or below this value scores 1.0.
    public let idealRTT: Duration

    /// RTT at or above this value scores 0.0.
    public let worstRTT: Duration

    /// Failure count at or above this value scores 0.0.
    public let maxFailuresBeforeZero: Int

    public init(
        rttWeight: Double = 0.6,
        failureWeight: Double = 0.4,
        idealRTT: Duration = .milliseconds(50),
        worstRTT: Duration = .seconds(2),
        maxFailuresBeforeZero: Int = 5
    ) {
        precondition(rttWeight >= 0 && failureWeight >= 0, "Weights must be non-negative")
        precondition(abs((rttWeight + failureWeight) - 1.0) < 0.001, "Weights must sum to 1.0")
        precondition(idealRTT <= worstRTT, "idealRTT must be <= worstRTT")
        precondition(maxFailuresBeforeZero > 0, "maxFailuresBeforeZero must be positive")
        self.rttWeight = rttWeight
        self.failureWeight = failureWeight
        self.idealRTT = idealRTT
        self.worstRTT = worstRTT
        self.maxFailuresBeforeZero = maxFailuresBeforeZero
    }
}
