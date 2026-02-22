/// RelaySelectorConfiguration - Scoring parameters for DefaultRelaySelector.

import Foundation

/// Configuration for `DefaultRelaySelector` scoring.
public struct RelaySelectorConfiguration: Sendable {
    /// Weight for RTT score in the composite (0.0...1.0).
    public var rttWeight: Double

    /// Weight for failure score in the composite (0.0...1.0).
    public var failureWeight: Double

    /// RTT at or below this value scores 1.0.
    public var idealRTT: Duration

    /// RTT at or above this value scores 0.0.
    public var worstRTT: Duration

    /// Failure count at or above this value scores 0.0.
    public var maxFailuresBeforeZero: Int

    public init(
        rttWeight: Double = 0.6,
        failureWeight: Double = 0.4,
        idealRTT: Duration = .milliseconds(50),
        worstRTT: Duration = .seconds(2),
        maxFailuresBeforeZero: Int = 5
    ) {
        self.rttWeight = rttWeight
        self.failureWeight = failureWeight
        self.idealRTT = idealRTT
        self.worstRTT = worstRTT
        self.maxFailuresBeforeZero = maxFailuresBeforeZero
    }
}
