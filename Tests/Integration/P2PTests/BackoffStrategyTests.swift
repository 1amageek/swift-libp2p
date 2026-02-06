/// BackoffStrategyTests - Tests for BackoffStrategy

import Testing
import Foundation
@testable import P2P

@Suite("BackoffStrategy Tests")
struct BackoffStrategyTests {

    // MARK: - Exponential

    @Test("Exponential growth: base doubles each attempt")
    func exponentialGrowth() {
        let strategy = BackoffStrategy(
            kind: .exponential(base: .milliseconds(100), multiplier: 2.0, max: .minutes(5)),
            jitter: 0
        )

        let d0 = strategy.delay(for: 0)
        let d1 = strategy.delay(for: 1)
        let d2 = strategy.delay(for: 2)

        #expect(d0 == .milliseconds(100))
        #expect(d1 == .milliseconds(200))
        #expect(d2 == .milliseconds(400))
    }

    @Test("Exponential cap: delay does not exceed max")
    func exponentialCap() {
        let strategy = BackoffStrategy(
            kind: .exponential(base: .seconds(1), multiplier: 10.0, max: .seconds(5)),
            jitter: 0
        )

        // attempt 0 = 1s, attempt 1 = 10s (capped to 5s)
        let d0 = strategy.delay(for: 0)
        let d1 = strategy.delay(for: 1)
        let d2 = strategy.delay(for: 2)

        #expect(d0 == .seconds(1))
        #expect(d1 == .seconds(5))
        #expect(d2 == .seconds(5))
    }

    // MARK: - Constant

    @Test("Constant delay: same value for all attempts")
    func constantDelay() {
        let strategy = BackoffStrategy(
            kind: .constant(.milliseconds(500)),
            jitter: 0
        )

        #expect(strategy.delay(for: 0) == .milliseconds(500))
        #expect(strategy.delay(for: 1) == .milliseconds(500))
        #expect(strategy.delay(for: 5) == .milliseconds(500))
        #expect(strategy.delay(for: 100) == .milliseconds(500))
    }

    // MARK: - Linear

    @Test("Linear growth: base + increment * attempt")
    func linearGrowth() {
        let strategy = BackoffStrategy(
            kind: .linear(base: .seconds(1), increment: .milliseconds(500), max: .seconds(10)),
            jitter: 0
        )

        #expect(strategy.delay(for: 0) == .seconds(1))
        #expect(strategy.delay(for: 2) == .seconds(2))
        #expect(strategy.delay(for: 4) == .seconds(3))
    }

    @Test("Linear cap: delay does not exceed max")
    func linearCap() {
        let strategy = BackoffStrategy(
            kind: .linear(base: .seconds(1), increment: .seconds(5), max: .seconds(10)),
            jitter: 0
        )

        // attempt 0 = 1, attempt 1 = 6, attempt 2 = 11 -> capped to 10
        #expect(strategy.delay(for: 0) == .seconds(1))
        #expect(strategy.delay(for: 1) == .seconds(6))
        #expect(strategy.delay(for: 2) == .seconds(10))
    }

    // MARK: - Jitter

    @Test("Zero jitter: exact base delay")
    func zeroJitter() {
        let strategy = BackoffStrategy(
            kind: .exponential(base: .seconds(1), multiplier: 2.0, max: .seconds(60)),
            jitter: 0
        )

        // With zero jitter, should be exactly the base
        #expect(strategy.delay(for: 0) == .seconds(1))
    }

    @Test("Jitter range: result within ±jitter% of base")
    func jitterRange() {
        let strategy = BackoffStrategy(
            kind: .constant(.seconds(10)),
            jitter: 0.1
        )

        // Run multiple times to test jitter bounds
        for _ in 0..<50 {
            let d = strategy.delay(for: 0)
            let seconds = d.asSeconds
            // 10s ± 10% = [9, 11]
            #expect(seconds >= 9.0)
            #expect(seconds <= 11.0)
        }
    }

    // MARK: - Edge Cases

    @Test("Zero delay with .none preset")
    func zeroDelay() {
        let strategy = BackoffStrategy.none

        #expect(strategy.delay(for: 0) == .zero)
        #expect(strategy.delay(for: 10) == .zero)
    }

    @Test("Default preset parameters")
    func defaultPreset() {
        let strategy = BackoffStrategy.default

        // Verify default is exponential with expected parameters
        if case .exponential(let base, let multiplier, let max) = strategy.kind {
            #expect(base == .milliseconds(100))
            #expect(multiplier == 2.0)
            #expect(max == .minutes(5))
        } else {
            Issue.record("Default should be exponential")
        }
        #expect(strategy.jitter == 0.1)
    }

    @Test("Aggressive preset parameters")
    func aggressivePreset() {
        let strategy = BackoffStrategy.aggressive

        if case .exponential(let base, let multiplier, let max) = strategy.kind {
            #expect(base == .milliseconds(50))
            #expect(multiplier == 1.5)
            #expect(max == .seconds(30))
        } else {
            Issue.record("Aggressive should be exponential")
        }
        #expect(strategy.jitter == 0.2)
    }

    @Test("Large attempt does not overflow")
    func largeAttempt() {
        let strategy = BackoffStrategy(
            kind: .exponential(base: .milliseconds(100), multiplier: 2.0, max: .seconds(60)),
            jitter: 0
        )

        // attempt=100 would overflow without cap: 100ms * 2^100
        // Should be capped to max
        let delay = strategy.delay(for: 100)
        #expect(delay == .seconds(60))
    }
}
