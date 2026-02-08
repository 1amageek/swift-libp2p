/// NATDeviceTypeTests - Tests for NAT device type detection
import Testing
import P2PCore
@testable import P2PNAT

@Suite("NATDeviceType Tests")
struct NATDeviceTypeTests {

    // MARK: - NATDeviceType Enum Tests

    @Test("NATDeviceType cases are equatable")
    func natDeviceTypeEquatable() {
        #expect(NATDeviceType.endpointIndependent == .endpointIndependent)
        #expect(NATDeviceType.endpointDependent == .endpointDependent)
        #expect(NATDeviceType.unknown == .unknown)
        #expect(NATDeviceType.endpointIndependent != .endpointDependent)
        #expect(NATDeviceType.endpointIndependent != .unknown)
        #expect(NATDeviceType.endpointDependent != .unknown)
    }

    // MARK: - Unknown / Insufficient Data

    @Test("Returns unknown with no observations")
    func unknownWithNoData() {
        let detector = NATTypeDetector()
        let result = detector.detectType(from: [])
        #expect(result == .unknown)
    }

    @Test("Returns unknown with insufficient observations")
    func unknownWithInsufficientData() {
        let detector = NATTypeDetector(minimumObservations: 3)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .unknown)
    }

    @Test("Returns unknown with insufficient distinct observers")
    func unknownWithInsufficientObservers() {
        let detector = NATTypeDetector(minimumObservations: 1, minimumDistinctObservers: 3)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .unknown)
    }

    // MARK: - Endpoint Independent (Cone NAT)

    @Test("Detects endpoint independent when same external address from multiple observers")
    func endpointIndependentSameExternal() {
        let detector = NATTypeDetector(minimumObservations: 3, minimumDistinctObservers: 3)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }

    @Test("Detects endpoint independent with multiple local addresses mapping to consistent externals")
    func endpointIndependentMultipleLocals() {
        let detector = NATTypeDetector(minimumObservations: 3, minimumDistinctObservers: 2)
        let observations = [
            // Local :4001 -> External :4001 (consistent)
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            // Local :5001 -> External :5001 (consistent)
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 5001),
                observedAddress: .tcp(host: "203.0.113.1", port: 5001),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }

    @Test("Detects endpoint independent with UDP/QUIC addresses")
    func endpointIndependentUDP() {
        let detector = NATTypeDetector(minimumObservations: 3, minimumDistinctObservers: 3)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .quic(host: "192.168.1.10", port: 4001),
                observedAddress: .quic(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .quic(host: "192.168.1.10", port: 4001),
                observedAddress: .quic(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .quic(host: "192.168.1.10", port: 4001),
                observedAddress: .quic(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }

    // MARK: - Endpoint Dependent (Symmetric NAT)

    @Test("Detects endpoint dependent when different external ports from same local")
    func endpointDependentDifferentPorts() {
        let detector = NATTypeDetector(minimumObservations: 3, minimumDistinctObservers: 3)
        let observations = [
            // Same local address, but each observer sees a different external port
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 12345),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 12346),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 12347),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointDependent)
    }

    @Test("Detects endpoint dependent when different external IPs from same local")
    func endpointDependentDifferentIPs() {
        let detector = NATTypeDetector(minimumObservations: 3, minimumDistinctObservers: 3)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.2", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.3", port: 4001),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointDependent)
    }

    @Test("Detects endpoint dependent with multiple local addresses all varying")
    func endpointDependentMultipleLocals() {
        let detector = NATTypeDetector(minimumObservations: 4, minimumDistinctObservers: 2)
        let observations = [
            // Local :4001 -> different external ports
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 11111),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 22222),
                observerCount: 1
            ),
            // Local :5001 -> different external ports
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 5001),
                observedAddress: .tcp(host: "203.0.113.1", port: 33333),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 5001),
                observedAddress: .tcp(host: "203.0.113.1", port: 44444),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointDependent)
    }

    // MARK: - Mixed Observations

    @Test("Mixed: mostly consistent with one varying group is endpoint independent")
    func mixedMostlyConsistent() {
        // 4 groups, 3 consistent, 1 varying -> 75% independent
        // With threshold at 0.8 this should be endpoint dependent
        let detector = NATTypeDetector(minimumObservations: 4, minimumDistinctObservers: 2, independentThreshold: 0.8)
        let observations = [
            // Group 1: consistent
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            // Group 2: consistent
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4002),
                observedAddress: .tcp(host: "203.0.113.1", port: 4002),
                observerCount: 1
            ),
            // Group 3: consistent
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4003),
                observedAddress: .tcp(host: "203.0.113.1", port: 4003),
                observerCount: 1
            ),
            // Group 4: varying (2 different externals for same local)
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4004),
                observedAddress: .tcp(host: "203.0.113.1", port: 55555),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4004),
                observedAddress: .tcp(host: "203.0.113.1", port: 55556),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointDependent)
    }

    @Test("Mixed: with lower threshold classifies as endpoint independent")
    func mixedWithLowerThreshold() {
        // Same data as above but with 0.5 threshold -> 3/4 = 75% > 50%
        let detector = NATTypeDetector(minimumObservations: 4, minimumDistinctObservers: 2, independentThreshold: 0.5)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4002),
                observedAddress: .tcp(host: "203.0.113.1", port: 4002),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4003),
                observedAddress: .tcp(host: "203.0.113.1", port: 4003),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4004),
                observedAddress: .tcp(host: "203.0.113.1", port: 55555),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4004),
                observedAddress: .tcp(host: "203.0.113.1", port: 55556),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }

    // MARK: - Edge Cases

    @Test("Single local address with single consistent external is independent")
    func singleGroupConsistent() {
        let detector = NATTypeDetector(minimumObservations: 3, minimumDistinctObservers: 3)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }

    @Test("Exactly at minimum threshold with matching data")
    func exactMinimumThreshold() {
        let detector = NATTypeDetector(minimumObservations: 3, minimumDistinctObservers: 2)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "10.0.0.1", port: 8080),
                observedAddress: .tcp(host: "1.2.3.4", port: 8080),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "10.0.0.1", port: 8080),
                observedAddress: .tcp(host: "1.2.3.4", port: 8080),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "10.0.0.1", port: 8080),
                observedAddress: .tcp(host: "1.2.3.4", port: 8080),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }

    @Test("One below minimum observations returns unknown")
    func oneBelowMinimum() {
        let detector = NATTypeDetector(minimumObservations: 4, minimumDistinctObservers: 1)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .unknown)
    }

    @Test("IPv6 addresses are handled correctly")
    func ipv6Addresses() {
        let detector = NATTypeDetector(minimumObservations: 3, minimumDistinctObservers: 3)
        let local = Multiaddr(uncheckedProtocols: [.ip6("fd00:0:0:0:0:0:0:1"), .tcp(4001)])
        let observed = Multiaddr(uncheckedProtocols: [.ip6("2001:db8:0:0:0:0:0:1"), .tcp(4001)])
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: local, observedAddress: observed, observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: local, observedAddress: observed, observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: local, observedAddress: observed, observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }

    @Test("lastDetectedType returns the cached result")
    func lastDetectedTypeCache() {
        let detector = NATTypeDetector(minimumObservations: 1, minimumDistinctObservers: 1)

        // Initially unknown
        #expect(detector.lastDetectedType == .unknown)

        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
        ]
        _ = detector.detectType(from: observations)
        #expect(detector.lastDetectedType == .endpointIndependent)
    }

    @Test("Multiple calls update the cached result")
    func multipleCalls() {
        let detector = NATTypeDetector(minimumObservations: 2, minimumDistinctObservers: 2)

        // First: endpoint independent
        let independentObs = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
        ]
        let result1 = detector.detectType(from: independentObs)
        #expect(result1 == .endpointIndependent)

        // Second: endpoint dependent
        let dependentObs = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 12345),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 54321),
                observerCount: 1
            ),
        ]
        let result2 = detector.detectType(from: dependentObs)
        #expect(result2 == .endpointDependent)
        #expect(detector.lastDetectedType == .endpointDependent)
    }

    @Test("Custom configuration parameters are respected")
    func customConfiguration() {
        // Very relaxed: 1 observation, 1 observer, 0% threshold (always independent)
        let detector = NATTypeDetector(
            minimumObservations: 1,
            minimumDistinctObservers: 1,
            independentThreshold: 0.0
        )
        // Even with varying ports, threshold 0.0 means 0/1 = 0% >= 0% -> independent
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 11111),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 22222),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        // With threshold 0.0, the ratio 0/1 = 0% >= 0% should be true
        #expect(result == .endpointIndependent)
    }

    @Test("High observer count satisfies distinct observer threshold")
    func highObserverCount() {
        let detector = NATTypeDetector(minimumObservations: 1, minimumDistinctObservers: 5)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 5
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }

    @Test("ObservationSummary equality")
    func observationSummaryEquality() {
        let a = NATTypeDetector.ObservationSummary(
            localAddress: .tcp(host: "192.168.1.10", port: 4001),
            observedAddress: .tcp(host: "203.0.113.1", port: 4001),
            observerCount: 3
        )
        let b = NATTypeDetector.ObservationSummary(
            localAddress: .tcp(host: "192.168.1.10", port: 4001),
            observedAddress: .tcp(host: "203.0.113.1", port: 4001),
            observerCount: 3
        )
        let c = NATTypeDetector.ObservationSummary(
            localAddress: .tcp(host: "192.168.1.10", port: 4001),
            observedAddress: .tcp(host: "203.0.113.1", port: 5001),
            observerCount: 3
        )
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Default configuration values")
    func defaultConfiguration() {
        let detector = NATTypeDetector()
        #expect(detector.minimumObservations == 3)
        #expect(detector.minimumDistinctObservers == 2)
        #expect(detector.independentThreshold == 0.8)
    }

    @Test("Threshold exactly at boundary classifies as independent")
    func thresholdExactBoundary() {
        // 5 groups, 4 consistent, 1 varying -> 4/5 = 80% exactly at 0.8
        let detector = NATTypeDetector(minimumObservations: 5, minimumDistinctObservers: 1, independentThreshold: 0.8)
        let observations = [
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4001),
                observedAddress: .tcp(host: "203.0.113.1", port: 4001),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4002),
                observedAddress: .tcp(host: "203.0.113.1", port: 4002),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4003),
                observedAddress: .tcp(host: "203.0.113.1", port: 4003),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4004),
                observedAddress: .tcp(host: "203.0.113.1", port: 4004),
                observerCount: 1
            ),
            // Varying group
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4005),
                observedAddress: .tcp(host: "203.0.113.1", port: 55555),
                observerCount: 1
            ),
            NATTypeDetector.ObservationSummary(
                localAddress: .tcp(host: "192.168.1.10", port: 4005),
                observedAddress: .tcp(host: "203.0.113.1", port: 55556),
                observerCount: 1
            ),
        ]
        let result = detector.detectType(from: observations)
        #expect(result == .endpointIndependent)
    }
}
