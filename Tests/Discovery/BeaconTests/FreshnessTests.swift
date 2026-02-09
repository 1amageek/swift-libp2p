import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("FreshnessFunction")
struct FreshnessTests {

    @Test("evaluate at zero age")
    func evaluateAtZeroAge() {
        let f = FreshnessFunction(initialWeight: 0.8, halfLife: .seconds(60))
        let result = f.evaluate(age: .zero)
        #expect(abs(result - 0.8) < 0.001)
    }

    @Test("evaluate at half life")
    func evaluateAtHalfLife() {
        let f = FreshnessFunction(initialWeight: 1.0, halfLife: .seconds(60))
        let result = f.evaluate(age: .seconds(60))
        #expect(abs(result - 0.5) < 0.001)
    }

    @Test("evaluate at double half life")
    func evaluateAtDoubleHalfLife() {
        let f = FreshnessFunction(initialWeight: 1.0, halfLife: .seconds(60))
        let result = f.evaluate(age: .seconds(120))
        #expect(abs(result - 0.25) < 0.001)
    }

    @Test("evaluate with large age")
    func evaluateWithLargeAge() {
        let f = FreshnessFunction(initialWeight: 1.0, halfLife: .seconds(60))
        let result = f.evaluate(age: .seconds(600))
        #expect(result < 0.01)
    }

    @Test("zero halfLife returns zero")
    func zeroHalfLifeReturnsZero() {
        let f = FreshnessFunction(initialWeight: 1.0, halfLife: .zero)
        let result = f.evaluate(age: .seconds(1))
        #expect(result == 0.0)
    }

    @Test("preset NFC")
    func presetNFC() {
        let f = FreshnessFunction.nfc
        #expect(f.initialWeight == 1.0)
        #expect(f.halfLife == .seconds(30))
    }

    @Test("preset BLE")
    func presetBLE() {
        let f = FreshnessFunction.ble
        #expect(f.initialWeight == 0.8)
        #expect(f.halfLife == .seconds(60))
    }

    @Test("all presets have positive values")
    func allPresetsHavePositiveValues() {
        let presets: [FreshnessFunction] = [.nfc, .ble, .wifiDirect, .lora, .gossip, .storeCarryForward]
        for p in presets {
            #expect(p.initialWeight > 0)
            #expect(p.halfLife > .zero)
        }
    }
}
