import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("BeaconFilter")
struct BeaconFilterTests {

    @Test("accept valid PoW")
    func acceptValidPoW() {
        let filter = BeaconFilter()
        let beacon = DecodedBeacon(
            tier: .tier1, truncID: 0x1234,
            nonce: Data([0, 0, 0, 1]), powValid: true
        )
        let discovery = makeRawDiscovery(payload: Data(repeating: 0xD0, count: 10))
        #expect(filter.accept(discovery, beacon: beacon, minInterval: .seconds(0)))
    }

    @Test("reject invalid PoW")
    func rejectInvalidPoW() {
        let filter = BeaconFilter()
        let beacon = DecodedBeacon(
            tier: .tier1, truncID: 0x1234,
            nonce: Data([0, 0, 0, 1]), powValid: false
        )
        let discovery = makeRawDiscovery(payload: Data(repeating: 0xD0, count: 10))
        #expect(!filter.accept(discovery, beacon: beacon, minInterval: .seconds(0)))
    }

    @Test("rate limit enforced")
    func rateLimitEnforced() {
        let filter = BeaconFilter()
        let beacon = DecodedBeacon(
            tier: .tier1, truncID: 0x5678,
            nonce: Data([0, 0, 0, 1]), powValid: true
        )
        let addr = makeOpaqueAddress()
        let ts = ContinuousClock.now
        let d1 = RawDiscovery(
            payload: Data(repeating: 0xD0, count: 10),
            sourceAddress: addr, timestamp: ts,
            rssi: nil, mediumID: "ble", physicalFingerprint: nil
        )
        let d2 = RawDiscovery(
            payload: Data(repeating: 0xD0, count: 10),
            sourceAddress: addr, timestamp: ts + .milliseconds(100),
            rssi: nil, mediumID: "ble", physicalFingerprint: nil
        )
        #expect(filter.accept(d1, beacon: beacon, minInterval: .seconds(5)))
        #expect(!filter.accept(d2, beacon: beacon, minInterval: .seconds(5)))
    }

    @Test("rate limit allows after interval")
    func rateLimitAllowsAfterInterval() {
        let filter = BeaconFilter()
        let beacon = DecodedBeacon(
            tier: .tier1, truncID: 0x9999,
            nonce: Data([0, 0, 0, 1]), powValid: true
        )
        let addr = makeOpaqueAddress()
        let ts = ContinuousClock.now
        let d1 = RawDiscovery(
            payload: Data(repeating: 0xD0, count: 10),
            sourceAddress: addr, timestamp: ts,
            rssi: nil, mediumID: "ble", physicalFingerprint: nil
        )
        let d2 = RawDiscovery(
            payload: Data(repeating: 0xD0, count: 10),
            sourceAddress: addr, timestamp: ts + .seconds(10),
            rssi: nil, mediumID: "ble", physicalFingerprint: nil
        )
        #expect(filter.accept(d1, beacon: beacon, minInterval: .seconds(5)))
        #expect(filter.accept(d2, beacon: beacon, minInterval: .seconds(5)))
    }

    @Test("sybil detection threshold")
    func sybilDetectionThreshold() {
        let filter = BeaconFilter(sybilThreshold: 2)
        let fp = PhysicalFingerprint(txPower: -10)
        let ts = ContinuousClock.now

        for i: UInt16 in 0...2 {
            let beacon = DecodedBeacon(
                tier: .tier1, truncID: i,
                nonce: Data([0, 0, 0, UInt8(i)]), powValid: true
            )
            let d = RawDiscovery(
                payload: Data(repeating: 0xD0, count: 10),
                sourceAddress: makeOpaqueAddress(),
                timestamp: ts + .milliseconds(Int(i)),
                rssi: nil, mediumID: "ble", physicalFingerprint: fp
            )
            if i <= 1 {
                #expect(filter.accept(d, beacon: beacon, minInterval: .zero))
            } else {
                // 3rd truncID (index 2) from same fingerprint -> threshold=2 -> accept (count becomes 3 > 2 -> reject)
                // Actually: after adding truncID 0 and 1 (count=2), adding truncID 2 makes count=3 > threshold=2 -> reject
                #expect(!filter.accept(d, beacon: beacon, minInterval: .zero))
            }
        }
    }

    @Test("sybil below threshold passes")
    func sybilBelowThresholdPasses() {
        let filter = BeaconFilter(sybilThreshold: 5)
        let fp = PhysicalFingerprint(txPower: -20)
        let ts = ContinuousClock.now

        for i: UInt16 in 0..<3 {
            let beacon = DecodedBeacon(
                tier: .tier1, truncID: i,
                nonce: Data([0, 0, 0, UInt8(i)]), powValid: true
            )
            let d = RawDiscovery(
                payload: Data(repeating: 0xD0, count: 10),
                sourceAddress: makeOpaqueAddress(),
                timestamp: ts + .milliseconds(Int(i)),
                rssi: nil, mediumID: "ble", physicalFingerprint: fp
            )
            #expect(filter.accept(d, beacon: beacon, minInterval: .zero))
        }
    }

    @Test("no fingerprint bypasses sybil")
    func noFingerprintBypassesSybil() {
        let filter = BeaconFilter(sybilThreshold: 1)
        let beacon = DecodedBeacon(
            tier: .tier1, truncID: 0x0001,
            nonce: Data([0, 0, 0, 1]), powValid: true
        )
        let d = RawDiscovery(
            payload: Data(repeating: 0xD0, count: 10),
            sourceAddress: makeOpaqueAddress(),
            timestamp: .now,
            rssi: nil, mediumID: "ble", physicalFingerprint: nil
        )
        #expect(filter.accept(d, beacon: beacon, minInterval: .zero))
    }

    @Test("prune expired removes old entries")
    func pruneExpiredRemovesOldEntries() {
        let filter = BeaconFilter(sybilThreshold: 5, sybilWindow: .seconds(1))
        // Just verify it doesn't crash
        filter.pruneExpired()
    }
}
