/// ControlFrameQueue - Decouples control-frame sends from the Yamux read loop.
///
/// The read loop decodes inbound frames and must emit control responses
/// (ACK, RST, Pong, window updates). Sending them inline through the single
/// `FrameWriter` lets a back-pressured underlying write stall the read loop —
/// which then cannot drain incoming frames, including the window updates that
/// would unblock the very writer causing the back-pressure (a soft deadlock).
///
/// This queue buffers control frames and drains them on a dedicated task, so
/// the read loop only ever enqueues (non-blocking, bounded) and never awaits a
/// write. The queue is bounded: if a peer floods control frames faster than the
/// transport can drain them, enqueue fails explicitly (no silent drop) and the
/// caller tears down the connection.
import Foundation
import Synchronization

/// A bounded FIFO queue of control frames drained by a single consumer task.
///
/// Thread-safe via `Mutex`. Producers (`enqueue`) never block; a single
/// consumer (`next`) awaits frames. `finish()` terminates the consumer.
final class ControlFrameQueue: Sendable {
    private struct State: Sendable {
        var buffer: [YamuxFrame] = []
        var waiter: CheckedContinuation<YamuxFrame?, Never>?
        var isFinished = false
    }

    /// Maximum number of control frames buffered before enqueue fails.
    ///
    /// Control frames are tiny (header-only, except window updates) and the
    /// drain task runs continuously, so this only fills under pathological
    /// transport stalls or control-frame floods — both of which warrant
    /// tearing the connection down rather than buffering unboundedly.
    private let capacity: Int

    private let state: Mutex<State>

    init(capacity: Int) {
        self.capacity = capacity
        self.state = Mutex(State())
    }

    /// Result of an enqueue attempt.
    private enum EnqueueOutcome {
        /// A consumer was waiting; resume it directly with the frame.
        case resume(CheckedContinuation<YamuxFrame?, Never>)
        /// The frame was buffered for later draining.
        case buffered
        /// The queue was full or finished; the frame was rejected.
        case rejected
    }

    /// Enqueues a control frame for the drain task.
    ///
    /// Never blocks. - Returns: `true` if enqueued (or delivered to a waiting
    /// consumer), `false` if the queue is full or finished.
    @discardableResult
    func enqueue(_ frame: YamuxFrame) -> Bool {
        let outcome: EnqueueOutcome = state.withLock { state in
            if state.isFinished { return .rejected }
            if let w = state.waiter {
                state.waiter = nil
                return .resume(w)
            }
            guard state.buffer.count < capacity else {
                return .rejected
            }
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

    /// Awaits the next control frame, or `nil` once the queue is finished and
    /// drained.
    func next() async -> YamuxFrame? {
        await withCheckedContinuation { continuation in
            enum Action {
                case frame(YamuxFrame)
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
        let waiter: CheckedContinuation<YamuxFrame?, Never>? = state.withLock { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            let w = state.waiter
            state.waiter = nil
            return w
        }
        waiter?.resume(returning: nil)
    }
}
