import Testing
import P2PCore
@testable import P2P

@Suite("BlackHoleDetector")
struct BlackHoleDetectorTests {

    @Test("no data means no black hole")
    func noData() {
        let detector = BlackHoleDetector()
        #expect(!detector.isBlackHole(.udp))
        #expect(!detector.isBlackHole(.ipv6))
    }

    @Test("all failures creates black hole")
    func allFailures() {
        let detector = BlackHoleDetector(threshold: 0.05, windowSize: 10)
        for _ in 0..<10 {
            detector.recordResult(pathType: .udp, success: false)
        }
        #expect(detector.isBlackHole(.udp))
    }

    @Test("all successes no black hole")
    func allSuccesses() {
        let detector = BlackHoleDetector(threshold: 0.05, windowSize: 10)
        for _ in 0..<10 {
            detector.recordResult(pathType: .udp, success: true)
        }
        #expect(!detector.isBlackHole(.udp))
    }

    @Test("below threshold triggers black hole")
    func belowThreshold() {
        let detector = BlackHoleDetector(threshold: 0.10, windowSize: 100)
        // 5 successes, 95 failures = 5% < 10%
        for _ in 0..<5 { detector.recordResult(pathType: .udp, success: true) }
        for _ in 0..<95 { detector.recordResult(pathType: .udp, success: false) }
        #expect(detector.isBlackHole(.udp))
    }

    @Test("above threshold not black hole")
    func aboveThreshold() {
        let detector = BlackHoleDetector(threshold: 0.10, windowSize: 100)
        // 20 successes, 80 failures = 20% > 10%
        for _ in 0..<20 { detector.recordResult(pathType: .udp, success: true) }
        for _ in 0..<80 { detector.recordResult(pathType: .udp, success: false) }
        #expect(!detector.isBlackHole(.udp))
    }

    @Test("filterAddresses removes black-holed UDP")
    func filterUDP() throws {
        let detector = BlackHoleDetector(threshold: 0.05, windowSize: 10)
        for _ in 0..<10 { detector.recordResult(pathType: .udp, success: false) }

        let addrs = [
            try Multiaddr("/ip4/1.2.3.4/tcp/4001"),
            try Multiaddr("/ip4/1.2.3.4/udp/4001/quic-v1"),
        ]
        let filtered = detector.filterAddresses(addrs)
        #expect(filtered.count == 1)  // Only TCP kept
    }

    @Test("filterAddresses removes black-holed IPv6")
    func filterIPv6() throws {
        let detector = BlackHoleDetector(threshold: 0.05, windowSize: 10)
        for _ in 0..<10 { detector.recordResult(pathType: .ipv6, success: false) }

        let addrs = [
            try Multiaddr("/ip4/1.2.3.4/tcp/4001"),
            try Multiaddr("/ip6/::1/tcp/4001"),
        ]
        let filtered = detector.filterAddresses(addrs)
        #expect(filtered.count == 1)  // Only IPv4 kept
    }

    @Test("rolling window evicts old entries")
    func rollingWindow() {
        let detector = BlackHoleDetector(threshold: 0.05, windowSize: 10)
        // Fill with failures
        for _ in 0..<10 { detector.recordResult(pathType: .udp, success: false) }
        #expect(detector.isBlackHole(.udp))

        // Add successes to push out failures
        for _ in 0..<10 { detector.recordResult(pathType: .udp, success: true) }
        #expect(!detector.isBlackHole(.udp))
    }

    @Test("reset clears data")
    func reset() {
        let detector = BlackHoleDetector(threshold: 0.05, windowSize: 10)
        for _ in 0..<10 { detector.recordResult(pathType: .udp, success: false) }
        detector.reset()
        #expect(!detector.isBlackHole(.udp))
    }

    @Test("independent path types")
    func independentPaths() {
        let detector = BlackHoleDetector(threshold: 0.05, windowSize: 10)
        for _ in 0..<10 { detector.recordResult(pathType: .udp, success: false) }
        for _ in 0..<10 { detector.recordResult(pathType: .ipv6, success: true) }
        #expect(detector.isBlackHole(.udp))
        #expect(!detector.isBlackHole(.ipv6))
    }
}
