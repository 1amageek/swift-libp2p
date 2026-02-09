import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("BLEDiscoveryScheduler")
struct BLEDiscoverySchedulerTests {

    @Test("three channels registered")
    func threeChannelsRegistered() {
        let scheduler = BLEDiscoveryScheduler()
        for ch: UInt8 in [37, 38, 39] {
            #expect(scheduler.currentInterval(for: ch) != nil)
        }
    }

    @Test("transmit decision has backoff")
    func transmitDecisionHasBackoff() {
        let scheduler = BLEDiscoveryScheduler()
        let decision = scheduler.shouldTransmit(on: 37)
        #expect(decision.backoff >= .zero)
    }

    @Test("backoff within range")
    func backoffWithinRange() {
        let scheduler = BLEDiscoveryScheduler()
        let decision = scheduler.shouldTransmit(on: 38)
        #expect(decision.backoff < .milliseconds(50))
    }

    @Test("per channel independence")
    func perChannelIndependence() {
        let scheduler = BLEDiscoveryScheduler(imin: .seconds(1), imax: .seconds(60), k: 5)
        scheduler.recordConsistent(on: 37)
        scheduler.recordConsistent(on: 37)
        // Channel 38 is unaffected
        #expect(scheduler.currentInterval(for: 38) == .seconds(1))
    }

    @Test("unregistered channel returns false")
    func unregisteredChannelReturnsFalse() {
        let scheduler = BLEDiscoveryScheduler()
        let decision = scheduler.shouldTransmit(on: 40)
        #expect(!decision.transmit)
        #expect(decision.backoff == .zero)
    }
}
