/// HealthMonitorTests - Tests for HealthMonitor

import Testing
import Foundation
import P2PCore
@testable import P2P

private func randomPeerID() -> PeerID {
    PeerID(publicKey: KeyPair.generateEd25519().publicKey)
}

/// Mock PingProvider for testing.
private struct MockPingProvider: PingProvider, @unchecked Sendable {
    let result: Result<Duration, any Error>

    func ping(_ peer: PeerID) async throws -> Duration {
        switch result {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }
}

private enum MockError: Error {
    case pingFailed
}

@Suite("HealthMonitor Tests")
struct HealthMonitorTests {

    // MARK: - Monitoring Lifecycle

    @Test("Start monitoring adds peer")
    func startMonitoring() async {
        let monitor = HealthMonitor(
            configuration: .default,
            pingProvider: MockPingProvider(result: .success(.milliseconds(10)))
        )

        await monitor.startMonitoring(peer: randomPeerID())
        let peers = await monitor.monitoredPeers
        #expect(peers.count == 1)

        await monitor.stopAll()
    }

    @Test("Stop monitoring removes peer")
    func stopMonitoring() async {
        let peer = randomPeerID()
        let monitor = HealthMonitor(
            configuration: .default,
            pingProvider: MockPingProvider(result: .success(.milliseconds(10)))
        )

        await monitor.startMonitoring(peer: peer)
        #expect(await monitor.isMonitoring(peer: peer) == true)

        await monitor.stopMonitoring(peer: peer)
        #expect(await monitor.isMonitoring(peer: peer) == false)
    }

    @Test("isMonitoring returns correct state")
    func isMonitoring() async {
        let peer1 = randomPeerID()
        let peer2 = randomPeerID()
        let monitor = HealthMonitor(
            configuration: .default,
            pingProvider: MockPingProvider(result: .success(.milliseconds(10)))
        )

        await monitor.startMonitoring(peer: peer1)

        #expect(await monitor.isMonitoring(peer: peer1) == true)
        #expect(await monitor.isMonitoring(peer: peer2) == false)

        await monitor.stopAll()
    }

    @Test("Multiple peers can be monitored")
    func monitoredPeers() async {
        let peer1 = randomPeerID()
        let peer2 = randomPeerID()
        let peer3 = randomPeerID()
        let monitor = HealthMonitor(
            configuration: .default,
            pingProvider: MockPingProvider(result: .success(.milliseconds(10)))
        )

        await monitor.startMonitoring(peer: peer1)
        await monitor.startMonitoring(peer: peer2)
        await monitor.startMonitoring(peer: peer3)

        let peers = await monitor.monitoredPeers
        #expect(peers.count == 3)
        #expect(Set(peers).contains(peer1))
        #expect(Set(peers).contains(peer2))
        #expect(Set(peers).contains(peer3))

        await monitor.stopAll()
    }

    @Test("Stop all clears all peers")
    func stopAll() async {
        let monitor = HealthMonitor(
            configuration: .default,
            pingProvider: MockPingProvider(result: .success(.milliseconds(10)))
        )

        await monitor.startMonitoring(peer: randomPeerID())
        await monitor.startMonitoring(peer: randomPeerID())
        await monitor.startMonitoring(peer: randomPeerID())

        await monitor.stopAll()

        let peers = await monitor.monitoredPeers
        #expect(peers.isEmpty)
    }

    // MARK: - Health Check

    @Test("checkHealth success returns duration", .timeLimit(.minutes(1)))
    func healthCheckSuccess() async throws {
        let expectedRTT = Duration.milliseconds(50)
        let monitor = HealthMonitor(
            configuration: .default,
            pingProvider: MockPingProvider(result: .success(expectedRTT))
        )

        let peer = randomPeerID()
        let rtt = try await monitor.checkHealth(of: peer)
        #expect(rtt == expectedRTT)
    }

    @Test("checkHealth failure throws", .timeLimit(.minutes(1)))
    func healthCheckFailure() async {
        let monitor = HealthMonitor(
            configuration: .default,
            pingProvider: MockPingProvider(result: .failure(MockError.pingFailed))
        )

        let peer = randomPeerID()
        await #expect(throws: (any Error).self) {
            _ = try await monitor.checkHealth(of: peer)
        }
    }

    // MARK: - Failure Counting

    @Test("Initial failure count is zero")
    func initialFailureCount() async {
        let monitor = HealthMonitor(
            configuration: .default,
            pingProvider: MockPingProvider(result: .success(.milliseconds(10)))
        )

        let peer = randomPeerID()
        let count = await monitor.failureCount(for: peer)
        #expect(count == 0)
    }

    // MARK: - Configuration

    @Test("Default configuration values")
    func defaultConfig() {
        let config = HealthMonitorConfiguration.default

        #expect(config.interval == .seconds(30))
        #expect(config.timeout == .seconds(10))
        #expect(config.maxFailures == 3)
        #expect(config.checkImmediately == false)
    }

    @Test("Aggressive configuration values")
    func aggressiveConfig() {
        let config = HealthMonitorConfiguration.aggressive

        #expect(config.interval == .seconds(10))
        #expect(config.timeout == .seconds(5))
        #expect(config.maxFailures == 2)
        #expect(config.checkImmediately == true)
    }

    @Test("Relaxed configuration values")
    func relaxedConfig() {
        let config = HealthMonitorConfiguration.relaxed

        #expect(config.interval == .seconds(60))
        #expect(config.timeout == .seconds(15))
        #expect(config.maxFailures == 5)
        #expect(config.checkImmediately == false)
    }
}
