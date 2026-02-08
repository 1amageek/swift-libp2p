/// Tests for QUIC hole punch coordinator.
///
/// These are unit tests that verify the coordinator's configuration,
/// address validation, error handling, and timing behavior without
/// requiring actual network connections.

import Testing
import Foundation
@testable import P2PTransportQUIC
@testable import P2PCore

// MARK: - Config Tests

@Suite("HolePunchConfig Tests")
struct HolePunchConfigTests {

    @Test("Default config has expected values")
    func defaultConfig() {
        let config = HolePunchConfig()

        #expect(config.timeout == .seconds(10))
        #expect(config.simultaneousAttempts == 3)
        #expect(config.retryDelay == .milliseconds(200))
    }

    @Test("Custom config preserves values")
    func customConfig() {
        let config = HolePunchConfig(
            timeout: .seconds(30),
            simultaneousAttempts: 5,
            retryDelay: .milliseconds(500)
        )

        #expect(config.timeout == .seconds(30))
        #expect(config.simultaneousAttempts == 5)
        #expect(config.retryDelay == .milliseconds(500))
    }

    @Test("Config with minimal timeout")
    func minimalTimeout() {
        let config = HolePunchConfig(
            timeout: .milliseconds(100),
            simultaneousAttempts: 1,
            retryDelay: .milliseconds(10)
        )

        #expect(config.timeout == .milliseconds(100))
        #expect(config.simultaneousAttempts == 1)
        #expect(config.retryDelay == .milliseconds(10))
    }
}

// MARK: - Coordinator Initialization Tests

@Suite("QUICHolePunchCoordinator Initialization Tests")
struct QUICHolePunchCoordinatorInitTests {

    @Test("Coordinator initializes with default config")
    func initDefaultConfig() {
        let coordinator = QUICHolePunchCoordinator()

        #expect(coordinator.config.timeout == .seconds(10))
        #expect(coordinator.config.simultaneousAttempts == 3)
        #expect(coordinator.config.retryDelay == .milliseconds(200))
    }

    @Test("Coordinator initializes with custom config")
    func initCustomConfig() {
        let config = HolePunchConfig(
            timeout: .seconds(20),
            simultaneousAttempts: 7,
            retryDelay: .seconds(1)
        )
        let coordinator = QUICHolePunchCoordinator(config: config)

        #expect(coordinator.config.timeout == .seconds(20))
        #expect(coordinator.config.simultaneousAttempts == 7)
        #expect(coordinator.config.retryDelay == .seconds(1))
    }

    @Test("Coordinator starts with zero total attempts")
    func initialTotalAttempts() {
        let coordinator = QUICHolePunchCoordinator()

        #expect(coordinator.totalAttempts == 0)
    }
}

// MARK: - Address Validation Tests

@Suite("QUIC Hole Punch Address Validation Tests")
struct QUICHolePunchAddressValidationTests {

    @Test("Valid IPv4 QUIC address")
    func validIPv4QUICAddress() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/ip4/192.168.1.1/udp/4433/quic-v1")

        #expect(coordinator.isValidQUICAddress(addr))
    }

    @Test("Valid IPv6 QUIC address")
    func validIPv6QUICAddress() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/ip6/::1/udp/4433/quic-v1")

        #expect(coordinator.isValidQUICAddress(addr))
    }

    @Test("Valid QUIC (non-v1) address")
    func validQUICLegacyAddress() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/ip4/10.0.0.1/udp/5000/quic")

        #expect(coordinator.isValidQUICAddress(addr))
    }

    @Test("TCP address is not valid for QUIC hole punch")
    func tcpAddressInvalid() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/ip4/192.168.1.1/tcp/4433")

        #expect(!coordinator.isValidQUICAddress(addr))
    }

    @Test("UDP-only address is not valid (no QUIC protocol)")
    func udpOnlyAddressInvalid() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/ip4/192.168.1.1/udp/4433")

        #expect(!coordinator.isValidQUICAddress(addr))
    }

    @Test("IP-only address is not valid (no UDP port)")
    func ipOnlyAddressInvalid() {
        let addr = Multiaddr(uncheckedProtocols: [.ip4("192.168.1.1"), .quicV1])

        let coordinator = QUICHolePunchCoordinator()
        #expect(!coordinator.isValidQUICAddress(addr))
    }

    @Test("Memory address is not valid for QUIC hole punch")
    func memoryAddressInvalid() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/memory/test-address")

        #expect(!coordinator.isValidQUICAddress(addr))
    }

    @Test("WebSocket address is not valid for QUIC hole punch")
    func webSocketAddressInvalid() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/8080/ws")

        #expect(!coordinator.isValidQUICAddress(addr))
    }

    @Test("Wildcard listen address is valid")
    func wildcardListenAddress() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/ip4/0.0.0.0/udp/0/quic-v1")

        #expect(coordinator.isValidQUICAddress(addr))
    }

    @Test("IPv6 wildcard listen address is valid")
    func ipv6WildcardListenAddress() throws {
        let coordinator = QUICHolePunchCoordinator()
        let addr = try Multiaddr("/ip6/::/udp/0/quic-v1")

        #expect(coordinator.isValidQUICAddress(addr))
    }
}

