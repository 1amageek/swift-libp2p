// TestClock.swift
// Host-only test `AsyncTimer` backed by `ContinuousClock` + `Task.sleep`. Embedded
// builds inject their own platform timer; the test target needs only a real clock
// to drive the negotiation deadline.

import Foundation
import P2PCoreCrypto

/// A host `AsyncTimer` for tests (ContinuousClock + Task.sleep).
struct TestClock: AsyncTimer {
    private let origin = ContinuousClock.now
    private let clock = ContinuousClock()

    func monotonicMillis() -> UInt64 {
        monotonicNanos() / 1_000_000
    }

    func monotonicNanos() -> UInt64 {
        let elapsed = ContinuousClock.now - origin
        let (seconds, attoseconds) = elapsed.components
        return UInt64(max(0, seconds)) &* 1_000_000_000
            &+ UInt64(max(0, attoseconds) / 1_000_000_000)
    }

    func sleep(untilNanos deadlineNanos: UInt64) async throws(CancellationError) {
        let now = monotonicNanos()
        if deadlineNanos <= now { return }
        let waitNanos = deadlineNanos - now
        let instant = ContinuousClock.now.advanced(by: .nanoseconds(waitNanos))
        do {
            try await Task.sleep(until: instant, clock: clock)
        } catch {
            throw CancellationError()
        }
    }
}

/// A host wall-clock for tests.
struct TestWallClock: WallClock {
    func nowUnixSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970.rounded(.down))
    }
}
