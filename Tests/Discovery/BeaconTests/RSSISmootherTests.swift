import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("RSSISmoother")
struct RSSISmootherTests {

    @Test("first reading passthrough")
    func firstReadingPassthrough() {
        let smoother = RSSISmoother(alpha: 0.3)
        let addr = makeOpaqueAddress()
        let result = smoother.smooth(rawRSSI: -70.0, from: addr)
        #expect(result == -70.0)
    }

    @Test("EMA formula correct")
    func emaFormulaCorrect() {
        let smoother = RSSISmoother(alpha: 0.3)
        let addr = makeOpaqueAddress()
        let _ = smoother.smooth(rawRSSI: -70.0, from: addr)
        let result = smoother.smooth(rawRSSI: -60.0, from: addr)
        // alpha * new + (1-alpha) * prev = 0.3 * -60 + 0.7 * -70 = -18 + -49 = -67
        #expect(abs(result - (-67.0)) < 0.001)
    }

    @Test("per address independence")
    func perAddressIndependence() {
        let smoother = RSSISmoother(alpha: 0.3)
        let addrA = OpaqueAddress(mediumID: "ble", raw: Data([0x01]))
        let addrB = OpaqueAddress(mediumID: "ble", raw: Data([0x02]))
        let _ = smoother.smooth(rawRSSI: -70.0, from: addrA)
        let resultB = smoother.smooth(rawRSSI: -50.0, from: addrB)
        #expect(resultB == -50.0) // first reading for B
    }

    @Test("reset clears history")
    func resetClearsHistory() {
        let smoother = RSSISmoother(alpha: 0.3)
        let addr = makeOpaqueAddress()
        let _ = smoother.smooth(rawRSSI: -70.0, from: addr)
        smoother.reset()
        let result = smoother.smooth(rawRSSI: -50.0, from: addr)
        #expect(result == -50.0) // treated as first reading
    }

    @Test("convergence behavior")
    func convergenceBehavior() {
        let smoother = RSSISmoother(alpha: 0.3)
        let addr = makeOpaqueAddress()
        var last = smoother.smooth(rawRSSI: -70.0, from: addr)
        for _ in 0..<100 {
            last = smoother.smooth(rawRSSI: -50.0, from: addr)
        }
        // After many iterations with same input, should converge to -50
        #expect(abs(last - (-50.0)) < 0.01)
    }
}