// MARK: - Error Case Tests

@Suite("QUIC Hole Punch Error Tests")
struct QUICHolePunchErrorTests {

    @Test("Punch with invalid target address throws invalidAddress", .timeLimit(.minutes(1)))
    func punchInvalidTarget() async throws {
        let coordinator = QUICHolePunchCoordinator()
        let invalidTarget = try Multiaddr("/ip4/192.168.1.1/tcp/4433")
        let validLocal = try Multiaddr("/ip4/0.0.0.0/udp/4433/quic-v1")

        await #expect(throws: HolePunchError.self) {
            _ = try await coordinator.punch(to: invalidTarget, from: validLocal)
        }
    }

    @Test("Punch with invalid local address throws invalidAddress", .timeLimit(.minutes(1)))
    func punchInvalidLocal() async throws {
        let coordinator = QUICHolePunchCoordinator()
        let validTarget = try Multiaddr("/ip4/203.0.113.1/udp/5678/quic-v1")
        let invalidLocal = try Multiaddr("/ip4/0.0.0.0/tcp/4433")

        await #expect(throws: HolePunchError.self) {
            _ = try await coordinator.punch(to: validTarget, from: invalidLocal)
        }
    }

    @Test("Punch with UDP-only target throws invalidAddress", .timeLimit(.minutes(1)))
    func punchUDPOnlyTarget() async throws {
        let coordinator = QUICHolePunchCoordinator()
        let udpOnly = try Multiaddr("/ip4/203.0.113.1/udp/5678")
        let validLocal = try Multiaddr("/ip4/0.0.0.0/udp/4433/quic-v1")

        await #expect(throws: HolePunchError.self) {
            _ = try await coordinator.punch(to: udpOnly, from: validLocal)
        }
    }
}

// MARK: - HolePunchResult Tests

@Suite("HolePunchResult Tests")
struct HolePunchResultTests {

    @Test("Result stores success state correctly")
    func successResult() throws {
        let addr = try Multiaddr("/ip4/203.0.113.1/udp/5678/quic-v1")
        let result = HolePunchResult(
            success: true,
            remoteAddress: addr,
            attemptCount: 3,
            duration: .seconds(2)
        )

        #expect(result.success == true)
        #expect(result.remoteAddress == addr)
        #expect(result.attemptCount == 3)
        #expect(result.duration == .seconds(2))
    }

    @Test("Result stores failure state correctly")
    func failureResult() throws {
        let addr = try Multiaddr("/ip4/203.0.113.1/udp/5678/quic-v1")
        let result = HolePunchResult(
            success: false,
            remoteAddress: addr,
            attemptCount: 15,
            duration: .seconds(10)
        )

        #expect(result.success == false)
        #expect(result.attemptCount == 15)
        #expect(result.duration == .seconds(10))
    }

    @Test("Result with zero attempts")
    func zeroAttemptResult() throws {
        let addr = try Multiaddr("/ip4/10.0.0.1/udp/1234/quic-v1")
        let result = HolePunchResult(
            success: false,
            remoteAddress: addr,
            attemptCount: 0,
            duration: .zero
        )

        #expect(result.attemptCount == 0)
        #expect(result.duration == .zero)
    }
}

// MARK: - Punch Behavior Tests

