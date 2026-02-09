import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("TrickleTimer")
struct TrickleTimerTests {

    @Test("initial interval")
    func initialInterval() {
        let timer = TrickleTimer(imin: .seconds(1), imax: .seconds(64), k: 1)
        #expect(timer.currentInterval == .seconds(1))
    }

    @Test("interval doubles after endOfInterval")
    func intervalDoublesAfterEndOfInterval() {
        let timer = TrickleTimer(imin: .seconds(1), imax: .seconds(64), k: 1)
        let _ = timer.endOfInterval()
        #expect(timer.currentInterval == .seconds(2))
    }

    @Test("interval caps at imax")
    func intervalCapsAtImax() {
        let timer = TrickleTimer(imin: .seconds(1), imax: .seconds(4), k: 1)
        let _ = timer.endOfInterval() // 1 -> 2
        let _ = timer.endOfInterval() // 2 -> 4
        let _ = timer.endOfInterval() // 4 -> 4 (capped)
        #expect(timer.currentInterval == .seconds(4))
    }

    @Test("consistent counter increments")
    func consistentCounterIncrements() {
        let timer = TrickleTimer(imin: .seconds(1), imax: .seconds(64), k: 5)
        timer.recordConsistent()
        timer.recordConsistent()
        #expect(timer.consistentCount == 2)
    }

    @Test("suppression when counter reaches k")
    func suppressionWhenCounterReachesK() {
        let timer = TrickleTimer(imin: .seconds(1), imax: .seconds(64), k: 2)
        timer.recordConsistent()
        timer.recordConsistent()
        let shouldTransmit = timer.endOfInterval()
        #expect(!shouldTransmit)
    }

    @Test("reset on inconsistency")
    func resetOnInconsistency() {
        let timer = TrickleTimer(imin: .seconds(1), imax: .seconds(64), k: 5)
        let _ = timer.endOfInterval() // 1 -> 2
        let _ = timer.endOfInterval() // 2 -> 4
        timer.recordInconsistent()
        #expect(timer.currentInterval == .seconds(1))
        #expect(timer.consistentCount == 0)
    }

    @Test("k=1 always transmits when no consistent")
    func kEqualsOneAlwaysTransmits() {
        let timer = TrickleTimer(imin: .seconds(1), imax: .seconds(64), k: 1)
        // no consistent recorded, counter=0 < k=1
        let shouldTransmit = timer.endOfInterval()
        #expect(shouldTransmit)
    }
}
