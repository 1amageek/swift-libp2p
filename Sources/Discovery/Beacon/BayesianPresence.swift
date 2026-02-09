import Foundation

/// Bayesian (Noisy-OR) presence estimation from multiple independent observations.
///
/// Each observation contributes an independent probability of the peer being present.
/// The combined score uses the Noisy-OR formula:
///   P(present) = 1 - Product(1 - freshness_i)
public struct BayesianPresence: Sendable {

    /// Computes the probability of a peer being present given multiple observations.
    ///
    /// Uses the Noisy-OR model where each observation is treated as an independent
    /// evidence channel. The freshness of each observation decays over time according
    /// to its medium-specific freshness function.
    ///
    /// - Parameter observations: The set of observations to combine.
    /// - Returns: A probability score in [0.0, 1.0].
    public static func presenceScore(observations: [BeaconObservation]) -> Double {
        guard !observations.isEmpty else { return 0 }
        var absentProbability = 1.0
        for obs in observations {
            let freshness = obs.freshnessFunction.evaluate(age: obs.age)
            absentProbability *= (1.0 - freshness)
        }
        return 1.0 - absentProbability
    }
}
