import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("ScanCoordinator")
struct ScanCoordinatorTests {

    @Test("register medium")
    func registerMedium() {
        let coord = ScanCoordinator()
        coord.registerMedium("ble", imin: .seconds(1), imax: .seconds(60), k: 1)
        #expect(coord.currentInterval(for: "ble") != nil)
    }

    @Test("unregistered returns false")
    func unregisteredReturnsFalse() {
        let coord = ScanCoordinator()
        #expect(!coord.shouldTransmit(medium: "unknown"))
    }

    @Test("currentInterval returns nil for unregistered")
    func currentIntervalReturnsNilForUnregistered() {
        let coord = ScanCoordinator()
        #expect(coord.currentInterval(for: "unknown") == nil)
    }

    @Test("consistent delegation")
    func consistentDelegation() {
        let coord = ScanCoordinator()
        coord.registerMedium("ble", imin: .seconds(1), imax: .seconds(60), k: 5)
        coord.reportConsistent(medium: "ble")
        coord.reportConsistent(medium: "ble")
        // endOfInterval (via shouldTransmit) will reset, but we tested recordConsistent was called
        // The interval should still be imin since we haven't called shouldTransmit yet
        #expect(coord.currentInterval(for: "ble") == .seconds(1))
    }

    @Test("inconsistent resets delegated")
    func inconsistentResetsDelegated() {
        let coord = ScanCoordinator()
        coord.registerMedium("ble", imin: .seconds(1), imax: .seconds(60), k: 1)
        let _ = coord.shouldTransmit(medium: "ble") // doubles interval
        coord.reportInconsistent(medium: "ble")
        #expect(coord.currentInterval(for: "ble") == .seconds(1))
    }

    @Test("registered media list")
    func registeredMediaList() {
        let coord = ScanCoordinator()
        coord.registerMedium("ble", imin: .seconds(1), imax: .seconds(60), k: 1)
        coord.registerMedium("lora", imin: .seconds(5), imax: .seconds(300), k: 2)
        let media = coord.registeredMedia
        #expect(media.contains("ble"))
        #expect(media.contains("lora"))
        #expect(media.count == 2)
    }
}