@Suite("QUIC Hole Punch Behavior Tests")
struct QUICHolePunchBehaviorTests {

    @Test("Punch completes with valid addresses", .timeLimit(.minutes(1)))
    func punchCompletesWithValidAddresses() async throws {
        // Use a very short timeout so the test runs quickly
        let config = HolePunchConfig(
            timeout: .milliseconds(500),
            simultaneousAttempts: 2,
            retryDelay: .milliseconds(50)
        )
        let coordinator = QUICHolePunchCoordinator(config: config)
        let target = try Multiaddr("/ip4/203.0.113.1/udp/5678/quic-v1")
        let local = try Multiaddr("/ip4/0.0.0.0/udp/4433/quic-v1")

        // This will run through the timing rounds and complete
        let result = try await coordinator.punch(to: target, from: local)

        // The coordinator ran through its attempts
        #expect(result.remoteAddress == target)
        #expect(result.attemptCount > 0)
        #expect(result.duration > .zero)
    }

    @Test("Punch tracks total attempts across calls", .timeLimit(.minutes(1)))
    func punchTracksAttempts() async throws {
        let config = HolePunchConfig(
            timeout: .milliseconds(200),
            simultaneousAttempts: 2,
            retryDelay: .milliseconds(50)
        )
        let coordinator = QUICHolePunchCoordinator(config: config)
        let target = try Multiaddr("/ip4/203.0.113.1/udp/5678/quic-v1")
        let local = try Multiaddr("/ip4/0.0.0.0/udp/4433/quic-v1")

        #expect(coordinator.totalAttempts == 0)

        _ = try await coordinator.punch(to: target, from: local)

        let afterFirst = coordinator.totalAttempts
        #expect(afterFirst > 0)

        _ = try await coordinator.punch(to: target, from: local)

        let afterSecond = coordinator.totalAttempts
        #expect(afterSecond > afterFirst)
    }

    @Test("Coordinator is Sendable and safe for concurrent access", .timeLimit(.minutes(1)))
    func concurrentSafety() async throws {
        let config = HolePunchConfig(
            timeout: .milliseconds(200),
            simultaneousAttempts: 1,
            retryDelay: .milliseconds(50)
        )
        let coordinator = QUICHolePunchCoordinator(config: config)
        let target = try Multiaddr("/ip4/203.0.113.1/udp/5678/quic-v1")
        let local = try Multiaddr("/ip4/0.0.0.0/udp/4433/quic-v1")

        // Run multiple punches concurrently to verify thread safety
        try await withThrowingTaskGroup(of: HolePunchResult.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    try await coordinator.punch(to: target, from: local)
                }
            }

            var results: [HolePunchResult] = []
            for try await result in group {
                results.append(result)
            }

            #expect(results.count == 5)
            // Total attempts should reflect all concurrent runs
            #expect(coordinator.totalAttempts > 0)
        }
    }
}

// MARK: - HolePunchError Tests

@Suite("HolePunchError Tests")
struct HolePunchErrorTests {

    @Test("HolePunchError.noLocalEndpoint is distinct")
    func noLocalEndpoint() {
        let error: HolePunchError = .noLocalEndpoint
        if case .noLocalEndpoint = error {
            // Expected
        } else {
            Issue.record("Expected noLocalEndpoint error case")
        }
    }

    @Test("HolePunchError.punchTimeout is distinct")
    func punchTimeout() {
        let error: HolePunchError = .punchTimeout
        if case .punchTimeout = error {
            // Expected
        } else {
            Issue.record("Expected punchTimeout error case")
        }
    }

    @Test("HolePunchError.connectionFailed wraps underlying error")
    func connectionFailed() {
        struct TestError: Error {}
        let error: HolePunchError = .connectionFailed(TestError())
        if case .connectionFailed(let underlying) = error {
            #expect(underlying is TestError)
        } else {
            Issue.record("Expected connectionFailed error case")
        }
    }

    @Test("HolePunchError.invalidAddress stores the address")
    func invalidAddress() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/tcp/4433")
        let error: HolePunchError = .invalidAddress(addr)
        if case .invalidAddress(let storedAddr) = error {
            #expect(storedAddr == addr)
        } else {
            Issue.record("Expected invalidAddress error case")
        }
    }
}
