import Foundation

/// Freshness decay function for a specific medium.
/// Defines how quickly an observation loses trustworthiness.
public struct FreshnessFunction: Sendable {
    /// Initial weight for this medium (0.0-1.0).
    public let initialWeight: Double

    /// Half-life: time after which trust decays to 50%.
    public let halfLife: Duration

    public init(initialWeight: Double, halfLife: Duration) {
        self.initialWeight = initialWeight
        self.halfLife = halfLife
    }

    /// Evaluates freshness given the observation age.
    public func evaluate(age: Duration) -> Double {
        let ageSeconds = Double(age.components.seconds)
            + Double(age.components.attoseconds) / 1e18
        let halfLifeSeconds = Double(halfLife.components.seconds)
            + Double(halfLife.components.attoseconds) / 1e18
        guard halfLifeSeconds > 0 else { return 0 }
        return initialWeight * pow(0.5, ageSeconds / halfLifeSeconds)
    }

    // MARK: - Preset Functions

    public static let nfc = FreshnessFunction(initialWeight: 1.0, halfLife: .seconds(30))
    public static let ble = FreshnessFunction(initialWeight: 0.8, halfLife: .seconds(60))
    public static let wifiDirect = FreshnessFunction(initialWeight: 0.7, halfLife: .seconds(120))
    public static let lora = FreshnessFunction(initialWeight: 0.5, halfLife: .seconds(300))
    public static let gossip = FreshnessFunction(initialWeight: 0.3, halfLife: .seconds(180))
    public static let storeCarryForward = FreshnessFunction(initialWeight: 0.2, halfLife: .seconds(600))
}
