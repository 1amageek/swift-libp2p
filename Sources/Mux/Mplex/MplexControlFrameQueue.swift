/// MplexControlFrameQueue - Decouples control-frame sends from the read loop.
///
/// The Mplex read loop decodes inbound frames and must emit RST responses for
/// protocol violations (reused/over-limit/unowned streams). Sending them inline
/// through the single `MplexFrameWriter` lets a back-pressured underlying write
/// stall the read loop, which then cannot drain incoming frames (head-of-line
/// blocking / soft deadlock).
///
/// This queue buffers control frames and drains them on a dedicated task, so the
/// read loop only ever enqueues (non-blocking, bounded) and never awaits a
/// write. The queue is bounded: a control-frame flood fails enqueue explicitly
/// (no silent drop) and the caller tears the connection down.
import Foundation
import Synchronization

/// A bounded FIFO queue of Mplex control frames drained by a single consumer.
final class MplexControlFrameQueue: Sendable {
    private struct State: Sendable {
        var buffer: [MplexFrame] = []
        var waiter: CheckedContinuation<MplexFrame?, Never>?
        var isFinished = false
    }

    private let capacity: Int
    private let state: Mutex<State>

    init(capacity: Int) {
        self.capacity = capacity
        self.state = Mutex(State())
    }

    private enum EnqueueOutcome {
        case resume(CheckedContinuation<MplexFrame?, Never>)
        case buffered
        case rejected
    }

    /// Enqueues a control frame. Never blocks.
    ///
    /// - Returns: `true` if enqueued or delivered to a waiting consumer,
    ///   `false` if the queue is full or finished.
    @discardableResult
    func enqueue(_ frame: MplexFrame) -> Bool {
        let outcome: EnqueueOutcome = state.withLock { state in
            if state.isFinished { return .rejected }
            if let w = state.waiter {
                state.waiter = nil
                return .resume(w)
            }
            guard state.buffer.count < capacity else { return .rejected }
            state.buffer.append(frame)
            return .buffered
        }
        switch outcome {
        case .resume(let waiter):
            waiter.resume(returning: frame)
            return true
        case .buffered:
            return true
        case .rejected:
            return false
        }
    }

    /// Awaits the next control frame, or `nil` once finished and drained.
    func next() async -> MplexFrame? {
        await withCheckedContinuation { continuation in
            enum Action {
                case frame(MplexFrame)
                case finished
                case wait
            }
            let action: Action = state.withLock { state in
                if !state.buffer.isEmpty {
                    return .frame(state.buffer.removeFirst())
                }
                if state.isFinished {
                    return .finished
                }
                state.waiter = continuation
                return .wait
            }
            switch action {
            case .frame(let f): continuation.resume(returning: f)
            case .finished: continuation.resume(returning: nil)
            case .wait: break
            }
        }
    }

    /// Terminates the queue. The drain task's pending `next()` resolves to
    /// `nil`; further enqueues fail.
    func finish() {
        let waiter: CheckedContinuation<MplexFrame?, Never>? = state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            let w = state.waiter
            state.waiter = nil
            return w
        }
        waiter?.resume(returning: nil)
    }
}
