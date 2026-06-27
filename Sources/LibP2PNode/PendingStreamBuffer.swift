// PendingStreamBuffer.swift
// Embedded-clean buffering for peer-opened QUIC stream IDs drained in batches from
// the QUIC engine facade.

import Synchronization

/// Thread-safe buffer for peer-opened stream IDs.
///
/// `QUICEngineClient.takeNewStreams()` drains and clears the engine queue. When it
/// returns several IDs at once, `QUICConnection.acceptStream` must preserve every
/// surplus ID and hand them out one by one. This type keeps that state behind an
/// Embedded-compatible spinlock based on `Atomic<Bool>`; `Synchronization.Mutex`
/// is intentionally not used in the Embedded node target.
final class PendingStreamBuffer: @unchecked Sendable {

    private var streamIDs: [UInt64] = []
    private var nextIndex: Int = 0
    private let lockFlag = Atomic<Bool>(false)

    /// Returns a previously-buffered stream ID, if any.
    func popBuffered() -> UInt64? {
        withLock { popLocked() }
    }

    /// Appends a batch drained from the engine and returns the next stream ID.
    func appendAndPop(_ drained: [UInt64]) -> UInt64? {
        withLock {
            streamIDs.append(contentsOf: drained)
            return popLocked()
        }
    }

    private func withLock<R>(_ body: () -> R) -> R {
        while true {
            if lockFlag.compareExchange(
                expected: false, desired: true, ordering: .acquiring
            ).exchanged {
                break
            }
        }
        defer { lockFlag.store(false, ordering: .releasing) }
        return body()
    }

    private func popLocked() -> UInt64? {
        guard nextIndex < streamIDs.count else {
            streamIDs.removeAll(keepingCapacity: true)
            nextIndex = 0
            return nil
        }

        let streamID = streamIDs[nextIndex]
        nextIndex += 1

        if nextIndex == streamIDs.count {
            streamIDs.removeAll(keepingCapacity: true)
            nextIndex = 0
        } else if nextIndex > 32 && nextIndex * 2 >= streamIDs.count {
            streamIDs.removeFirst(nextIndex)
            nextIndex = 0
        }

        return streamID
    }
}
