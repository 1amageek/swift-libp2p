/// ReconnectionPolicyTests - Tests for ReconnectionPolicy

import Testing
import Foundation
@testable import P2P

@Suite("ReconnectionPolicy Tests")
struct ReconnectionPolicyTests {

    // MARK: - Configuration Presets

    @Test("Default configuration values")
    func defaultConfig() {
        let policy = ReconnectionPolicy.default

        #expect(policy.enabled == true)
        #expect(policy.maxRetries == 10)
        #expect(policy.resetThreshold == .seconds(30))
    }

    @Test("Disabled configuration")
    func disabledConfig() {
        let policy = ReconnectionPolicy.disabled

        #expect(policy.enabled == false)
        #expect(policy.maxRetries == 0)
    }

    @Test("Aggressive configuration")
    func aggressiveConfig() {
        let policy = ReconnectionPolicy.aggressive

        #expect(policy.enabled == true)
        #expect(policy.maxRetries == 20)
        #expect(policy.resetThreshold == .seconds(15))
    }

    @Test("Persistent configuration")
    func persistentConfig() {
        let policy = ReconnectionPolicy.persistent

        #expect(policy.enabled == true)
        #expect(policy.maxRetries == 100)
        #expect(policy.resetThreshold == .seconds(60))
    }

    // MARK: - shouldReconnect Logic

    @Test("Basic: enabled + attempt < max → true")
    func shouldReconnectBasic() {
        let policy = ReconnectionPolicy(enabled: true, maxRetries: 5)

        #expect(policy.shouldReconnect(attempt: 0, reason: .remoteClose) == true)
        #expect(policy.shouldReconnect(attempt: 4, reason: .remoteClose) == true)
    }

    @Test("Disabled: always returns false")
    func shouldNotReconnectDisabled() {
        let policy = ReconnectionPolicy.disabled

        #expect(policy.shouldReconnect(attempt: 0, reason: .remoteClose) == false)
    }

    @Test("Max retries exceeded: returns false")
    func shouldNotReconnectMaxRetries() {
        let policy = ReconnectionPolicy(enabled: true, maxRetries: 3)

        #expect(policy.shouldReconnect(attempt: 3, reason: .remoteClose) == false)
        #expect(policy.shouldReconnect(attempt: 10, reason: .remoteClose) == false)
    }

    @Test("Local close: don't reconnect")
    func shouldNotReconnectLocalClose() {
        let policy = ReconnectionPolicy.default

        #expect(policy.shouldReconnect(attempt: 0, reason: .localClose) == false)
    }

    @Test("Gated: don't reconnect")
    func shouldNotReconnectGated() {
        let policy = ReconnectionPolicy.default

        #expect(policy.shouldReconnect(attempt: 0, reason: .gated(stage: .dial)) == false)
        #expect(policy.shouldReconnect(attempt: 0, reason: .gated(stage: .accept)) == false)
        #expect(policy.shouldReconnect(attempt: 0, reason: .gated(stage: .secured)) == false)
    }

    @Test("Connection limit exceeded: don't reconnect")
    func shouldNotReconnectLimitExceeded() {
        let policy = ReconnectionPolicy.default

        #expect(policy.shouldReconnect(attempt: 0, reason: .connectionLimitExceeded) == false)
    }

    @Test("Protocol error: don't reconnect")
    func shouldNotReconnectProtocolError() {
        let policy = ReconnectionPolicy.default

        #expect(policy.shouldReconnect(attempt: 0, reason: .error(code: .protocolError, message: "no agreement")) == false)
    }

    @Test("Transport error: do reconnect")
    func shouldReconnectTransportError() {
        let policy = ReconnectionPolicy.default

        #expect(policy.shouldReconnect(attempt: 0, reason: .error(code: .transportError, message: "connection refused")) == true)
    }

    @Test("Remote close: do reconnect")
    func shouldReconnectRemoteClose() {
        let policy = ReconnectionPolicy.default

        #expect(policy.shouldReconnect(attempt: 0, reason: .remoteClose) == true)
    }

    @Test("Timeout: do reconnect")
    func shouldReconnectTimeout() {
        let policy = ReconnectionPolicy.default

        #expect(policy.shouldReconnect(attempt: 0, reason: .timeout) == true)
    }

    @Test("Health check failed: do reconnect")
    func shouldReconnectHealthCheckFailed() {
        let policy = ReconnectionPolicy.default

        #expect(policy.shouldReconnect(attempt: 0, reason: .healthCheckFailed) == true)
    }

    // MARK: - Delay Delegation

    @Test("delay(for:) delegates to backoff strategy")
    func delayDelegation() {
        let policy = ReconnectionPolicy(
            backoff: BackoffStrategy(kind: .constant(.seconds(5)), jitter: 0)
        )

        #expect(policy.delay(for: 0) == .seconds(5))
        #expect(policy.delay(for: 10) == .seconds(5))
    }

    // MARK: - Equatable

    @Test("Equatable: same values are equal")
    func equatableSame() {
        let a = ReconnectionPolicy.default
        let b = ReconnectionPolicy.default

        #expect(a == b)
    }

    @Test("Equatable: different values are not equal")
    func equatableDifferent() {
        let a = ReconnectionPolicy.default
        let b = ReconnectionPolicy.disabled

        #expect(a != b)
    }
}
